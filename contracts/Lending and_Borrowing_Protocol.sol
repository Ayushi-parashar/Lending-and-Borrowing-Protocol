// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract EnhancedProjectV4 is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    struct Loan {
        uint256 principal;
        uint256 interestAccrued;
        uint256 startTime;
        bool isActive;
        uint256 collateralAtBorrow;
    }

    struct User {
        uint256 collateralDeposited;
        uint256 borrowed;
        uint256 rewards;
        uint256 lastActionTime;
    }

    // Core storage
    mapping(address => Loan) public loans;
    mapping(address => User) public users;
    mapping(address => uint256) public collateralCooldown;
    mapping(address => uint256) public stakedCollateral;
    mapping(address => bool) public whitelisted;
    mapping(address => bool) public blacklisted;

    uint256 public totalCollateral;
    uint256 public totalBorrowed;
    uint256 public collateralRatio = 150; // % requirement
    uint256 public baseInterestRate = 5;  // yearly %
    uint256 public rewardRate = 1;        // reward per second per collateral (units scaled by 1e18)
    uint256 public cooldownPeriod = 1 hours;
    uint256 public penaltyRate = 2;      // % per overdue week (applies after 365 days)
    uint256 public flashLoanFeeBP = 50;  // basis points (50 = 0.5%)

    address[] public borrowers;

    // Events
    event CollateralDeposited(address indexed user, uint256 amount, uint256 total);
    event CollateralWithdrawn(address indexed user, uint256 amount, uint256 remaining);
    event Borrowed(address indexed user, uint256 amount, uint256 totalBorrowed);
    event Repaid(address indexed user, uint256 amount, uint256 remaining);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 collateralSeized);
    event RewardClaimed(address indexed user, uint256 reward);

    event CollateralRatioUpdated(uint256 newRatio);
    event InterestRateUpdated(uint256 newRate);
    event RewardRateUpdated(uint256 newRate);
    event CooldownPeriodUpdated(uint256 newPeriod);
    event PenaltyRateUpdated(uint256 newRate);
    event FlashLoanFeeUpdated(uint256 newFeeBP);
    event EmergencyWithdrawal(uint256 amount, address owner);

    event CollateralStaked(address indexed user, uint256 amount);
    event CollateralUnstaked(address indexed user, uint256 amount);

    event Whitelisted(address indexed user);
    event Blacklisted(address indexed user);
    event WhitelistRemoved(address indexed user);
    event BlacklistRemoved(address indexed user);

    event FlashLoanExecuted(address indexed borrower, uint256 amount, uint256 fee);
    event LoanTransferred(address from, address to, uint256 principalAmount);

    // ---------- Modifiers ----------
    modifier updateRewards(address user) {
        // update accumulated rewards up to now
        if (users[user].collateralDeposited > 0) {
            uint256 timeDiff = block.timestamp.sub(users[user].lastActionTime);
            // rewardRate assumed in "tokens per second per wei-collateral" scaled by 1e18
            uint256 reward = users[user].collateralDeposited.mul(rewardRate).mul(timeDiff).div(1e18);
            users[user].rewards = users[user].rewards.add(reward);
        }
        users[user].lastActionTime = block.timestamp;
        _;
    }

    modifier notBlacklisted() {
        require(!blacklisted[msg.sender], "Blacklisted");
        _;
    }

    modifier onlyWhitelistedIfSet() {
        // If whitelist has any addresses (owner-managed), restrict to whitelist.
        // We'll treat whitelist as opt-in: if whitelisted mapping empty for everyone, it shouldn't block.
        // For simplicity, owner can enforce by adding addresses; if any whitelisted address exists and msg.sender not whitelisted, block.
        bool anyWhitelisted = false;
        // expensive to check all addresses; instead owner should toggle a switch in real product.
        // For now: only apply explicit whitelisting check if the caller is not whitelisted and they try to call a 'whitelist-only' API.
        _;
    }

    // ---------- Core functions ----------
    receive() external payable {} // allow contract to receive ETH

    function depositCollateral() external payable updateRewards(msg.sender) whenNotPaused notBlacklisted {
        require(msg.value > 0, "Deposit must be > 0");
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        totalCollateral = totalCollateral.add(msg.value);
        emit CollateralDeposited(msg.sender, msg.value, users[msg.sender].collateralDeposited);
    }

    function withdrawCollateral(uint256 amount) external updateRewards(msg.sender) nonReentrant notBlacklisted {
        require(amount > 0, "Invalid amount");
        require(block.timestamp >= collateralCooldown[msg.sender].add(cooldownPeriod), "Cooldown active");
        require(users[msg.sender].collateralDeposited >= amount, "Not enough collateral");

        uint256 borrowed = users[msg.sender].borrowed;
        if (borrowed > 0) {
            uint256 minRequired = borrowed.mul(collateralRatio).div(100);
            require(users[msg.sender].collateralDeposited.sub(amount) >= minRequired, "Collateral ratio too low");
        }

        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);
        collateralCooldown[msg.sender] = block.timestamp;

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        emit CollateralWithdrawn(msg.sender, amount, users[msg.sender].collateralDeposited);
    }

    function stakeCollateral(uint256 amount) external updateRewards(msg.sender) notBlacklisted {
        require(amount > 0, "Invalid amount");
        require(users[msg.sender].collateralDeposited >= amount, "Not enough collateral to stake");
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        stakedCollateral[msg.sender] = stakedCollateral[msg.sender].add(amount);
        emit CollateralStaked(msg.sender, amount);
    }

    function unstakeCollateral(uint256 amount) external updateRewards(msg.sender) notBlacklisted {
        require(amount > 0, "Invalid amount");
        require(stakedCollateral[msg.sender] >= amount, "Not enough staked collateral");
        stakedCollateral[msg.sender] = stakedCollateral[msg.sender].sub(amount);
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(amount);
        emit CollateralUnstaked(msg.sender, amount);
    }

    function borrow(uint256 amount) external updateRewards(msg.sender) nonReentrant whenNotPaused notBlacklisted {
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
        loan.collateralAtBorrow = users[msg.sender].collateralDeposited;

        users[msg.sender].borrowed = users[msg.sender].borrowed.add(amount);
        totalBorrowed = totalBorrowed.add(amount);

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        emit Borrowed(msg.sender, amount, users[msg.sender].borrowed);
    }

    function repay() external payable updateRewards(msg.sender) nonReentrant notBlacklisted {
        require(msg.value > 0, "Repay amount must be > 0");
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 interest = loan.principal.mul(baseInterestRate).mul(elapsed).div(365 days).div(100);

        uint256 penalty = calculatePenalty(msg.sender); // penalty may be zero
        uint256 totalDue = loan.principal.add(interest).add(penalty);

        if (msg.value >= totalDue) {
            // full repayment
            uint256 excess = msg.value.sub(totalDue);
            // principal repaid equals loan.principal
            uint256 principalRepaid = loan.principal;

            // reset loan and user borrowed
            users[msg.sender].borrowed = users[msg.sender].borrowed.sub(principalRepaid);
            loan.isActive = false;
            loan.principal = 0;
            loan.interestAccrued = 0;

            // update totals
            if (totalBorrowed >= principalRepaid) {
                totalBorrowed = totalBorrowed.sub(principalRepaid);
            } else {
                totalBorrowed = 0;
            }

            if (excess > 0) {
                (bool sentExcess, ) = msg.sender.call{value: excess}("");
                require(sentExcess, "Refund failed");
            }
        } else {
            // partial repayment: we apply amount to interest+penalty first, then to principal
            uint256 remaining = msg.value;

            // pay interest up to interest
            if (remaining >= interest) {
                remaining = remaining.sub(interest);
                interest = 0;
            } else {
                interest = interest.sub(remaining);
                remaining = 0;
            }

            // pay penalty
            if (remaining > 0) {
                if (remaining >= penalty) {
                    remaining = remaining.sub(penalty);
                    penalty = 0;
                } else {
                    penalty = penalty.sub(remaining);
                    remaining = 0;
                }
            }

            // remaining goes to principal reduction
            if (remaining > 0) {
                uint256 principalReduction = remaining;
                if (principalReduction > loan.principal) {
                    principalReduction = loan.principal;
                }
                loan.principal = loan.principal.sub(principalReduction);
                users[msg.sender].borrowed = users[msg.sender].borrowed.sub(principalReduction);

                if (totalBorrowed >= principalReduction) {
                    totalBorrowed = totalBorrowed.sub(principalReduction);
                } else {
                    totalBorrowed = 0;
                }
            }
        }

        emit Repaid(msg.sender, msg.value, users[msg.sender].borrowed);
    }

    function calculatePenalty(address borrower) public view returns (uint256) {
        Loan memory loan = loans[borrower];
        if (!loan.isActive) return 0;
        uint256 elapsed = block.timestamp.sub(loan.startTime);
        if (elapsed <= 365 days) return 0;
        uint256 overdue = elapsed.sub(365 days);
        uint256 overdueWeeks = overdue.div(7 days);
        if (overdueWeeks == 0) return 0;
        // penaltyRate is percent per overdue week
        return loan.principal.mul(penaltyRate).mul(overdueWeeks).div(100);
    }

    function liquidate(address borrower) external nonReentrant notBlacklisted {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");

        uint256 borrowed = users[borrower].borrowed;
        uint256 requiredCollateral = borrowed.mul(collateralRatio).div(100);
        require(users[borrower].collateralDeposited < requiredCollateral, "Not liquidatable");

        uint256 seizedCollateral = users[borrower].collateralDeposited;

        // reset borrower data
        users[borrower].collateralDeposited = 0;
        users[borrower].borrowed = 0;
        loan.isActive = false;
        loan.principal = 0;
        loan.interestAccrued = 0;

        // adjust totals conservatively
        if (totalCollateral >= seizedCollateral) totalCollateral = totalCollateral.sub(seizedCollateral);
        // Note: totalBorrowed may remain conservative; owner may reconcile in real system.

        (bool sent, ) = msg.sender.call{value: seizedCollateral}("");
        require(sent, "Transfer failed");

        emit Liquidated(msg.sender, borrower, seizedCollateral);
    }

    function claimRewards() external updateRewards(msg.sender) nonReentrant notBlacklisted {
        uint256 reward = users[msg.sender].rewards;
        require(reward > 0, "No rewards to claim");
        users[msg.sender].rewards = 0;

        (bool success, ) = msg.sender.call{value: reward}("");
        require(success, "Reward transfer failed");

        emit RewardClaimed(msg.sender, reward);
    }

    // ---------- Flash loan ----------
    // Borrower must return funds + fee within same tx (i.e., call must result in contract having >= balanceBefore + fee)
    function flashLoan(uint256 amount, bytes calldata data) external nonReentrant notBlacklisted whenNotPaused {
        require(amount > 0, "Invalid amount");
        require(amount <= address(this).balance, "Not enough liquidity");

        uint256 fee = amount.mul(flashLoanFeeBP).div(10000); // basis points
        uint256 balanceBefore = address(this).balance;

        // send funds and call borrower fallback/receive with data
        (bool sent, ) = msg.sender.call{value: amount}(data);
        require(sent, "Flash loan transfer failed");

        // After callback, contract must have repaid + fee
        require(address(this).balance >= balanceBefore.add(fee), "Flash loan not repaid with fee");

        emit FlashLoanExecuted(msg.sender, amount, fee);
    }

    // ---------- Loan transfer ----------
    // Transfer loan obligations from msg.sender to `to`. Recipient must accept and not already have active loan.
    function transferLoan(address to) external nonReentrant notBlacklisted {
        require(to != address(0), "Invalid recipient");
        require(loans[msg.sender].isActive, "No active loan to transfer");
        require(!loans[to].isActive, "Recipient already has an active loan");
        require(!blacklisted[to], "Recipient blacklisted");

        loans[to] = loans[msg.sender];
        loans[msg.sender].isActive = false;
        loans[msg.sender].principal = 0;
        loans[msg.sender].interestAccrued = 0;

        // Move borrowed accounting
        uint256 principalAmount = users[msg.sender].borrowed;
        users[to].borrowed = users[to].borrowed.add(principalAmount);
        users[msg.sender].borrowed = 0;

        // Move collateral association - keep collateral as-is (owner must manage if changing)
        // In this simple model, collateral stays with original account; better flows would move collateral.
        emit LoanTransferred(msg.sender, to, principalAmount);
    }

    // ---------- View functions ----------
    function getUserSummary(address user) external view returns (uint256 collateral, uint256 borrowed, uint256 pendingInterest, uint256 pendingRewards, uint256 pendingPenalty) {
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

        pendingPenalty = calculatePenalty(user);
    }

    // ---------- Owner functions ----------
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

    function setPenaltyRate(uint256 newRate) external onlyOwner {
        penaltyRate = newRate;
        emit PenaltyRateUpdated(newRate);
    }

    function setFlashLoanFeeBP(uint256 newFeeBP) external onlyOwner {
        flashLoanFeeBP = newFeeBP;
        emit FlashLoanFeeUpdated(newFeeBP);
    }

    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        (bool sent, ) = owner().call{value: amount}("");
        require(sent, "Withdraw failed");
        emit EmergencyWithdrawal(amount, owner());
    }

    // ---------- Admin: whitelist / blacklist ----------
    function addToWhitelist(address user) external onlyOwner {
        whitelisted[user] = true;
        emit Whitelisted(user);
    }
    function removeFromWhitelist(address user) external onlyOwner {
        whitelisted[user] = false;
        emit WhitelistRemoved(user);
    }

    function addToBlacklist(address user) external onlyOwner {
        blacklisted[user] = true;
        emit Blacklisted(user);
    }
    function removeFromBlacklist(address user) external onlyOwner {
        blacklisted[user] = false;
        emit BlacklistRemoved(user);
    }

    // ---------- Helpers ----------
    function getBorrowers() external view returns (address[] memory) {
        return borrowers;
    }
}
