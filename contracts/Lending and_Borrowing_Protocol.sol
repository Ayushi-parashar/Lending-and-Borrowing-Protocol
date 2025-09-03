// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract EnhancedProjectV5 is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    struct Loan {
        uint256 principal;
        uint256 interestAccrued;
        uint256 startTime;
        bool isActive;
    }

    struct User {
        uint256 deposited;
        uint256 borrowed;
        uint256 collateralDeposited;
        uint256 rewardDebt;
        bool isBlacklisted;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;
    mapping(address => uint256) public rewards;

    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public totalCollateral;
    uint256 public baseInterestRate = 5;
    uint256 public collateralRatio = 150;
    uint256 public rewardRate = 100;

    // Fine-grained pause controls
    bool public borrowingPaused = false;
    bool public repaymentPaused = false;
    bool public flashLoanPaused = false;

    event Deposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 collateralSeized);
    event FlashLoanExecuted(address indexed borrower, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event Blacklisted(address indexed user);
    event RemovedFromBlacklist(address indexed user);
    event BorrowingPaused(bool status);
    event RepaymentPaused(bool status);
    event FlashLoanPaused(bool status);

    modifier notBlacklisted() {
        require(!users[msg.sender].isBlacklisted, "User is blacklisted");
        _;
    }

    modifier updateRewards(address user) {
        rewards[user] = rewards[user].add(pendingRewards(user));
        users[user].rewardDebt = block.timestamp;
        _;
    }

    modifier whenBorrowingNotPaused() {
        require(!borrowingPaused, "Borrowing paused");
        _;
    }

    modifier whenRepaymentNotPaused() {
        require(!repaymentPaused, "Repayments paused");
        _;
    }

    modifier whenFlashLoanNotPaused() {
        require(!flashLoanPaused, "Flash loans paused");
        _;
    }

    // ---------- Core Functions ----------

    function depositCollateral() external payable notBlacklisted updateRewards(msg.sender) {
        require(msg.value > 0, "Must deposit collateral");
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        totalCollateral = totalCollateral.add(msg.value);
        emit CollateralDeposited(msg.sender, msg.value);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant notBlacklisted updateRewards(msg.sender) {
        require(amount > 0, "Invalid amount");
        require(users[msg.sender].collateralDeposited >= amount, "Not enough collateral");

        uint256 borrowed = users[msg.sender].borrowed;
        if (borrowed > 0) {
            uint256 requiredCollateral = borrowed.mul(collateralRatio).div(100);
            require(users[msg.sender].collateralDeposited.sub(amount) >= requiredCollateral, "Collateral ratio too low");
        }

        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Collateral withdrawal failed");

        emit CollateralWithdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external whenBorrowingNotPaused nonReentrant notBlacklisted updateRewards(msg.sender) {
        require(amount > 0, "Invalid borrow amount");

        uint256 collateral = users[msg.sender].collateralDeposited;
        uint256 borrowed = users[msg.sender].borrowed.add(amount);
        uint256 requiredCollateral = borrowed.mul(collateralRatio).div(100);

        require(collateral >= requiredCollateral, "Not enough collateral");

        users[msg.sender].borrowed = borrowed;
        totalBorrowed = totalBorrowed.add(amount);

        loans[msg.sender] = Loan({
            principal: borrowed,
            interestAccrued: 0,
            startTime: block.timestamp,
            isActive: true
        });

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Borrow transfer failed");

        emit Borrowed(msg.sender, amount);
    }

    function repay() external payable whenRepaymentNotPaused nonReentrant notBlacklisted updateRewards(msg.sender) {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(msg.value > 0, "Invalid repay amount");

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 interest = loan.principal.mul(baseInterestRate).mul(elapsed).div(365 days).div(100);

        uint256 totalOwed = loan.principal.add(interest);
        require(msg.value >= totalOwed, "Not enough to repay");

        users[msg.sender].borrowed = 0;
        totalBorrowed = totalBorrowed.sub(loan.principal);

        loan.isActive = false;

        uint256 excess = msg.value.sub(totalOwed);
        if (excess > 0) {
            (bool refund, ) = msg.sender.call{value: excess}("");
            require(refund, "Refund failed");
        }

        emit Repaid(msg.sender, msg.value);
    }

    // ---------- New Features ----------

    // Partial liquidation
    function partialLiquidate(address borrower, uint256 repayAmount) external payable nonReentrant notBlacklisted {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");
        require(repayAmount > 0, "Invalid repay amount");

        uint256 borrowed = users[borrower].borrowed;
        uint256 requiredCollateral = borrowed.mul(collateralRatio).div(100);
        require(users[borrower].collateralDeposited < requiredCollateral, "Not liquidatable");

        require(msg.value == repayAmount, "Incorrect repay amount");
        if (repayAmount > loan.principal) repayAmount = loan.principal;

        loan.principal = loan.principal.sub(repayAmount);
        users[borrower].borrowed = users[borrower].borrowed.sub(repayAmount);

        uint256 seizeCollateral = users[borrower].collateralDeposited.mul(repayAmount).div(borrowed);
        users[borrower].collateralDeposited = users[borrower].collateralDeposited.sub(seizeCollateral);
        totalCollateral = totalCollateral.sub(seizeCollateral);

        (bool sent, ) = msg.sender.call{value: seizeCollateral}("");
        require(sent, "Transfer failed");

        emit Liquidated(msg.sender, borrower, seizeCollateral);

        if (loan.principal == 0) {
            loan.isActive = false;
        }
    }

    // Loan extension
    function extendLoan() external payable updateRewards(msg.sender) nonReentrant notBlacklisted {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(msg.value > 0, "Payment must be > 0");

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 interest = loan.principal.mul(baseInterestRate).mul(elapsed).div(365 days).div(100);

        uint256 totalDue = interest;
        require(msg.value >= totalDue, "Not enough to cover interest");

        loan.startTime = block.timestamp;

        if (msg.value > totalDue) {
            (bool refund, ) = msg.sender.call{value: msg.value.sub(totalDue)}("");
            require(refund, "Refund failed");
        }
    }

    // ---------- Flash Loan ----------

    function flashLoan(uint256 amount, address target, bytes calldata data) external whenFlashLoanNotPaused nonReentrant notBlacklisted {
        uint256 balanceBefore = address(this).balance;
        require(amount > 0 && amount <= balanceBefore, "Invalid amount");

        (bool sent, ) = target.call{value: amount}(data);
        require(sent, "Flash loan execution failed");

        uint256 balanceAfter = address(this).balance;
        require(balanceAfter >= balanceBefore, "Flash loan not repaid");

        emit FlashLoanExecuted(msg.sender, amount);
    }

    // ---------- Rewards ----------

    function pendingRewards(address user) public view returns (uint256) {
        uint256 timeDiff = block.timestamp.sub(users[user].rewardDebt);
        return users[user].deposited.mul(rewardRate).mul(timeDiff).div(365 days).div(100);
    }

    function claimRewards() external updateRewards(msg.sender) nonReentrant notBlacklisted {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards");
        rewards[msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: reward}("");
        require(sent, "Reward transfer failed");

        emit RewardClaimed(msg.sender, reward);
    }

    // ---------- Admin Controls ----------

    function setBorrowingPaused(bool status) external onlyOwner {
        borrowingPaused = status;
        emit BorrowingPaused(status);
    }

    function setRepaymentPaused(bool status) external onlyOwner {
        repaymentPaused = status;
        emit RepaymentPaused(status);
    }

    function setFlashLoanPaused(bool status) external onlyOwner {
        flashLoanPaused = status;
        emit FlashLoanPaused(status);
    }

    function blacklist(address user) external onlyOwner {
        users[user].isBlacklisted = true;
        emit Blacklisted(user);
    }

    function removeFromBlacklist(address user) external onlyOwner {
        users[user].isBlacklisted = false;
        emit RemovedFromBlacklist(user);
    }

    receive() external payable {}
}
