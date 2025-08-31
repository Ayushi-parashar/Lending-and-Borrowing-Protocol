// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract EnhancedProjectV3 is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    struct Loan {
        uint256 principal;
        uint256 interestAccrued;
        uint256 startTime;
        bool isActive;
        uint256 collateral;
    }

    struct User {
        uint256 collateralDeposited;
        uint256 borrowed;
        uint256 rewards;
        uint256 lastActionTime;
    }

    mapping(address => Loan) public loans;
    mapping(address => User) public users;
    mapping(address => uint256) public collateralCooldown;

    uint256 public totalCollateral;
    uint256 public totalBorrowed;
    uint256 public collateralRatio = 150; // % requirement
    uint256 public baseInterestRate = 5;  // yearly %
    uint256 public rewardRate = 1;        // reward per second per collateral
    uint256 public cooldownPeriod = 1 hours;

    address[] public borrowers;

    event CollateralDeposited(address indexed user, uint256 amount, uint256 total);
    event CollateralWithdrawn(address indexed user, uint256 amount, uint256 remaining);
    event Borrowed(address indexed user, uint256 amount, uint256 totalBorrowed);
    event Repaid(address indexed user, uint256 amount, uint256 remaining);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 collateralSeized);
    event RewardClaimed(address indexed user, uint256 reward);

    // 🔹 New Events
    event CollateralRatioUpdated(uint256 newRatio);
    event InterestRateUpdated(uint256 newRate);
    event RewardRateUpdated(uint256 newRate);
    event CooldownPeriodUpdated(uint256 newPeriod);
    event EmergencyWithdrawal(uint256 amount, address owner);

    modifier updateRewards(address user) {
        if (users[user].collateralDeposited > 0) {
            uint256 timeDiff = block.timestamp.sub(users[user].lastActionTime);
            uint256 reward = users[user].collateralDeposited.mul(rewardRate).mul(timeDiff).div(1e18);
            users[user].rewards = users[user].rewards.add(reward);
        }
        users[user].lastActionTime = block.timestamp;
        _;
    }

    // ------------ New Core Functions ------------

    function depositCollateral() external payable updateRewards(msg.sender) whenNotPaused {
        require(msg.value > 0, "Deposit must be > 0");
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        totalCollateral = totalCollateral.add(msg.value);
        emit CollateralDeposited(msg.sender, msg.value, users[msg.sender].collateralDeposited);
    }

    function withdrawCollateral(uint256 amount) external updateRewards(msg.sender) nonReentrant {
        require(amount > 0, "Invalid amount");
        require(block.timestamp >= collateralCooldown[msg.sender].add(cooldownPeriod), "Cooldown active");
        require(users[msg.sender].collateralDeposited >= amount, "Not enough collateral");

        // Ensure after withdrawal, collateral ratio is not violated
        uint256 borrowed = users[msg.sender].borrowed;
        if (borrowed > 0) {
            uint256 minRequired = borrowed.mul(collateralRatio).div(100);
            require(users[msg.sender].collateralDeposited.sub(amount) >= minRequired, "Collateral ratio too low");
        }

        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);
        collateralCooldown[msg.sender] = block.timestamp;

        payable(msg.sender).transfer(amount);
        emit CollateralWithdrawn(msg.sender, amount, users[msg.sender].collateralDeposited);
    }

    function borrow(uint256 amount) external updateRewards(msg.sender) nonReentrant {
        require(amount > 0, "Invalid borrow amount");
        uint256 maxBorrow = users[msg.sender].collateralDeposited.mul(100).div(collateralRatio);
        require(users[msg.sender].borrowed.add(amount) <= maxBorrow, "Exceeds borrow limit");

        Loan storage loan = loans[msg.sender];
        if (!loan.isActive) {
            loan.isActive = true;
            borrowers.push(msg.sender);
        }
        loan.principal = loan.principal.add(amount);
        loan.startTime = block.timestamp;
        loan.collateral = users[msg.sender].collateralDeposited;

        users[msg.sender].borrowed = users[msg.sender].borrowed.add(amount);
        totalBorrowed = totalBorrowed.add(amount);

        payable(msg.sender).transfer(amount);
        emit Borrowed(msg.sender, amount, users[msg.sender].borrowed);
    }

    function repay() external payable updateRewards(msg.sender) nonReentrant {
        require(msg.value > 0, "Repay amount must be > 0");
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 interest = loan.principal.mul(baseInterestRate).mul(elapsed).div(365 days).div(100);
        uint256 totalDue = loan.principal.add(interest);

        if (msg.value >= totalDue) {
            // full repayment
            uint256 excess = msg.value.sub(totalDue);
            if (excess > 0) payable(msg.sender).transfer(excess);
            users[msg.sender].borrowed = 0;
            loan.isActive = false;
            loan.principal = 0;
            loan.interestAccrued = 0;
        } else {
            // partial repayment
            loan.principal = loan.principal.sub(msg.value);
            users[msg.sender].borrowed = users[msg.sender].borrowed.sub(msg.value);
        }

        totalBorrowed = totalBorrowed.sub(msg.value);
        emit Repaid(msg.sender, msg.value, users[msg.sender].borrowed);
    }

    function liquidate(address borrower) external nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");

        uint256 borrowed = users[borrower].borrowed;
        uint256 requiredCollateral = borrowed.mul(collateralRatio).div(100);
        require(users[borrower].collateralDeposited < requiredCollateral, "Not liquidatable");

        uint256 seizedCollateral = users[borrower].collateralDeposited;
        users[borrower].collateralDeposited = 0;
        users[borrower].borrowed = 0;
        loan.isActive = false;

        payable(msg.sender).transfer(seizedCollateral);
        emit Liquidated(msg.sender, borrower, seizedCollateral);
    }

    function claimRewards() external updateRewards(msg.sender) {
        uint256 reward = users[msg.sender].rewards;
        require(reward > 0, "No rewards to claim");

        users[msg.sender].rewards = 0;
        payable(msg.sender).transfer(reward);
        emit RewardClaimed(msg.sender, reward);
    }

    // ------------ View Functions ------------

    function getUserSummary(address user) external view returns (uint256 collateral, uint256 borrowed, uint256 pendingInterest, uint256 pendingRewards) {
        collateral = users[user].collateralDeposited;
        borrowed = users[user].borrowed;

        Loan memory loan = loans[user];
        if (loan.isActive && loan.principal > 0) {
            uint256 elapsed = block.timestamp.sub(loan.startTime);
            pendingInterest = loan.principal.mul(baseInterestRate).mul(elapsed).div(365 days).div(100);
        }

        if (users[user].collateralDeposited > 0) {
            uint256 timeDiff = block.timestamp.sub(users[user].lastActionTime);
            uint256 reward = users[user].collateralDeposited.mul(rewardRate).mul(timeDiff).div(1e18);
            pendingRewards = users[user].rewards.add(reward);
        } else {
            pendingRewards = users[user].rewards;
        }
    }

    // ------------ Owner Functions ------------

    function setCollateralRatio(uint256 newRatio) external onlyOwner {
        require(newRatio >= 100, "Ratio must be >= 100");
        collateralRatio = newRatio;
        emit CollateralRatioUpdated(newRatio);
    }

    function setInterestRate(uint256 newRate) external onlyOwner {
        baseInterestRate = newRate;
        emit InterestRateUpdated(newRate);
    }

    function setRewardRate(uint256 newRate) external onlyOwner {
        rewardRate = newRate;
        emit RewardRateUpdated(newRate);
    }

    function setCooldownPeriod(uint256 newPeriod) external onlyOwner {
        cooldownPeriod = newPeriod;
        emit CooldownPeriodUpdated(newPeriod);
    }

    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        payable(owner()).transfer(amount);
        emit EmergencyWithdrawal(amount, owner());
    }
}
