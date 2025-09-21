// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract EnhancedProjectV7 is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    struct Loan {
        uint256 principal;
        uint256 interestAccrued;
        uint256 startTime;
        bool isActive;
    }

    struct User {
        uint256 deposited; // available deposits (savings)
        uint256 borrowed;
        uint256 collateralDeposited;
        uint256 rewardDebt; // timestamp of last reward accounting
        bool isBlacklisted;
        address referrer; // referral referrer
    }

    struct FixedDeposit {
        uint256 amount;
        uint256 unlockTime;
        uint256 rateMultiplier; // expressed as percent, e.g., 150 = 1.5x rewardRate
        bool active;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;
    mapping(address => uint256) public rewards;
    mapping(address => FixedDeposit) public fixedDeposits;

    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public totalCollateral;
    uint256 public baseInterestRate = 5; // percent per year (base)
    uint256 public collateralRatio = 150; // percent (e.g., 150 = 150%)
    uint256 public rewardRate = 100; // percent per year of deposited balance (example)
    uint256 public referralRate = 1; // percent of deposit to give to referrer (1%)

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
    event RewardStaked(address indexed user, uint256 amount);
    event Blacklisted(address indexed user);
    event RemovedFromBlacklist(address indexed user);
    event BorrowingPaused(bool status);
    event RepaymentPaused(bool status);
    event FlashLoanPaused(bool status);
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    event InterestRateUpdated(uint256 newRate);
    event CollateralRatioUpdated(uint256 newRatio);
    event RewardRateUpdated(uint256 newRate);
    event ReferralRateUpdated(uint256 newRate);
    event FixedDepositCreated(address indexed user, uint256 amount, uint256 unlockTime, uint256 multiplier);
    event FixedDepositWithdrawn(address indexed user, uint256 amount);
    event LoanForgiven(address indexed borrower, uint256 forgivenAmount);

    modifier notBlacklisted() {
        require(!users[msg.sender].isBlacklisted, "User is blacklisted");
        _; 
    }

    // Ensure reward calculation does not explode for new users: if rewardDebt == 0 => no pending rewards
    modifier updateRewards(address userAddr) {
        rewards[userAddr] = rewards[userAddr].add(pendingRewards(userAddr));
        users[userAddr].rewardDebt = block.timestamp;
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

    // ETH deposit (savings) - optional referrer argument
    function depositWithReferrer(address referrer) external payable notBlacklisted updateRewards(msg.sender) {
        require(msg.value > 0, "Deposit must be > 0");

        // set referrer if not already set and referrer isn't the user themself
        if (users[msg.sender].referrer == address(0) && referrer != address(0) && referrer != msg.sender) {
            users[msg.sender].referrer = referrer;
        }

        // Deposit
        users[msg.sender].deposited = users[msg.sender].deposited.add(msg.value);
        totalDeposits = totalDeposits.add(msg.value);

        // referral reward
        if (users[msg.sender].referrer != address(0) && referralRate > 0) {
            uint256 referralReward = msg.value.mul(referralRate).div(100);
            // credit referrer rewards (not direct transfer to avoid reentrancy)
            rewards[users[msg.sender].referrer] = rewards[users[msg.sender].referrer].add(referralReward);
        }

        emit Deposited(msg.sender, msg.value);
    }

    // backward-compatible deposit (no referrer)
    function deposit() external payable {
        depositWithReferrer(address(0));
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
        uint256 rate = getCurrentInterestRate(); // dynamic
        uint256 interest = loan.principal.mul(rate).mul(elapsed).div(365 days).div(100);

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
        uint256 rate = getCurrentInterestRate(); // dynamic
        uint256 interest = loan.principal.mul(rate).mul(elapsed).div(365 days).div(100);

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
    function pendingRewards(address userAddr) public view returns (uint256) {
        if (users[userAddr].rewardDebt == 0) return 0;

        uint256 timeDiff = block.timestamp.sub(users[userAddr].rewardDebt);

        // base reward from deposited funds
        uint256 basePending = users[userAddr].deposited.mul(rewardRate).mul(timeDiff).div(365 days).div(100);

        // if user has an active fixed deposit, apply multiplier for that portion
        FixedDeposit memory fd = fixedDeposits[userAddr];
        uint256 fdPending = 0;
        if (fd.active && fd.amount > 0) {
            // reward multiplier: rateMultiplier is percent (e.g., 150 => 1.5x)
            fdPending = fd.amount.mul(rewardRate).mul(fd.rateMultiplier).mul(timeDiff).div(365 days).div(100).div(100);
            // Note: dividing by 100 twice because rateMultiplier is a percent (e.g., 150)
        }

        // avoid double-counting: basePending currently uses users[user].deposited only.
        // fixed deposit's reward is calculated separately (fd.amount is not included in users.deposited)
        return basePending.add(fdPending);
    }

    function claimRewards() external updateRewards(msg.sender) nonReentrant notBlacklisted {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards");
        rewards[msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: reward}("");
        require(sent, "Reward transfer failed");

        emit RewardClaimed(msg.sender, reward);
    }

    // Stake rewards into deposits (compound)
    function stakeRewards() external updateRewards(msg.sender) nonReentrant notBlacklisted {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards to stake");
        rewards[msg.sender] = 0;

        users[msg.sender].deposited = users[msg.sender].deposited.add(reward);
        totalDeposits = totalDeposits.add(reward);

        emit RewardStaked(msg.sender, reward);
    }

    // ---------- Fixed Deposit (Time-locked) ----------

    // Create a single fixed deposit per user (simple implementation)
    // rateMultiplier example: 150 => 1.5x reward rate, must be >= 100
    function createFixedDeposit(uint256 lockDurationSeconds, uint256 rateMultiplier) external payable notBlacklisted updateRewards(msg.sender) {
        require(msg.value > 0, "Must deposit amount");
        require(lockDurationSeconds >= 30 days, "Minimum 30 days");
        require(rateMultiplier >= 100, "Multiplier must be >= 100");

        FixedDeposit storage fd = fixedDeposits[msg.sender];
        require(!fd.active, "Existing fixed deposit active");

        fd.amount = msg.value;
        fd.unlockTime = block.timestamp.add(lockDurationSeconds);
        fd.rateMultiplier = rateMultiplier;
        fd.active = true;

        totalDeposits = totalDeposits.add(msg.value);

        emit FixedDepositCreated(msg.sender, msg.value, fd.unlockTime, rateMultiplier);
    }

    // Withdraw fixed deposit after unlock
    function withdrawFixedDeposit() external nonReentrant notBlacklisted updateRewards(msg.sender) {
        FixedDeposit storage fd = fixedDeposits[msg.sender];
        require(fd.active, "No active fixed deposit");
        require(block.timestamp >= fd.unlockTime, "Fixed deposit still locked");

        uint256 amount = fd.amount;
        fd.amount = 0;
        fd.active = false;
        fd.unlockTime = 0;
        fd.rateMultiplier = 0;

        totalDeposits = totalDeposits.sub(amount);

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Fixed deposit withdrawal failed");

        emit FixedDepositWithdrawn(msg.sender, amount);
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
    function setBaseInterestRate(uint256 newRate) external onlyOwner {
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

    function setReferralRate(uint256 newRate) external onlyOwner {
        require(newRate <= 10, "Referral too high"); // example cap
        referralRate = newRate;
        emit ReferralRateUpdated(newRate);
    }

    // Emergency withdraw by owner (use with caution)
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Not enough balance");
        (bool sent, ) = owner().call{value: amount}("");
        require(sent, "Emergency withdraw failed");
        emit EmergencyWithdraw(owner(), amount);
    }

    // Admin: forgive (part of) a loan (emergency/support)
    function forgiveLoan(address borrower, uint256 amount) external onlyOwner {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");
        require(amount > 0, "Invalid amount");

        if (amount >= loan.principal) {
            uint256 forgiven = loan.principal;
            totalBorrowed = totalBorrowed.sub(loan.principal);
            loan.principal = 0;
            loan.isActive = false;
            users[borrower].borrowed = 0;
            emit LoanForgiven(borrower, forgiven);
        } else {
            loan.principal = loan.principal.sub(amount);
            totalBorrowed = totalBorrowed.sub(amount);
            users[borrower].borrowed = users[borrower].borrowed.sub(amount);
            emit LoanForgiven(borrower, amount);
        }
    }

    // ---------- Utility / View Functions ----------

    function getUserInfo(address user) external view returns (
        uint256 deposited,
        uint256 borrowed,
        uint256 collateral,
        uint256 pendingReward,
        bool blacklisted,
        address referrer,
        bool hasFixedDeposit,
        uint256 fixedDepositAmount,
        uint256 fixedDepositUnlockTime
    ) {
        User memory u = users[user];
        FixedDeposit memory fd = fixedDeposits[user];
        return (
            u.deposited,
            u.borrowed,
            u.collateralDeposited,
            pendingRewards(user),
            u.isBlacklisted,
            u.referrer,
            fd.active,
            fd.amount,
            fd.unlockTime
        );
    }

    function getSystemStats() external view returns (
        uint256 totalSystemDeposits,
        uint256 totalSystemBorrowed,
        uint256 totalSystemCollateral
    ) {
        return (totalDeposits, totalBorrowed, totalCollateral);
    }

    // Health Factor example:
    // Returns 0 if no borrowed amount, otherwise health factor scaled as percent
    // healthFactor = (collateralDeposited * 100) / requiredCollateral
    // If < 100 => below required collateral
    function getHealthFactor(address userAddr) external view returns (uint256) {
        uint256 borrowed = users[userAddr].borrowed;
        if (borrowed == 0) return type(uint256).max;
        uint256 requiredCollateral = borrowed.mul(collateralRatio).div(100);
        if (requiredCollateral == 0) return type(uint256).max;
        return users[userAddr].collateralDeposited.mul(100).div(requiredCollateral);
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

    // Dynamic interest rate based on utilization (totalBorrowed / totalDeposits)
    // Example model:
    // utilization < 50% -> baseInterestRate
    // 50% <= utilization < 80% -> base + 2
    // 80% <= utilization < 95% -> base + 5
    // >=95% -> base + 10
    function getCurrentInterestRate() public view returns (uint256) {
        if (totalDeposits == 0) return baseInterestRate;
        uint256 utilization = totalBorrowed.mul(100).div(totalDeposits); // percent
        if (utilization < 50) {
            return baseInterestRate;
        } else if (utilization < 80) {
            return baseInterestRate.add(2);
        } else if (utilization < 95) {
            return baseInterestRate.add(5);
        } else {
            return baseInterestRate.add(10);
        }
    }

    // ---------- Receive / Fallback ----------
    receive() external payable {}
    fallback() external payable {}
}
