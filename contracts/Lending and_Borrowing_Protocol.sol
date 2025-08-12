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

    uint256 public baseInterestRate = 5; // percent
    uint256 public flashLoanFee = 9; // basis points (0.09%) originally used 10000 denom; keep as basis points/10000
    uint256 public rewardRate = 100; // reward units per second scaled by 1e18 in rewardPerToken calculation
    uint256 public earlyWithdrawalPenalty = 2; // percent
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
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 seizedCollateral);
    event LoanTransferred(address indexed from, address indexed to);
    event AuthorizedLiquidatorUpdated(address indexed liquidator, bool authorized);

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

    constructor() Ownable() {
        interestTiers.push(InterestTier(50, 3));
        interestTiers.push(InterestTier(80, 5));
        interestTiers.push(InterestTier(95, 8));
        interestTiers.push(InterestTier(100, 15));
        lastUpdateTime = block.timestamp;
    }

    // --- Core: deposits & withdrawals ---

    function deposit() external payable updateReward(msg.sender) nonReentrant whenLendingNotPaused notBlacklisted {
        require(msg.value > 0, "Zero deposit");
        users[msg.sender].deposited = users[msg.sender].deposited.add(msg.value);
        users[msg.sender].lastDepositTime = block.timestamp;
        totalDeposits = totalDeposits.add(msg.value);
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) public updateReward(msg.sender) nonReentrant notBlacklisted {
        require(amount > 0, "Zero withdraw");
        User storage user = users[msg.sender];
        require(user.deposited >= amount, "Insufficient balance");

        uint256 penalty = 0;
        if (block.timestamp < user.lastDepositTime + withdrawalTimelock) {
            penalty = amount.mul(earlyWithdrawalPenalty).div(100);
        }

        uint256 payout = amount.sub(penalty);

        // update accounting: subtract full requested amount from user's deposited balance
        user.deposited = user.deposited.sub(amount);
        totalDeposits = totalDeposits.sub(amount);

        if (penalty > 0) {
            protocolFees = protocolFees.add(penalty);
        }

        payable(msg.sender).transfer(payout);
        emit Withdrawn(msg.sender, payout);
    }

    function partialWithdraw(uint256 amount) external {
        withdraw(amount);
    }

    // --- Borrowing & loan logic ---

    function borrow(uint256 amount, uint256 duration) external payable updateReward(msg.sender) nonReentrant whenBorrowingNotPaused notBlacklisted onlyWhitelisted {
        require(!users[msg.sender].hasActiveLoan, "Loan exists");
        require(amount > 0 && msg.value > 0, "Invalid input");
        require(duration <= MAX_LOAN_DURATION, "Too long");

        uint256 requiredCollateral = amount.mul(COLLATERAL_RATIO).div(100);
        require(msg.value >= requiredCollateral, "Not enough collateral");

        uint256 interestRate = getInterestRate();

        loans[msg.sender] = Loan({
            amount: amount,
            collateral: msg.value,
            timestamp: block.timestamp,
            interestRate: interestRate,
            duration: duration,
            isActive: true
        });

        users[msg.sender].borrowed = users[msg.sender].borrowed.add(amount);
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        users[msg.sender].hasActiveLoan = true;

        totalBorrowed = totalBorrowed.add(amount);
        totalCollateral = totalCollateral.add(msg.value);

        // transfer loan amount to borrower
        payable(msg.sender).transfer(amount);

        emit Borrowed(msg.sender, amount, msg.value, duration);
    }

    // Repay loan; includes overdue penalty if repaid after loan.duration
    function repayLoan() external payable updateReward(msg.sender) nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(SECONDS_PER_YEAR * 100);

        // Overdue penalty: 1% of principal per overdue day (configurable approach)
        if (timeElapsed > loan.duration) {
            uint256 overdueSeconds = timeElapsed.sub(loan.duration);
            uint256 overdueDays = overdueSeconds.div(1 days);
            if (overdueDays > 0) {
                uint256 penalty = loan.amount.mul(overdueDays).mul(1).div(100); // 1% per day
                interest = interest.add(penalty);
            }
        }

        uint256 totalDue = loan.amount.add(interest);
        require(msg.value >= totalDue, "Not enough to repay");

        uint256 refund = msg.value.sub(totalDue);

        // Accounting
        totalBorrowed = totalBorrowed.sub(loan.amount);
        totalCollateral = totalCollateral.sub(loan.collateral);
        protocolFees = protocolFees.add(interest);

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

        // return collateral + any refund
        payable(msg.sender).transfer(loan.collateral.add(refund));
        emit Repaid(msg.sender, loan.amount, interest);
    }

    function partialRepay(uint256 amount) external payable nonReentrant updateReward(msg.sender) {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No loan");
        require(amount > 0 && amount <= loan.amount, "Invalid amount");

        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(SECONDS_PER_YEAR * 100);

        // prorate interest for the portion being paid
        uint256 proratedInterest = interest.mul(amount).div(loan.amount);
        uint256 totalDue = amount.add(proratedInterest);
        require(msg.value >= totalDue, "Not enough");

        // update loan principal & accounting
        loan.amount = loan.amount.sub(amount);
        users[msg.sender].borrowed = users[msg.sender].borrowed.sub(amount);
        totalBorrowed = totalBorrowed.sub(amount);
        protocolFees = protocolFees.add(proratedInterest);

        emit PartialRepayment(msg.sender, amount);
    }

    function extendLoan(uint256 extraTime) external {
        require(loans[msg.sender].isActive, "No loan");
        loans[msg.sender].duration = loans[msg.sender].duration.add(extraTime);
        emit LoanExtended(msg.sender, loans[msg.sender].duration);
    }

    // --- New: add collateral to an active loan ---
    function addCollateral() external payable nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(msg.value > 0, "Zero collateral");

        loan.collateral = loan.collateral.add(msg.value);
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        totalCollateral = totalCollateral.add(msg.value);

        emit CollateralAdded(msg.sender, msg.value);
    }

    // --- New: transfer loan ownership to another address (consent by current owner only) ---
    function transferLoan(address newBorrower) external nonReentrant {
        require(newBorrower != address(0), "Invalid address");
        require(!users[newBorrower].hasActiveLoan, "Receiver has loan");

        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        // copy loan to new borrower
        loans[newBorrower] = Loan({
            amount: loan.amount,
            collateral: loan.collateral,
            timestamp: loan.timestamp,
            interestRate: loan.interestRate,
            duration: loan.duration,
            isActive: true
        });

        // update user structs
        users[newBorrower].borrowed = users[newBorrower].borrowed.add(users[msg.sender].borrowed);
        users[newBorrower].collateralDeposited = users[newBorrower].collateralDeposited.add(users[msg.sender].collateralDeposited);
        users[newBorrower].hasActiveLoan = true;

        // clear old borrower loan & state
        loans[msg.sender] = Loan(0, 0, 0, 0, 0, false);
        users[msg.sender].borrowed = 0;
        users[msg.sender].collateralDeposited = 0;
        users[msg.sender].hasActiveLoan = false;

        emit LoanTransferred(msg.sender, newBorrower);
    }

    // --- Rewards: compound or claim ---

    function autoCompoundRewards() external updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards");
        rewards[msg.sender] = 0;
        users[msg.sender].deposited = users[msg.sender].deposited.add(reward);
        totalDeposits = totalDeposits.add(reward);
        emit Deposited(msg.sender, reward);
    }

    // New: direct claim rewards in ETH
    function claimRewards() external updateReward(msg.sender) nonReentrant {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards");
        require(address(this).balance >= reward, "Insufficient contract balance");
        rewards[msg.sender] = 0;
        payable(msg.sender).transfer(reward);
        emit RewardClaimed(msg.sender, reward);
    }

    // --- Admin / governance ---

    function adminWithdrawFees(address to) external onlyOwner {
        require(to != address(0), "Invalid address");
        require(protocolFees > 0, "No fees");
        uint256 amount = protocolFees;
        protocolFees = 0;
        payable(to).transfer(amount);
        emit ProtocolFeesWithdrawn(to, amount);
    }

    function toggleWhitelistMode(bool status) external onlyOwner {
        isWhitelistEnabled = status;
        emit WhitelistModeUpdated(status);
    }

    function updateWhitelist(address user, bool status) external onlyOwner {
        whitelist[user] = status;
    }

    function updateBlacklist(address user, bool status) external onlyOwner {
        blacklist[user] = status;
    }

    function pauseLending(bool status) external onlyOwner {
        lendingPaused = status;
    }

    function pauseBorrowing(bool status) external onlyOwner {
        borrowingPaused = status;
    }

    // New: pause/unpause everything (and trigger Pausable _pause/_unpause)
    function pauseAll(bool status) external onlyOwner {
        lendingPaused = status;
        borrowingPaused = status;
        if (status) _pause();
        else _unpause();
    }

    function setBaseInterestRate(uint256 newRate) external onlyOwner {
        baseInterestRate = newRate;
    }

    function setFlashLoanFee(uint256 newFee) external onlyOwner {
        flashLoanFee = newFee;
    }

    function setRewardRate(uint256 newRate) external onlyOwner {
        rewardRate = newRate;
    }

    function setEarlyWithdrawalPenalty(uint256 newPenaltyPercent) external onlyOwner {
        earlyWithdrawalPenalty = newPenaltyPercent;
    }

    function setWithdrawalTimelock(uint256 newTimelock) external onlyOwner {
        withdrawalTimelock = newTimelock;
    }

    // authorize a liquidator
    function setAuthorizedLiquidator(address liquidator, bool authorized) external onlyOwner {
        authorizedLiquidators[liquidator] = authorized;
        emit AuthorizedLiquidatorUpdated(liquidator, authorized);
    }

    // --- Interest & util functions ---

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

    function getUserDetails(address userAddr) external view returns (User memory, Loan memory, uint256 earnedRewards) {
        return (users[userAddr], loans[userAddr], earned(userAddr));
    }

    function getProtocolStats() external view returns (uint256 deposits, uint256 borrowed, uint256 fees, uint256 collaterals) {
        return (totalDeposits, totalBorrowed, protocolFees, totalCollateral);
    }

    // --- Flash loan receiver ---

    function receiveFlashLoan(address receiver, uint256 amount, bytes calldata data) external nonReentrant {
        require(address(this).balance >= amount, "Insufficient balance");
        uint256 fee = amount.mul(flashLoanFee).div(10000);
        uint256 initialBalance = address(this).balance;

        IFlashLoanReceiver(receiver).executeOperation(amount, data);
        require(address(this).balance >= initialBalance.add(fee), "Loan not repaid");

        protocolFees = protocolFees.add(fee);
        emit FlashLoan(receiver, amount, fee);
    }

    // --- Liquidations ---

    function liquidate(address borrower) external nonReentrant {
        require(authorizedLiquidators[msg.sender] || msg.sender == owner(), "Not authorized");
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");

        uint256 ratio = loan.collateral.mul(100).div(loan.amount);
        require(ratio < LIQUIDATION_THRESHOLD, "Healthy position");

        uint256 bonus = loan.collateral.mul(LIQUIDATION_BONUS).div(100);
        uint256 toLiquidator = loan.collateral.sub(bonus);

        users[borrower].borrowed = 0;
        users[borrower].collateralDeposited = 0;
        users[borrower].hasActiveLoan = false;

        loan.isActive = false;
        totalBorrowed = totalBorrowed.sub(loan.amount);
        totalCollateral = totalCollateral.sub(loan.collateral);

        protocolFees = protocolFees.add(bonus);
        payable(msg.sender).transfer(toLiquidator);

        emit Liquidated(borrower, msg.sender, toLiquidator);
    }

    // --- Emergency withdraw when contract paused ---

    function emergencyWithdraw() external nonReentrant {
        require(paused(), "Not emergency");
        User storage user = users[msg.sender];
        uint256 amount = user.deposited;
        require(amount > 0, "Nothing to withdraw");
        user.deposited = 0;
        totalDeposits = totalDeposits.sub(amount);
        payable(msg.sender).transfer(amount);
    }

    // --- receive fallback ---

    receive() external payable {
        // keep original behavior: emit Deposited but do not automatically credit 'users' mapping
        emit Deposited(msg.sender, msg.value);
    }
}
