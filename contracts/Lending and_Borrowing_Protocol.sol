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

    // ------------ Existing core functions (deposit, withdraw, borrow, repay etc.) stay same ------------

    // 🔹 New Owner-Only Functions
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

    // 🔹 View Functions
    function calculatePendingInterest(address borrower) external view returns (uint256) {
        Loan memory loan = loans[borrower];
        if (!loan.isActive || loan.principal == 0) return 0;
        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 interest = loan.principal.mul(baseInterestRate).mul(elapsed).div(365 days).div(100);
        return loan.interestAccrued.add(interest);
    }

    function calculatePendingRewards(address user) external view returns (uint256) {
        User memory u = users[user];
        if (u.collateralDeposited == 0) return u.rewards;
        uint256 timeDiff = block.timestamp.sub(u.lastActionTime);
        uint256 reward = u.collateralDeposited.mul(rewardRate).mul(timeDiff).div(1e18);
        return u.rewards.add(reward);
    }

    // 🔹 Emergency Withdraw (onlyOwner)
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        payable(owner()).transfer(amount);
        emit EmergencyWithdrawal(amount, owner());
    }
}
