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
    uint256 public constant LIQUIDATION_BONUS = 5;
    uint256 public constant MAX_LOAN_DURATION = 365 days;
    uint256 public constant SECONDS_PER_YEAR = 365 * 24 * 60 * 60;

    uint256 public baseInterestRate = 5;
    uint256 public flashLoanFee = 9;
    uint256 public rewardRate = 100;
    uint256 public earlyWithdrawalPenalty = 2;
    uint256 public withdrawalTimelock = 7 days;

    bool public borrowingPaused = false;
    bool public lendingPaused = false;
    bool public isWhitelistEnabled = false;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => bool) public authorizedLiquidators;
    mapping(address => bool) public whitelist;
    mapping(address => bool) public blacklist;

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
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event PartialRepayment(address indexed user, uint256 amount);
    event LoanExtended(address indexed user, uint256 newDuration);
    event RewardClaimed(address indexed user, uint256 amount);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);
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

    modifier notBlacklisted() {
        require(!blacklist[msg.sender], "Blacklisted");
        _;
    }

    modifier whenLendingNotPaused() {
        require(!lendingPaused, "Lending is paused");
        _;
    }

    modifier whenBorrowingNotPaused() {
        require(!borrowingPaused, "Borrowing is paused");
        _;
    }

    constructor() Ownable(msg.sender) {
        interestTiers.push(InterestTier(50, 3));
        interestTiers.push(InterestTier(80, 5));
        interestTiers.push(InterestTier(95, 8));
        interestTiers.push(InterestTier(100, 15));
        lastUpdateTime = block.timestamp;
    }

    // 🔹 Deposit ETH
    function deposit() external payable updateReward(msg.sender) nonReentrant whenLendingNotPaused notBlacklisted {
        require(msg.value > 0, "Zero deposit");
        users[msg.sender].deposited += msg.value;
        users[msg.sender].lastDepositTime = block.timestamp;
        totalDeposits += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    // 🔹 Withdraw ETH
    function withdraw(uint256 amount) external updateReward(msg.sender) nonReentrant notBlacklisted {
        require(amount > 0, "Zero withdraw");
        User storage user = users[msg.sender];
        require(user.deposited >= amount, "Insufficient balance");

        if (block.timestamp < user.lastDepositTime + withdrawalTimelock) {
            uint256 penalty = amount.mul(earlyWithdrawalPenalty).div(100);
            amount = amount.sub(penalty);
            protocolFees += penalty;
        }

        user.deposited -= amount;
        totalDeposits -= amount;
        payable(msg.sender).transfer(amount);
        emit Withdrawn(msg.sender, amount);
    }

    // 🔹 Partial Withdraw
    function partialWithdraw(uint256 amount) external {
        withdraw(amount); // same as normal withdraw but encourages usage
    }

    // 🔹 Borrow
    function borrow(uint256 amount, uint256 duration) external payable updateReward(msg.sender) nonReentrant whenBorrowingNotPaused notBlacklisted {
        require(!users[msg.sender].hasActiveLoan, "Loan exists");
        require(amount > 0 && msg.value > 0, "Invalid input");
        require(duration <= MAX_LOAN_DURATION, "Too long");

        uint256 requiredCollateral = amount.mul(COLLATERAL_RATIO).div(100);
        require(msg.value >= requiredCollateral, "Not enough collateral");

        uint256 interestRate = getInterestRate();

        loans[msg.sender] = Loan(amount, msg.value, block.timestamp, interestRate, duration, true);
        users[msg.sender].borrowed = amount;
        users[msg.sender].collateralDeposited = msg.value;
        users[msg.sender].hasActiveLoan = true;

        totalBorrowed += amount;
        totalCollateral += msg.value;

        payable(msg.sender).transfer(amount);
        emit Borrowed(msg.sender, amount, msg.value, duration);
    }

    // 🔹 Repay full loan
    function repayLoan() external payable updateReward(msg.sender) nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(SECONDS_PER_YEAR * 100);
        uint256 totalDue = loan.amount.add(interest);
        require(msg.value >= totalDue, "Not enough to repay");

        uint256 refund = msg.value.sub(totalDue);

        totalBorrowed -= loan.amount;
        totalCollateral -= loan.collateral;

        protocolFees += interest;

        users[msg.sender].borrowed = 0;
        users[msg.sender].collateralDeposited = 0;
        users[msg.sender].hasActiveLoan = false;

        loanHistories[msg.sender].push(LoanHistory({
            amount: loan.amount,
            interestPaid: interest,
            duration: loan.duration,
            repaidAt: block.timestamp
        }));

        loan.isActive = false;
        payable(msg.sender).transfer(loan.collateral.add(refund));
        emit Repaid(msg.sender, loan.amount, interest);
    }

    // 🔹 Partial Repay
    function partialRepay(uint256 amount) external payable nonReentrant updateReward(msg.sender) {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No loan");
        require(amount <= loan.amount, "Too much");

        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(SECONDS_PER_YEAR * 100);
        uint256 totalDue = amount.add(interest.mul(amount).div(loan.amount));
        require(msg.value >= totalDue, "Not enough");

        loan.amount -= amount;
        users[msg.sender].borrowed -= amount;
        totalBorrowed -= amount;
        protocolFees += interest;

        emit PartialRepayment(msg.sender, amount);
    }

    // 🔹 Extend loan
    function extendLoan(uint256 extraTime) external {
        require(loans[msg.sender].isActive, "No loan");
        loans[msg.sender].duration += extraTime;
        emit LoanExtended(msg.sender, loans[msg.sender].duration);
    }

    // 🔹 Auto compound rewards
    function autoCompoundRewards() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards");
        rewards[msg.sender] = 0;
        users[msg.sender].deposited += reward;
        totalDeposits += reward;
        emit Deposited(msg.sender, reward);
    }

    // 🔹 Admin: withdraw protocol fees
    function adminWithdrawFees(address to) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(protocolFees > 0, "No fees");
        uint256 amount = protocolFees;
        protocolFees = 0;
        payable(to).transfer(amount);
        emit ProtocolFeesWithdrawn(to, amount);
    }

    // 🔹 Admin: toggle whitelist
    function toggleWhitelistMode(bool status) external onlyOwner {
        isWhitelistEnabled = status;
        emit WhitelistModeUpdated(status);
    }

    // 🔹 View rewards
    function rewardPerToken() public view returns (uint256) {
        if (totalDeposits == 0) return rewardPerTokenStored;
        return rewardPerTokenStored.add(rewardRate.mul(block.timestamp.sub(lastUpdateTime)).mul(1e18).div(totalDeposits));
    }

    function earned(address account) public view returns (uint256) {
        return users[account].deposited.mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getInterestRate() public view returns (uint256) {
        if (totalDeposits == 0) return baseInterestRate;
        uint256 utilization = totalBorrowed.mul(100).div(totalDeposits);
        for (uint256 i = 0; i < interestTiers.length; i++) {
            if (utilization <= interestTiers[i].utilizationThreshold) {
                return interestTiers[i].interestRate;
            }
        }
        return interestTiers[interestTiers.length - 1].interestRate;
    }

    // 🔹 View: User info
    function getUserDetails(address userAddr) external view returns (User memory, Loan memory, uint256 earnedRewards) {
        return (users[userAddr], loans[userAddr], earned(userAddr));
    }

    // 🔹 View: Protocol stats
    function getProtocolStats() external view returns (
        uint256 deposits,
        uint256 borrowed,
        uint256 fees,
        uint256 collaterals
    ) {
        return (totalDeposits, totalBorrowed, protocolFees, totalCollateral);
    }

    // 🔹 Fallback
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }
}
