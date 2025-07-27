// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract EnhancedProjectV2 is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    uint256 public constant COLLATERAL_RATIO = 150;
    uint256 public constant LIQUIDATION_THRESHOLD = 120;
    uint256 public baseInterestRate = 5;
    uint256 public constant SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
    uint256 public constant LIQUIDATION_BONUS = 5;
    uint256 public constant MAX_LOAN_DURATION = 365 days;
    uint256 public flashLoanFee = 9;
    uint256 public rewardRate = 100;
    uint256 public earlyWithdrawalPenalty = 2;
    uint256 public withdrawalTimelock = 7 days;

    bool public borrowingPaused = false;
    bool public lendingPaused = false;

    modifier whenBorrowingNotPaused() {
        require(!borrowingPaused, "Borrowing is paused");
        _;
    }

    modifier whenLendingNotPaused() {
        require(!lendingPaused, "Lending is paused");
        _;
    }

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => bool) public authorizedLiquidators;
    mapping(address => bool) public whitelist;
    bool public isWhitelistEnabled = false;

    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 timestamp;
        uint256 interestRate;
        uint256 duration;
        bool isActive;
    }

    struct User {
        uint256 deposited;
        uint256 borrowed;
        uint256 collateralDeposited;
        bool hasActiveLoan;
        uint256 lastDepositTime;
    }

    struct LoanHistory {
        uint256 amount;
        uint256 interestPaid;
        uint256 duration;
        uint256 repaidAt;
    }

    struct InterestTier {
        uint256 utilizationThreshold;
        uint256 interestRate;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;
    mapping(address => LoanHistory[]) public loanHistories;

    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public totalCollateral;
    uint256 public protocolFees;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    InterestTier[] public interestTiers;

    interface IFlashLoanReceiver {
        function executeOperation(uint256 amount, bytes calldata params) external;
    }

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 collateral, uint256 duration);
    event Repaid(address indexed user, uint256 amount, uint256 interest);
    event CollateralAdded(address indexed user, uint256 amount);
    event Liquidated(address indexed user, uint256 collateral, uint256 debt, address liquidator);
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event RewardClaimed(address indexed user, uint256 amount);
    event InterestRateUpdated(uint256 newRate);
    event LiquidatorAuthorized(address indexed liquidator, bool authorized);
    event PartialRepayment(address indexed user, uint256 amount);
    event LoanExtended(address indexed user, uint256 newDuration);
    event DonationReceived(address indexed donor, uint256 amount);
    event WhitelistUpdated(address indexed user, bool status);
    event WhitelistModeUpdated(bool enabled);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    modifier onlyWhitelisted() {
        require(!isWhitelistEnabled || whitelist[msg.sender], "Not whitelisted");
        _;
    }

    constructor() Ownable(msg.sender) {
        interestTiers.push(InterestTier(50, 3));
        interestTiers.push(InterestTier(80, 5));
        interestTiers.push(InterestTier(95, 8));
        interestTiers.push(InterestTier(100, 15));
        lastUpdateTime = block.timestamp;
    }

    function setBorrowingPaused(bool _paused) external onlyOwner {
        borrowingPaused = _paused;
    }

    function setLendingPaused(bool _paused) external onlyOwner {
        lendingPaused = _paused;
    }

    function deposit() external payable nonReentrant whenNotPaused whenLendingNotPaused updateReward(msg.sender) onlyWhitelisted {
        require(msg.value > 0, "Deposit must be > 0");
        users[msg.sender].deposited += msg.value;
        users[msg.sender].lastDepositTime = block.timestamp;
        totalDeposits += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        require(_amount > 0, "Withdraw > 0");
        require(users[msg.sender].deposited >= _amount, "Insufficient balance");
        require(address(this).balance >= _amount, "Contract liquidity low");

        uint256 amountToTransfer = _amount;
        if (block.timestamp < users[msg.sender].lastDepositTime + withdrawalTimelock) {
            uint256 penalty = _amount * earlyWithdrawalPenalty / 100;
            amountToTransfer -= penalty;
            protocolFees += penalty;
        }

        users[msg.sender].deposited -= _amount;
        totalDeposits -= _amount;
        payable(msg.sender).transfer(amountToTransfer);
        emit Withdrawn(msg.sender, amountToTransfer);
    }

    function emergencyWithdraw() external whenPaused nonReentrant {
        uint256 amount = users[msg.sender].deposited;
        require(amount > 0, "Nothing to withdraw");
        users[msg.sender].deposited = 0;
        totalDeposits -= amount;
        payable(msg.sender).transfer(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function donate() external payable {
        require(msg.value > 0, "Donation must be > 0");
        protocolFees += msg.value;
        emit DonationReceived(msg.sender, msg.value);
    }

    function borrow(uint256 amount, uint256 duration) external payable nonReentrant whenNotPaused whenBorrowingNotPaused updateReward(msg.sender) {
        require(!users[msg.sender].hasActiveLoan, "Already have a loan");
        require(msg.value > 0, "Collateral required");
        require(amount > 0, "Invalid borrow amount");

        uint256 requiredCollateral = amount.mul(COLLATERAL_RATIO).div(100);
        require(msg.value >= requiredCollateral, "Insufficient collateral");

        uint256 interestRate = getInterestRate();
        loans[msg.sender] = Loan({
            amount: amount,
            collateral: msg.value,
            timestamp: block.timestamp,
            interestRate: interestRate,
            duration: duration,
            isActive: true
        });

        users[msg.sender].borrowed = amount;
        users[msg.sender].collateralDeposited = msg.value;
        users[msg.sender].hasActiveLoan = true;
        totalBorrowed += amount;
        totalCollateral += msg.value;

        payable(msg.sender).transfer(amount);
        emit Borrowed(msg.sender, amount, msg.value, duration);
    }

    function repayLoan() external payable nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(SECONDS_PER_YEAR).div(100);
        uint256 totalDue = loan.amount.add(interest);

        require(msg.value >= totalDue, "Insufficient repayment");
        uint256 excess = msg.value.sub(totalDue);
        if (excess > 0) payable(msg.sender).transfer(excess);

        protocolFees += interest;
        users[msg.sender].borrowed = 0;
        users[msg.sender].hasActiveLoan = false;
        totalBorrowed -= loan.amount;
        uint256 collateral = loan.collateral;
        totalCollateral -= collateral;
        loan.isActive = false;

        loanHistories[msg.sender].push(LoanHistory(loan.amount, interest, loan.duration, block.timestamp));
        delete loans[msg.sender];

        payable(msg.sender).transfer(collateral);
        emit Repaid(msg.sender, loan.amount, interest);
    }

    function partialRepayLoan(uint256 repayAmount) external payable nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(repayAmount > 0 && repayAmount <= loan.amount, "Invalid repay amount");

        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(SECONDS_PER_YEAR).div(100);
        uint256 totalDue = repayAmount.add(interest.mul(repayAmount).div(loan.amount));

        require(msg.value >= totalDue, "Insufficient repayment");

        loan.amount = loan.amount.sub(repayAmount);
        users[msg.sender].borrowed = loan.amount;
        totalBorrowed = totalBorrowed.sub(repayAmount);
        protocolFees = protocolFees.add(interest.mul(repayAmount).div(loan.amount));

        emit PartialRepayment(msg.sender, repayAmount);
    }

    function extendLoan(uint256 additionalTime) external {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(loan.duration + additionalTime <= MAX_LOAN_DURATION, "Exceeds max duration");

        loan.duration += additionalTime;
        emit LoanExtended(msg.sender, loan.duration);
    }

    function claimRewards() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards");
        rewards[msg.sender] = 0;
        payable(msg.sender).transfer(reward);
        emit RewardClaimed(msg.sender, reward);
    }

    function withdrawProtocolFees(address payable to) external onlyOwner {
        require(protocolFees > 0, "No fees");
        uint256 amount = protocolFees;
        protocolFees = 0;
        to.transfer(amount);
        emit ProtocolFeesWithdrawn(to, amount);
    }

    function updateWhitelist(address user, bool status) external onlyOwner {
        whitelist[user] = status;
        emit WhitelistUpdated(user, status);
    }

    function toggleWhitelistMode(bool enabled) external onlyOwner {
        isWhitelistEnabled = enabled;
        emit WhitelistModeUpdated(enabled);
    }

    function liquidate(address borrower) external nonReentrant {
        require(authorizedLiquidators[msg.sender], "Not authorized");
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");

        uint256 collateralValue = loan.collateral;
        uint256 requiredCollateral = loan.amount.mul(LIQUIDATION_THRESHOLD).div(100);
        require(collateralValue < requiredCollateral, "Loan is safe");

        loan.isActive = false;
        users[borrower].hasActiveLoan = false;
        totalBorrowed -= loan.amount;
        totalCollateral -= collateralValue;

        uint256 bonus = collateralValue.mul(LIQUIDATION_BONUS).div(100);
        uint256 reward = collateralValue.sub(bonus);

        payable(msg.sender).transfer(bonus);
        protocolFees += reward;
        emit Liquidated(borrower, collateralValue, loan.amount, msg.sender);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalDeposits == 0) return rewardPerTokenStored;
        return rewardPerTokenStored.add((block.timestamp.sub(lastUpdateTime)).mul(rewardRate).mul(1e18).div(totalDeposits));
    }

    function earned(address account) public view returns (uint256) {
        return users[account].deposited.mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getInterestRate() public view returns (uint256) {
        uint256 utilization = totalBorrowed.mul(100).div(totalDeposits == 0 ? 1 : totalDeposits);
        for (uint256 i = 0; i < interestTiers.length; i++) {
            if (utilization <= interestTiers[i].utilizationThreshold) {
                return interestTiers[i].interestRate;
            }
        }
        return baseInterestRate;
    }
}
