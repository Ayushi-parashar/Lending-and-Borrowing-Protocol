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
    uint256 public collateralRatio = 150;
    uint256 public baseInterestRate = 5;
    uint256 public rewardRate = 1;
    uint256 public cooldownPeriod = 1 hours;

    address[] public borrowers;

    event CollateralDeposited(address indexed user, uint256 amount, uint256 total);
    event CollateralWithdrawn(address indexed user, uint256 amount, uint256 remaining);
    event Borrowed(address indexed user, uint256 amount, uint256 totalBorrowed);
    event Repaid(address indexed user, uint256 amount, uint256 remaining);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 collateralSeized);
    event RewardClaimed(address indexed user, uint256 reward);

    modifier updateRewards(address user) {
        if (users[user].collateralDeposited > 0) {
            uint256 timeDiff = block.timestamp.sub(users[user].lastActionTime);
            uint256 reward = users[user].collateralDeposited.mul(rewardRate).mul(timeDiff).div(1e18);
            users[user].rewards = users[user].rewards.add(reward);
        }
        users[user].lastActionTime = block.timestamp;
        _;
    }

    function depositCollateral() external payable nonReentrant updateRewards(msg.sender) {
        require(msg.value > 0, "Must deposit collateral");
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        loans[msg.sender].collateral = loans[msg.sender].collateral.add(msg.value);
        collateralCooldown[msg.sender] = block.timestamp;
        totalCollateral = totalCollateral.add(msg.value);
        emit CollateralDeposited(msg.sender, msg.value, users[msg.sender].collateralDeposited);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant updateRewards(msg.sender) {
        require(amount > 0, "Invalid amount");
        require(block.timestamp.sub(collateralCooldown[msg.sender]) >= cooldownPeriod, "Collateral in cooldown");
        require(users[msg.sender].collateralDeposited >= amount, "Not enough collateral");

        Loan storage loan = loans[msg.sender];
        uint256 requiredCollateral = loan.principal.mul(collateralRatio).div(100);
        uint256 remainingCollateral = users[msg.sender].collateralDeposited.sub(amount);
        require(remainingCollateral >= requiredCollateral, "Collateral ratio breached");

        users[msg.sender].collateralDeposited = remainingCollateral;
        loan.collateral = loan.collateral.sub(amount);
        totalCollateral = totalCollateral.sub(amount);

        payable(msg.sender).transfer(amount);
        emit CollateralWithdrawn(msg.sender, amount, remainingCollateral);
    }

    function borrow(uint256 amount) external nonReentrant whenNotPaused updateRewards(msg.sender) {
        require(amount > 0, "Invalid borrow amount");

        Loan storage loan = loans[msg.sender];
        uint256 collateralValue = users[msg.sender].collateralDeposited;
        uint256 maxBorrow = collateralValue.mul(100).div(collateralRatio);
        require(amount <= maxBorrow.sub(loan.principal), "Exceeds borrow limit");

        loan.principal = loan.principal.add(amount);
        loan.startTime = block.timestamp;
        loan.isActive = true;
        users[msg.sender].borrowed = users[msg.sender].borrowed.add(amount);
        totalBorrowed = totalBorrowed.add(amount);

        borrowers.push(msg.sender);

        payable(msg.sender).transfer(amount);
        emit Borrowed(msg.sender, amount, totalBorrowed);
    }

    function repay() external payable nonReentrant updateRewards(msg.sender) {
        require(msg.value > 0, "Must repay");
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        (uint256 principalReduced, uint256 interestReduced) = _processRepayment(msg.sender, msg.value);
        emit Repaid(msg.sender, msg.value, loan.principal);
    }

    function repayFromCollateral(uint256 amount) external nonReentrant updateRewards(msg.sender) {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(amount > 0, "Invalid amount");
        require(loan.collateral >= amount, "Not enough collateral");

        loan.collateral = loan.collateral.sub(amount);
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);

        (uint256 principalReduced, uint256 interestReduced) = _processRepayment(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, amount, loan.collateral);
    }

    function _processRepayment(address payer, uint256 amount) internal returns (uint256, uint256) {
        Loan storage loan = loans[payer];
        require(loan.isActive, "Loan inactive");

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 interest = loan.principal.mul(baseInterestRate).mul(elapsed).div(365 days).div(100);
        loan.interestAccrued = loan.interestAccrued.add(interest);

        uint256 repayAmount = amount;
        uint256 interestReduced = 0;
        uint256 principalReduced = 0;

        if (repayAmount >= loan.interestAccrued) {
            repayAmount = repayAmount.sub(loan.interestAccrued);
            interestReduced = loan.interestAccrued;
            loan.interestAccrued = 0;

            if (repayAmount >= loan.principal) {
                principalReduced = loan.principal;
                repayAmount = repayAmount.sub(loan.principal);
                loan.principal = 0;
            } else {
                principalReduced = repayAmount;
                loan.principal = loan.principal.sub(repayAmount);
                repayAmount = 0;
            }
        } else {
            interestReduced = repayAmount;
            loan.interestAccrued = loan.interestAccrued.sub(repayAmount);
            repayAmount = 0;
        }

        users[payer].borrowed = users[payer].borrowed.sub(principalReduced);
        totalBorrowed = totalBorrowed.sub(principalReduced);

        if (loan.principal == 0 && loan.interestAccrued == 0) {
            loan.isActive = false;
            _removeBorrower(payer);
        }

        return (principalReduced, interestReduced);
    }

    function liquidate(address borrower) external nonReentrant {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "Loan inactive");

        uint256 collateralValue = loan.collateral;
        uint256 requiredCollateral = loan.principal.mul(collateralRatio).div(100);
        require(collateralValue < requiredCollateral, "Loan healthy");

        uint256 seizedCollateral = collateralValue;
        loan.collateral = 0;
        users[borrower].collateralDeposited = 0;
        totalCollateral = totalCollateral.sub(seizedCollateral);
        loan.isActive = false;

        _removeBorrower(borrower);
        payable(msg.sender).transfer(seizedCollateral);
        emit Liquidated(msg.sender, borrower, seizedCollateral);
    }

    function claimRewards() external nonReentrant updateRewards(msg.sender) {
        uint256 reward = users[msg.sender].rewards;
        require(reward > 0, "No rewards");

        users[msg.sender].rewards = 0;
        payable(msg.sender).transfer(reward);
        emit RewardClaimed(msg.sender, reward);
    }

    function _removeBorrower(address user) internal {
        for (uint i = 0; i < borrowers.length; i++) {
            if (borrowers[i] == user) {
                borrowers[i] = borrowers[borrowers.length - 1];
                borrowers.pop();
                break;
            }
        }
    }

    function getAllBorrowers() external view returns (address[] memory) {
        return borrowers;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
