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

    function deposit() external payable nonReentrant whenNotPaused updateReward(msg.sender) onlyWhitelisted {
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

    function updateWhitelist(address user, bool status) external onlyOwner {
        whitelist[user] = status;
        emit WhitelistUpdated(user, status);
    }

    function toggleWhitelistMode(bool enabled) external onlyOwner {
        isWhitelistEnabled = enabled;
        emit WhitelistModeUpdated(enabled);
    }

    function withdrawProtocolFees(address payable to) external onlyOwner {
        require(protocolFees > 0, "No fees available");
        uint256 amount = protocolFees;
        protocolFees = 0;
        to.transfer(amount);
        emit ProtocolFeesWithdrawn(to, amount);
    }

    function claimReward() external updateReward(msg.sender) nonReentrant {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards to claim");
        rewards[msg.sender] = 0;
        payable(msg.sender).transfer(reward);
        emit RewardClaimed(msg.sender, reward);
    }

    function flashLoan(uint256 amount, address receiver, bytes calldata params) external nonReentrant {
        require(amount <= address(this).balance, "Insufficient liquidity");

        uint256 fee = amount.mul(flashLoanFee).div(10000);
        uint256 balanceBefore = address(this).balance;

        IFlashLoanReceiver(receiver).executeOperation{value: amount}(amount, params);

        require(address(this).balance >= balanceBefore + fee, "Flash loan not repaid with fee");
        protocolFees += fee;

        emit FlashLoan(receiver, amount, fee);
    }

    function extendLoan(uint256 additionalTime) external nonReentrant {
        require(loans[msg.sender].isActive, "No active loan");
        require(additionalTime > 0, "Invalid extension time");
        require(loans[msg.sender].duration + additionalTime <= MAX_LOAN_DURATION, "Exceeds max loan duration");

        loans[msg.sender].duration += additionalTime;
        emit LoanExtended(msg.sender, loans[msg.sender].duration);
    }

    function repayPartialLoan(uint256 amount) external payable nonReentrant {
        require(loans[msg.sender].isActive, "No active loan");
        require(amount > 0 && amount <= loans[msg.sender].amount, "Invalid repayment amount");
        require(msg.value == amount, "Incorrect ETH amount sent");

        loans[msg.sender].amount -= amount;
        users[msg.sender].borrowed -= amount;
        totalBorrowed -= amount;

        emit PartialRepayment(msg.sender, amount);

        if (loans[msg.sender].amount == 0) {
            loans[msg.sender].isActive = false;
            users[msg.sender].hasActiveLoan = false;
            emit Repaid(msg.sender, amount, 0); // Optional: calculate and emit interest
        }
    }

    // Dummy reward functions for completeness
    function rewardPerToken() public view returns (uint256) {
        if (totalDeposits == 0) return rewardPerTokenStored;
        return rewardPerTokenStored.add((block.timestamp.sub(lastUpdateTime)).mul(rewardRate).mul(1e18).div(totalDeposits));
    }

    function earned(address account) public view returns (uint256) {
        return users[account].deposited.mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }
}
