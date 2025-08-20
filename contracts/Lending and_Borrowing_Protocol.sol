// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * EnhancedProjectV3
 *
 * Features:
 * - Collateral deposit / withdraw (with 1 hour cooldown on collateral added)
 * - Borrowing (requires collateral ratio)
 * - Interest accrual (simple interest, accrued continuously)
 * - Repayments (repay interest first, then principal)
 * - Liquidation by third parties if health factor < LIQUIDATION_THRESHOLD
 * - Protocol reserve which receives a fraction of accrued interest and liquidated collateral
 * - Helper view functions for portfolio and health
 *
 * Notes:
 * - Contract holds ETH deposited as collateral, which is used/referenced for loans.
 * - Borrow sends ETH from contract to borrower (so contract needs collateral balance from deposits).
 */
contract EnhancedProjectV3 is ReentrancyGuard {
    using SafeMath for uint256;

    // --- Parameters ---
    uint256 public constant COLLATERAL_RATIO = 150; // 150% required (collateral / debt * 100)
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120% health -> liquidatable if < 120%
    uint256 public constant LIQUIDATION_BONUS = 5; // 5% of collateral goes to liquidator
    uint256 public constant INTEREST_RATE_BP = 500; // basis points annual interest (500 bp = 5% per year)
    uint256 public constant INTEREST_FEE_BP = 1000; // fee on interest in basis points /10000 (i.e., 1000 => 10%)
    uint256 public constant BP_DIVISOR = 10000;

    uint256 public totalCollateral;
    uint256 public totalLoans; // sum of (principal + loanInterest) outstanding excluding protocolReserve
    uint256 public protocolReserve; // tracked reserve (ETH value stored in contract balance)

    // --- Structs ---
    struct User {
        uint256 collateralDeposited;
        uint256 loanTaken; // principal borrowed (sum of principals)
    }

    struct Loan {
        uint256 principal;         // principal outstanding
        uint256 interestAccrued;   // accrued interest (net of protocol fee)
        uint256 collateral;        // collateral allocated to this loan
        uint256 lastDepositTime;   // last time collateral was deposited (for withdraw cooldown)
        uint256 lastInterestTime;  // timestamp of last interest accrual
        bool isActive;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;

    // --- Events ---
    event CollateralDeposited(address indexed user, uint256 amount);
    event LoanTaken(address indexed user, uint256 amount, uint256 collateral);
    event LoanRepaid(address indexed user, uint256 amountPaid, uint256 principalReduced, uint256 interestReduced);
    event CollateralWithdrawn(address indexed user, uint256 amount, uint256 remainingCollateral);
    event LoanLiquidated(address indexed liquidator, address indexed borrower, uint256 repaidAmount, uint256 bonusCollateral);
    event InterestAccrued(address indexed borrower, uint256 interestToLoan, uint256 feeToReserve);

    // --- Deposit collateral ---
    function depositCollateral() external payable nonReentrant {
        require(msg.value > 0, "Must deposit some ETH");

        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        totalCollateral = totalCollateral.add(msg.value);

        if (loans[msg.sender].isActive) {
            loans[msg.sender].collateral = loans[msg.sender].collateral.add(msg.value);
            loans[msg.sender].lastDepositTime = block.timestamp;
        }

        emit CollateralDeposited(msg.sender, msg.value);
    }

    // --- Borrow loan ---
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        User storage user = users[msg.sender];
        require(user.collateralDeposited > 0, "No collateral deposited");

        // Check collateral ratio using collateral deposited vs amount (principal)
        uint256 ratio = user.collateralDeposited.mul(100).div(amount);
        require(ratio >= COLLATERAL_RATIO, "Not enough collateral for requested loan");

        // If there is already an active loan, disallow overlapping new loan creation for simplicity.
        // (Alternatively you could allow increasing principal; left simple here.)
        require(!loans[msg.sender].isActive, "Existing active loan - repay or manage it first");

        // Create loan
        loans[msg.sender] = Loan({
            principal: amount,
            interestAccrued: 0,
            collateral: user.collateralDeposited,
            lastDepositTime: block.timestamp,
            lastInterestTime: block.timestamp,
            isActive: true
        });

        user.loanTaken = user.loanTaken.add(amount);
        totalLoans = totalLoans.add(amount);

        // Transfer loan amount to borrower from contract balance
        // Note: contract must hold enough ETH (it will if users deposited collateral)
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");

        emit LoanTaken(msg.sender, amount, user.collateralDeposited);
    }

    // --- Internal: accrue interest since lastInterestTime for a borrower ---
    function _accrueInterest(address borrower) internal {
        Loan storage loan = loans[borrower];
        if (!loan.isActive || loan.principal == 0) return;

        uint256 nowTs = block.timestamp;
        if (nowTs <= loan.lastInterestTime) return;

        uint256 timeElapsed = nowTs.sub(loan.lastInterestTime);
        if (timeElapsed == 0) return;

        // interest = principal * rate * timeElapsed / (yearInSeconds)
        uint256 yearSeconds = 365 days;
        uint256 interest = loan.principal.mul(INTEREST_RATE_BP).mul(timeElapsed).div(yearSeconds).div(100); // because INTEREST_RATE_BP is in bp/100

        if (interest == 0) {
            loan.lastInterestTime = nowTs;
            return;
        }

        // Split fee to protocol reserve
        uint256 fee = interest.mul(INTEREST_FEE_BP).div(BP_DIVISOR); // e.g., 10% when INTEREST_FEE_BP = 1000
        uint256 interestAfterFee = interest.sub(fee);

        loan.interestAccrued = loan.interestAccrued.add(interestAfterFee);

        // accounting
        totalLoans = totalLoans.add(interestAfterFee);
        protocolReserve = protocolReserve.add(fee);

        loan.lastInterestTime = nowTs;

        emit InterestAccrued(borrower, interestAfterFee, fee);
    }

    // --- Repay loan (payable) ---
    // Repayment reduces interestAccrued first, then principal.
    function repayLoan() external payable nonReentrant {
        require(msg.value > 0, "Repay must be > 0");
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        // Accrue interest up to now
        _accrueInterest(msg.sender);

        uint256 amountPaid = msg.value;
        uint256 interestReduced = 0;
        uint256 principalReduced = 0;

        // First cover interestAccrued
        if (amountPaid >= loan.interestAccrued) {
            interestReduced = loan.interestAccrued;
            amountPaid = amountPaid.sub(loan.interestAccrued);
            loan.interestAccrued = 0;
        } else {
            interestReduced = amountPaid;
            loan.interestAccrued = loan.interestAccrued.sub(amountPaid);
            amountPaid = 0;
        }

        // Then reduce principal
        if (amountPaid > 0) {
            if (amountPaid >= loan.principal) {
                principalReduced = loan.principal;
                amountPaid = amountPaid.sub(loan.principal);
                loan.principal = 0;
            } else {
                principalReduced = amountPaid;
                loan.principal = loan.principal.sub(amountPaid);
                amountPaid = 0;
            }
        }

        // Update global accounting
        uint256 totalReduced = interestReduced.add(principalReduced);
        if (totalReduced > 0) {
            // totalLoans tracks outstanding principal+interest (excluding protocolReserve)
            totalLoans = totalLoans.sub(totalReduced);
        }

        // Adjust user record
        if (principalReduced > 0) {
            // users[msg.sender].loanTaken represents principal outstanding
            users[msg.sender].loanTaken = users[msg.sender].loanTaken.sub(principalReduced);
        }

        // If fully repaid
        if (loan.principal == 0 && loan.interestAccrued == 0) {
            loan.isActive = false;
            loan.lastInterestTime = 0;
        }

        emit LoanRepaid(msg.sender, msg.value, principalReduced, interestReduced);
    }

    // --- Withdraw collateral (only allowed while loan is active and respecting ratio) ---
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid amount");
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        // cooldown: 1 hour since last collateral deposit
        require(block.timestamp > loan.lastDepositTime + 1 hours, "Collateral locked, wait before withdrawing");

        // Accrue interest first
        _accrueInterest(msg.sender);

        require(amount <= loan.collateral, "Amount exceeds loan collateral");

        uint256 newCollateral = loan.collateral.sub(amount);

        // total owed = principal + interestAccrued
        uint256 totalOwed = loan.principal.add(loan.interestAccrued);
        require(totalOwed > 0, "No owed amount (should not happen)");

        // New health ratio
        uint256 ratio = newCollateral.mul(100).div(totalOwed);
        require(ratio >= COLLATERAL_RATIO, "Would fall below collateral ratio");

        // Update states
        loan.collateral = newCollateral;
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);

        emit CollateralWithdrawn(msg.sender, amount, newCollateral);

        // Transfer ETH back
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");
    }

    // --- Liquidation ---
    // Any account can liquidate a borrower's loan by repaying full owed amount (principal + interestAccrued).
    // Liquidator must send the exact amount equal to totalOwed. Liquidator receives LIQUIDATION_BONUS% of borrower's collateral.
    // Remaining collateral is stored to protocolReserve (left in contract).
    function liquidate(address borrower) external payable nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan to liquidate");

        // Accrue interest for borrower
        _accrueInterest(borrower);

        uint256 totalOwed = loan.principal.add(loan.interestAccrued);
        require(totalOwed > 0, "No debt to liquidate");

        // health ratio
        uint256 ratio = loan.collateral.mul(100).div(totalOwed);
        require(ratio < LIQUIDATION_THRESHOLD, "Loan is healthy; cannot liquidate");

        require(msg.value == totalOwed, "Must repay full owed amount to liquidate");

        // Calculate bonus collateral to liquidator
        uint256 bonusCollateral = loan.collateral.mul(LIQUIDATION_BONUS).div(100);
        if (bonusCollateral > loan.collateral) {
            bonusCollateral = loan.collateral;
        }

        uint256 remainingCollateral = loan.collateral.sub(bonusCollateral);

        // Update accounting
        totalLoans = totalLoans.sub(totalOwed);
        users[borrower].loanTaken = 0;
        users[borrower].collateralDeposited = 0;
        totalCollateral = totalCollateral.sub(loan.collateral);

        // Mark loan closed
        loan.isActive = false;
        loan.principal = 0;
        loan.interestAccrued = 0;
        loan.collateral = 0;
        loan.lastDepositTime = 0;
        loan.lastInterestTime = 0;

        // Pay collateral bonus to liquidator
        if (bonusCollateral > 0) {
            (bool paid, ) = msg.sender.call{value: bonusCollateral}("");
            require(paid, "Paying liquidator failed");
        }

        // Keep the remainingCollateral inside contract as protocolReserve
        protocolReserve = protocolReserve.add(remainingCollateral);

        emit LoanLiquidated(msg.sender, borrower, totalOwed, bonusCollateral);
    }

    // --- Helper views ---
    // Returns large number (max uint) when no loan (signifies 'infinite' / healthy)
    function getHealthFactor(address user) external view returns (uint256) {
        Loan memory loan = loans[user];
        if (!loan.isActive) return type(uint256).max;
        uint256 totalOwed = loan.principal.add(loan.interestAccrued);
        if (totalOwed == 0) return type(uint256).max;
        return loan.collateral.mul(100).div(totalOwed);
    }

    // Return collateral, principal, interest, and health in single call
    function getUserPortfolio(address user) external view returns (
        uint256 collateral,
        uint256 principal,
        uint256 interestAccrued,
        uint256 healthFactor
    ) {
        Loan memory loan = loans[user];
        collateral = loan.collateral;
        principal = loan.principal;
        interestAccrued = loan.interestAccrued;
        if (!loan.isActive || principal.add(interestAccrued) == 0) {
            healthFactor = type(uint256).max;
        } else {
            healthFactor = collateral.mul(100).div(principal.add(interestAccrued));
        }
    }

    // --- Admin helper: withdraw collected protocol reserve to owner (not implemented owner logic for brevity) ---
    // For production, add Ownable and restrict access. Here it's a public function that sends reserve to caller
    // (for testing/demonstration). Replace with proper access control as needed.
    function withdrawProtocolReserve(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid amount");
        require(amount <= protocolReserve, "Amount exceeds reserve");
        protocolReserve = protocolReserve.sub(amount);

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");
    }

    // Fallback / receive to accept ETH (e.g., from direct transfers or leftover transfers)
    receive() external payable {
        // allow receiving ETH; this will increase contract balance but not protocolReserve / totalCollateral variables.
    }
}
