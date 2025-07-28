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
    mapping(address => bool) public blacklist;
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
    event BlacklistUpdated(address indexed user, bool status);

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

    modifier notBlacklisted() {
        require(!blacklist[msg.sender], "Blacklisted");
        _;
    }

    constructor() Ownable(msg.sender) {
        interestTiers.push(InterestTier(50, 3));
        interestTiers.push(InterestTier(80, 5));
        interestTiers.push(InterestTier(95, 8));
        interestTiers.push(InterestTier(100, 15));
        lastUpdateTime = block.timestamp;
    }

    // Add new functions below (see previous message for suggestions)
    function getLoanHealth(address user) external view returns (uint256 ltv, bool isLiquidationRisk) {
        Loan storage loan = loans[user];
        if (!loan.isActive || loan.amount == 0) return (0, false);
        ltv = loan.amount.mul(100).div(loan.collateral);
        isLiquidationRisk = ltv >= LIQUIDATION_THRESHOLD;
    }

    function getTVL() external view returns (uint256) {
        return address(this).balance;
    }

    function claimAndDepositRewards() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards");
        rewards[msg.sender] = 0;
        users[msg.sender].deposited += reward;
        totalDeposits += reward;
        emit Deposited(msg.sender, reward);
    }

    function refinanceLoan(uint256 newAmount, uint256 newDuration) external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(newAmount >= loan.amount, "Must increase amount");
        require(users[msg.sender].collateralDeposited >= newAmount.mul(COLLATERAL_RATIO).div(100), "Insufficient collateral");
        uint256 newRate = getInterestRate();
        loan.amount = newAmount;
        loan.duration = newDuration;
        loan.interestRate = newRate;
    }

    function updateBlacklist(address user, bool status) external onlyOwner {
        blacklist[user] = status;
        emit BlacklistUpdated(user, status);
    }

    function executeFlashLoan(uint256 amount, address receiver, bytes calldata params) external nonReentrant whenNotPaused {
        require(amount <= address(this).balance, "Insufficient liquidity");
        uint256 fee = amount.mul(flashLoanFee).div(1000);
        uint256 prevBalance = address(this).balance;
        IFlashLoanReceiver(receiver).executeOperation(amount, params);
        require(address(this).balance >= prevBalance + fee, "Loan not repaid");
        protocolFees += fee;
        emit FlashLoan(receiver, amount, fee);
    }

    // Existing core methods like deposit(), borrow(), repayLoan(), etc. stay unchanged, and will work with added modifiers as needed.
}
