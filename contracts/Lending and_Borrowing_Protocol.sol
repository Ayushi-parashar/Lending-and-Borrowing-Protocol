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

    function donate() external payable {
        require(msg.value > 0, "Donation must be > 0");
        protocolFees += msg.value;
        emit DonationReceived(msg.sender, msg.value);
    }

    function toggleWhitelistMode(bool _enabled) external onlyOwner {
        isWhitelistEnabled = _enabled;
        emit WhitelistModeUpdated(_enabled);
    }

    function updateWhitelist(address _user, bool _status) external onlyOwner {
        whitelist[_user] = _status;
        emit WhitelistUpdated(_user, _status);
    }

    function recordLoanHistory(address user, uint256 interest) internal {
        loanHistories[user].push(LoanHistory({
            amount: loans[user].amount,
            interestPaid: interest,
            duration: loans[user].duration,
            repaidAt: block.timestamp
        }));
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalDeposits == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((block.timestamp - lastUpdateTime) * rewardRate * 1e18 / totalDeposits);
    }

    function earned(address account) public view returns (uint256) {
        return (users[account].deposited * (rewardPerToken() - userRewardPerTokenPaid[account]) / 1e18) + rewards[account];
    }

    function claimReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            emit RewardClaimed(msg.sender, reward);
        }
    }

    receive() external payable {}
}
