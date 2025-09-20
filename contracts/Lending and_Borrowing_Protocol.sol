// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract EnhancedProjectV6 is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    struct Loan {
        uint256 principal;
        uint256 interestAccrued;
        uint256 startTime;
        bool isActive;
    }

    struct User {
        uint256 deposited; // savings / deposits
        uint256 borrowed;
        uint256 collateralDeposited;
        uint256 rewardDebt; // timestamp of last reward accounting
        bool isBlacklisted;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;
    mapping(address => uint256) public rewards;

    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public totalCollateral;
    uint256 public baseInterestRate = 5; // percent per year
    uint256 public collateralRatio = 150; // percent (e.g., 150 = 150%)
    uint256 public rewardRate = 100; // percent per year of deposited balance (example)

    // Fine-grained pause controls
    bool public borrowingPaused = false;
    bool public repaymentPaused = false;
    bool public flashLoanPaused = false;

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
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
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    event InterestRateUpdated(uint256 newRate);
    event CollateralRatioUpdated(uint256 newRatio);
    event RewardRateUpdated(uint256 newRate);

    modifier notBlacklisted() {
        require(!users[msg.sender].isBlacklisted, "User is blacklisted");
        _;
    }

    // Ensure reward calculation does not explode for new users: if rewardDebt == 0 => no pending rewards
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

    // Deposit for savings / earning rewards
    function deposit() external payable notBlacklisted updateRewards(msg.sender) {
        require(msg.value > 0, "Deposit must be > 0");
        users[msg.sender].deposited = users[msg.sender].deposited.add(msg.value);
        totalDeposits = totalDeposits.add(msg.value);

        // Initialize rewardDebt if it was zero (updateRewards already sets it)
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external nonReentrant notBlacklisted updateRewards(msg.sender) {
        require(amount > 0, "Invalid withdraw amount");
        require(users[msg.sender].deposited >= amount, "Not enough balance");

        users[msg.sender].deposited = users[msg.sender].deposited.sub(amount);
        totalDeposits = totalDeposits.sub(amount);

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Withdraw failed");

        emit Withdrawn(msg.sender, amount);
    }

    // Collateral-only deposit (used for borrowing)
    function depositCollateral() external payable notBlacklisted updateRewards(msg.sender) {
        require(msg.value > 0, "Must deposit collateral");
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        totalCollateral = totalCollateral.add(msg.value);

        // If rewardDebt was zero, updateRewards modifier set it to now.
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

        // Update loan object (principal = outstanding)
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

    // Calculate interest and late fees included
    function repay() external payable whenRepaymentNotPaused nonReentrant notBlacklisted updateRewards(msg.sender) {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(msg.value > 0, "Invalid repay amount");

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 interest = loan.principal.mul(baseInterestRate).mul(elapsed).div(365 days).div(100);

        uint256 lateFee = calculateLateFee(msg.sender);

        uint256 totalOwed = loan.principal.add(interest).add(lateFee);
        require(msg.value >= totalOwed, "Not enough to repay");

        // Reduce totals
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
        require(borrowed > 0, "Borrower has no debt");

        uint256 requiredCollateral = borrowed.mul(collateralRatio).div(100);
        require(users[borrower].collateralDeposited < requiredCollateral, "Not liquidatable");

        require(msg.value == repayAmount, "Incorrect repay amount");
        if (repayAmount > loan.principal) repayAmount = loan.principal;

        // Reduce loan principal and user borrowed
        loan.principal = loan.principal.sub(repayAmount);
        users[borrower].borrowed = users[borrower].borrowed.sub(repayAmount);
        totalBorrowed = totalBorrowed.sub(repayAmount);

        // Seize proportional collateral
        uint256 seizeCollateral = users[borrower].collateralDeposited.mul(repayAmount).div(borrowed);
        users[borrower].collateralDeposited = users[borrower].collateralDeposited.sub(seizeCollateral);
        totalCollateral = totalCollateral.sub(seizeCollateral);

        // Pay liquidator with seized collateral
        (bool sent, ) = msg.sender.call{value: seizeCollateral}("");
        require(sent, "Transfer failed");

        emit Liquidated(msg.sender, borrower, seizeCollateral);

        if (loan.principal == 0) {
            loan.isActive = false;
        }
    }

    // Loan extension - pay interest to roll the loan forward
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

    // If user.rewardDebt == 0 => user is new/uninitialized => return 0
    function pendingRewards(address user) public view returns (uint256) {
        if (users[user].rewardDebt == 0) return 0;
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

    // Admin adjustable parameters
    function setInterestRate(uint256 newRate) external onlyOwner {
        require(newRate > 0 && newRate < 1000, "Invalid interest rate");
        baseInterestRate = newRate;
        emit InterestRateUpdated(newRate);
    }

    function setCollateralRatio(uint256 newRatio) external onlyOwner {
        require(newRatio >= 100, "Collateral ratio must be >= 100%");
        collateralRatio = newRatio;
        emit CollateralRatioUpdated(newRatio);
    }

    function setRewardRate(uint256 newRate) external onlyOwner {
        require(newRate > 0, "Reward rate must be > 0");
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }

    // Emergency withdraw by owner (use with caution)
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Not enough balance");
        (bool sent, ) = owner().call{value: amount}("");
        require(sent, "Emergency withdraw failed");
        emit EmergencyWithdraw(owner(), amount);
    }

    // ---------- Utility / View Functions ----------

    function getUserInfo(address user) external view returns (
        uint256 deposited,
        uint256 borrowed,
        uint256 collateral,
        uint256 pendingReward,
        bool blacklisted
    ) {
        User memory u = users[user];
        return (
            u.deposited,
            u.borrowed,
            u.collateralDeposited,
            pendingRewards(user),
            u.isBlacklisted
        );
    }

    function getSystemStats() external view returns (
        uint256 totalSystemDeposits,
        uint256 totalSystemBorrowed,
        uint256 totalSystemCollateral
    ) {
        return (totalDeposits, totalBorrowed, totalCollateral);
    }

    // Late fee: if loan active and elapsed > 365 days apply 2% per 30 days overdue (example)
    function calculateLateFee(address borrower) public view returns (uint256) {
        Loan memory loan = loans[borrower];
        if (!loan.isActive) return 0;
        uint256 elapsed = block.timestamp.sub(loan.startTime);
        if (elapsed <= 365 days) return 0;

        uint256 overdue = elapsed.sub(365 days);
        uint256 overdueMonths = overdue.div(30 days);
        if (overdueMonths == 0) return 0;
        // 2% penalty per overdue month
        uint256 fee = loan.principal.mul(overdueMonths).mul(2).div(100);
        return fee;
    }

    // ---------- Receive / Fallback ----------

    receive() external payable {}
    fallback() external payable {}
}
