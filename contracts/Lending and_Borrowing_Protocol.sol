// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract EnhancedProjectV2 is ReentrancyGuard {
    using SafeMath for uint256;

    // --- Parameters ---
    uint256 public constant COLLATERAL_RATIO = 150; // 150% required
    uint256 public totalCollateral;
    uint256 public totalLoans;

    // --- Structs ---
    struct User {
        uint256 collateralDeposited;
        uint256 loanTaken;
    }

    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 lastDepositTime;
        bool isActive;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;

    // --- Events ---
    event CollateralDeposited(address indexed user, uint256 amount);
    event LoanTaken(address indexed user, uint256 amount, uint256 collateral);
    event LoanRepaid(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount, uint256 remainingCollateral);

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

    // --- Borrow loan (simple version) ---
    function borrow(uint256 amount) external nonReentrant {
        User storage user = users[msg.sender];
        require(user.collateralDeposited > 0, "No collateral deposited");
        require(amount > 0, "Amount must be > 0");

        uint256 ratio = user.collateralDeposited.mul(100).div(amount);
        require(ratio >= COLLATERAL_RATIO, "Not enough collateral");

        loans[msg.sender] = Loan({
            amount: amount,
            collateral: user.collateralDeposited,
            lastDepositTime: block.timestamp,
            isActive: true
        });

        user.loanTaken = user.loanTaken.add(amount);
        totalLoans = totalLoans.add(amount);

        payable(msg.sender).transfer(amount);

        emit LoanTaken(msg.sender, amount, user.collateralDeposited);
    }

    // --- Repay loan ---
    function repayLoan() external payable nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(msg.value > 0, "Repay must be > 0");
        require(msg.value <= loan.amount, "Cannot repay more than owed");

        loan.amount = loan.amount.sub(msg.value);
        users[msg.sender].loanTaken = users[msg.sender].loanTaken.sub(msg.value);
        totalLoans = totalLoans.sub(msg.value);

        if (loan.amount == 0) {
            loan.isActive = false;
        }

        emit LoanRepaid(msg.sender, msg.value);
    }

    // --- Withdraw collateral (enhanced) ---
    function withdrawCollateral(uint256 amount) external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(amount > 0 && amount <= loan.collateral, "Invalid amount");

        // Cooldown: avoid instant withdraw abuse (1 hour lock)
        require(
            block.timestamp > loan.lastDepositTime + 1 hours,
            "Collateral locked, wait before withdrawing"
        );

        uint256 newCollateral = loan.collateral.sub(amount);
        uint256 ratio = newCollateral.mul(100).div(loan.amount);

        require(ratio >= COLLATERAL_RATIO, "Would fall below collateral ratio");

        loan.collateral = newCollateral;
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);

        emit CollateralWithdrawn(msg.sender, amount, newCollateral);

        payable(msg.sender).transfer(amount);
    }

    // --- Helper: get health factor ---
    function getHealthFactor(address user) external view returns (uint256) {
        Loan memory loan = loans[user];
        if (!loan.isActive || loan.amount == 0) return type(uint256).max;
        return loan.collateral.mul(100).div(loan.amount);
    }
}
