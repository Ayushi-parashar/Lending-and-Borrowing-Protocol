// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * EnhancedProjectV3 (upgraded)
 *
 * Additions:
 * - Utilization-based dynamic interest rate (getDynamicInterestRate)
 * - View pending interest (getPendingInterest)
 * - Partial repayments with explicit amount (repayPartial)
 * - Emergency collateral withdrawal when no active loan (emergencyWithdrawCollateral)
 * - Owner-only protocol reserve withdrawal (Ownable)
 *
 * Existing:
 * - Collateral deposit / withdraw (with 1 hour cooldown on collateral added)
 * - Borrowing with collateral ratio check
 * - Interest accrual (simple)
 * - Repayments (interest first, then principal)
 * - Liquidation with bonus
 * - Protocol reserve receiving a fee cut of interest + liquidated collateral
 * - Portfolio & health helpers
 */
contract EnhancedProjectV3 is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    // --- Parameters ---
    uint256 public constant COLLATERAL_RATIO = 150; // 150% required (collateral / debt * 100)
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120% (liquidatable if < 120%)
    uint256 public constant LIQUIDATION_BONUS = 5; // 5% of collateral to liquidator

    // Base interest is no longer used directly; accrual pulls dynamic rate from utilization.
    // Kept for reference/compatibility; can be used as a "mid" tier rate in the model.
    uint256 public constant INTEREST_RATE_BP = 500; // 5% (basis points)

    uint256 public constant INTEREST_FEE_BP = 1000; // protocol fee on interest in bp (1000 = 10%)
    uint256 public constant BP_DIVISOR = 10000;

    uint256 public totalCollateral;
    uint256 public totalLoans; // principal + borrower-accrued interest (excludes protocolReserve)
    uint256 public protocolReserve; // ETH value stored as protocol-owned funds

    // --- Structs ---
    struct User {
        uint256 collateralDeposited;
        uint256 loanTaken; // principal outstanding
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
    event ProtocolReserveWithdrawn(address indexed to, uint256 amount);

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
        require(ratio >= COLLATERAL_RATIO, "Not enough collateral");

        // Disallow overlapping loans for simplicity
        require(!loans[msg.sender].isActive, "Active loan exists");

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

        // Send ETH to borrower
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");

        emit LoanTaken(msg.sender, amount, user.collateralDeposited);
    }

    // --- Interest model: utilization-based dynamic rate (in basis points) ---
    // Utilization = totalLoans / totalCollateral (scaled to %)
    // You can tweak thresholds/tiers as desired.
    function getDynamicInterestRate() public view returns (uint256) {
        if (totalCollateral == 0) return INTEREST_RATE_BP; // avoid div-by-zero

        uint256 utilizationPct = totalLoans.mul(100).div(totalCollateral);
        if (utilizationPct < 50) {
            return 300; // 3%
        } else if (utilizationPct < 80) {
            return 500; // 5%
        } else {
            return 800; // 8%
        }
    }

    // --- View pending interest since last accrual (net of fee) ---
    function getPendingInterest(address borrower) public view returns (uint256) {
        Loan memory loan = loans[borrower];
        if (!loan.isActive || loan.principal == 0) return 0;

        if (block.timestamp <= loan.lastInterestTime) return 0;
        uint256 timeElapsed = block.timestamp.sub(loan.lastInterestTime);
        if (timeElapsed == 0) return 0;

        uint256 yearSeconds = 365 days;
        uint256 dynRateBp = getDynamicInterestRate();
        // principal * rate(bp) * time / (year) / 100 (because bp already /100)
        uint256 grossInterest = loan.principal.mul(dynRateBp).mul(timeElapsed).div(yearSeconds).div(100);

        uint256 fee = grossInterest.mul(INTEREST_FEE_BP).div(BP_DIVISOR);
        return grossInterest.sub(fee);
    }

    // --- Internal: accrue interest since lastInterestTime for a borrower ---
    function _accrueInterest(address borrower) internal {
        Loan storage loan = loans[borrower];
        if (!loan.isActive || loan.principal == 0) return;

        uint256 nowTs = block.timestamp;
        if (nowTs <= loan.lastInterestTime) return;

        uint256 timeElapsed = nowTs.sub(loan.lastInterestTime);
        if (timeElapsed == 0) return;

        uint256 yearSeconds = 365 days;
        uint256 dynRateBp = getDynamicInterestRate();
        uint256 grossInterest = loan.principal.mul(dynRateBp).mul(timeElapsed).div(yearSeconds).div(100);

        if (grossInterest == 0) {
            loan.lastInterestTime = nowTs;
            return;
        }

        // Split fee to protocol reserve
        uint256 fee = grossInterest.mul(INTEREST_FEE_BP).div(BP_DIVISOR);
        uint256 interestAfterFee = grossInterest.sub(fee);

        loan.interestAccrued = loan.interestAccrued.add(interestAfterFee);

        // accounting
        totalLoans = totalLoans.add(interestAfterFee);
        protocolReserve = protocolReserve.add(fee);

        loan.lastInterestTime = nowTs;

        emit InterestAccrued(borrower, interestAfterFee, fee);
    }

    // --- Internal: process repayment logic and emit event ---
    function _processRepayment(address payer, uint256 amount) internal returns (uint256 principalReduced, uint256 interestReduced) {
        require(amount > 0, "Repay must be > 0");
        Loan storage loan = loans[payer];
        require(loan.isActive, "No active loan");

        // Accrue interest up to now
        _accrueInterest(payer);

        uint256 remaining = amount;

        // First cover interestAccrued
        if (remaining >= loan.interestAccrued) {
            interestReduced = loan.interestAccrued;
            remaining = remaining.sub(loan.interestAccrued);
            loan.interestAccrued = 0;
        } else {
            interestReduced = remaining;
            loan.interestAccrued = loan.interestAccrued.sub(remaining);
            remaining = 0;
        }

        // Then reduce principal
        if (remaining > 0) {
            if (remaining >= loan.principal) {
                principalReduced = loan.principal;
                remaining = remaining.sub(loan.principal);
                loan.principal = 0;
            } else {
                principalReduced = remaining;
                loan.principal = loan.principal.sub(remaining);
                remaining = 0;
            }
        }

        // Update global accounting
        uint256 totalReduced = interestReduced.add(principalReduced);
        if (totalReduced > 0) {
            totalLoans = totalLoans.sub(totalReduced);
        }

        // Adjust user record (principal part only)
        if (principalReduced > 0) {
            users[payer].loanTaken = users[payer].loanTaken.sub(principalReduced);
        }

        // If fully repaid
        if (loan.principal == 0 && loan.interestAccrued == 0) {
            loan.isActive = false;
            loan.lastInterestTime = 0;
        }

        emit LoanRepaid(payer, amount, principalReduced, interestReduced);

        // Any "remaining" here would be an overpay, but by construction we enforce msg.value == amount from caller.
        return (principalReduced, interestReduced);
    }

    // --- Repay loan (payable) ---
    function repayLoan() external payable nonReentrant {
        require(msg.value > 0, "Repay must be > 0");
        _processRepayment(msg.sender, msg.value);
    }

    // --- Repay a specific amount (explicit) ---
    function repayPartial(uint256 repayAmount) external payable nonReentrant {
        require(repayAmount > 0, "Invalid repay amount");
        require(msg.value == repayAmount, "ETH must match repayAmount");
        _processRepayment(msg.sender, repayAmount);
    }

    // --- Withdraw collateral (only allowed while loan is active and respecting ratio) ---
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid amount");
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        // cooldown: 1 hour since last collateral deposit
        require(block.timestamp > loan.lastDepositTime + 1 hours, "Collateral locked");

        // Accrue interest first
        _accrueInterest(msg.sender);

        require(amount <= loan.collateral, "Amount exceeds loan collateral");

        uint256 newCollateral = loan.collateral.sub(amount);

        // total owed = principal + interestAccrued
        uint256 totalOwed = loan.principal.add(loan.interestAccrued);
        require(totalOwed > 0, "No owed amount");

        // New health ratio
        uint256 ratio = newCollateral.mul(100).div(totalOwed);
        require(ratio >= COLLATERAL_RATIO, "Would drop below ratio");

        // Update states
        loan.collateral = newCollateral;
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);

        emit CollateralWithdrawn(msg.sender, amount, newCollateral);

        // Transfer ETH back
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");
    }

    // --- Emergency withdraw (when NO active loan) ---
    function emergencyWithdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Invalid amount");
        require(!loans[msg.sender].isActive, "Active loan exists");
        require(users[msg.sender].collateralDeposited >= amount, "Insufficient collateral");

        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");
    }

    // --- Liquidation ---
    // Any account can liquidate by repaying full owed (principal + interest).
    // Liquidator pays msg.value == totalOwed and receives LIQUIDATION_BONUS% of borrower's collateral.
    // Remaining collateral goes to protocolReserve.
    function liquidate(address borrower) external payable nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");

        // Accrue interest for borrower
        _accrueInterest(borrower);

        uint256 totalOwed = loan.principal.add(loan.interestAccrued);
        require(totalOwed > 0, "No debt");
        uint256 ratio = loan.collateral.mul(100).div(totalOwed);
        require(ratio < LIQUIDATION_THRESHOLD, "Loan healthy");
        require(msg.value == totalOwed, "Must repay full owed");

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

        // Remaining collateral becomes protocol reserve
        protocolReserve = protocolReserve.add(remainingCollateral);

        emit LoanLiquidated(msg.sender, borrower, totalOwed, bonusCollateral);
    }

    // --- Helper views ---
    // Returns large number (max uint) when no loan
    function getHealthFactor(address userAddr) external view returns (uint256) {
        Loan memory loan = loans[userAddr];
        if (!loan.isActive) return type(uint256).max;
        uint256 totalOwed = loan.principal.add(loan.interestAccrued);
        if (totalOwed == 0) return type(uint256).max;
        return loan.collateral.mul(100).div(totalOwed);
    }

    // Return collateral, principal, interest, and health in single call
    function getUserPortfolio(address userAddr) external view returns (
        uint256 collateral,
        uint256 principal,
        uint256 interestAccrued,
        uint256 healthFactor
    ) {
        Loan memory loan = loans[userAddr];
        collateral = loan.collateral;
        principal = loan.principal;
        interestAccrued = loan.interestAccrued;
        if (!loan.isActive || principal.add(interestAccrued) == 0) {
            healthFactor = type(uint256).max;
        } else {
            healthFactor = collateral.mul(100).div(principal.add(interestAccrued));
        }
    }

    // --- Admin: withdraw collected protocol reserve to owner ---
    function withdrawProtocolReserve(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Invalid amount");
        require(amount <= protocolReserve, "Exceeds reserve");
        protocolReserve = protocolReserve.sub(amount);

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Transfer failed");

        emit ProtocolReserveWithdrawn(msg.sender, amount);
    }

    // Fallback / receive to accept ETH (e.g., direct transfers)
    receive() external payable {
        // Receiving ETH increases contract balance but not counters unless routed via functions.
    }
}
