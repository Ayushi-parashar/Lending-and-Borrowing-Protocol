// SPDX-License-Identifier: 
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title Enhanced Lending and Borrowing Protocol
 * @dev A decentralized lending and borrowing protocol with advanced features
 */
contract EnhancedProject is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    // State variables
    uint256 public constant COLLATERAL_RATIO = 150; // 150% collateralization required
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120% liquidation threshold
    uint256 public baseInterestRate = 5; // 5% annual base interest rate (now adjustable)
    uint256 public constant SECONDS_PER_YEAR = 365 * 24 * 60 * 60;
    uint256 public constant LIQUIDATION_BONUS = 5; // 5% bonus for liquidators
    uint256 public constant MAX_LOAN_DURATION = 365 days; // Maximum loan duration
    
    // NEW: Flash loan fee
    uint256 public flashLoanFee = 9; // 0.09% flash loan fee (9 basis points)
    
    // NEW: Governance token rewards
    uint256 public rewardRate = 100; // Rewards per second per deposited ETH
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 timestamp;
        uint256 interestRate;
        uint256 duration; // NEW: Loan duration
        bool isActive;
    }

    struct User {
        uint256 deposited;
        uint256 borrowed;
        uint256 collateralDeposited;
        bool hasActiveLoan;
        uint256 lastDepositTime; // NEW: For time-locked deposits
    }

    // NEW: Flash loan interface
    interface IFlashLoanReceiver {
        function executeOperation(uint256 amount, bytes calldata params) external;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;
    mapping(address => bool) public authorizedLiquidators; // NEW: Authorized liquidator system
    
    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public totalCollateral;
    uint256 public protocolFees; // NEW: Track protocol fees
    
    // NEW: Interest rate tiers based on utilization
    struct InterestTier {
        uint256 utilizationThreshold;
        uint256 interestRate;
    }
    InterestTier[] public interestTiers;

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 collateral, uint256 duration);
    event Repaid(address indexed user, uint256 amount, uint256 interest);
    event CollateralAdded(address indexed user, uint256 amount);
    event Liquidated(address indexed user, uint256 collateral, uint256 debt, address liquidator);
    
    // NEW: Additional events
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event RewardClaimed(address indexed user, uint256 amount);
    event InterestRateUpdated(uint256 newRate);
    event LiquidatorAuthorized(address indexed liquidator, bool authorized);
    event PartialRepayment(address indexed user, uint256 amount);
    event LoanExtended(address indexed user, uint256 newDuration);

    constructor() Ownable(msg.sender) {
        // Initialize interest rate tiers
        interestTiers.push(InterestTier(50, 3)); // 0-50% utilization: 3%
        interestTiers.push(InterestTier(80, 5)); // 50-80% utilization: 5%
        interestTiers.push(InterestTier(95, 8)); // 80-95% utilization: 8%
        interestTiers.push(InterestTier(100, 15)); // 95-100% utilization: 15%
        
        lastUpdateTime = block.timestamp;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /**
     * @dev NEW FEATURE 1: Dynamic Interest Rates based on utilization
     */
    function getCurrentInterestRate() public view returns (uint256) {
        if (totalDeposits == 0) return baseInterestRate;
        
        uint256 utilization = totalBorrowed.mul(100).div(totalDeposits);
        
        for (uint256 i = 0; i < interestTiers.length; i++) {
            if (utilization <= interestTiers[i].utilizationThreshold) {
                return interestTiers[i].interestRate;
            }
        }
        return interestTiers[interestTiers.length - 1].interestRate;
    }

    /**
     * @dev Enhanced deposit function with rewards
     */
    function deposit() external payable nonReentrant whenNotPaused updateReward(msg.sender) {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        
        users[msg.sender].deposited = users[msg.sender].deposited.add(msg.value);
        users[msg.sender].lastDepositTime = block.timestamp;
        totalDeposits = totalDeposits.add(msg.value);
        
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @dev NEW FEATURE 2: Borrow with custom duration
     */
    function borrowWithDuration(uint256 _amount, uint256 _duration) external payable nonReentrant whenNotPaused {
        require(_amount > 0, "Borrow amount must be greater than 0");
        require(msg.value > 0, "Collateral required");
        require(_duration > 0 && _duration <= MAX_LOAN_DURATION, "Invalid loan duration");
        require(!users[msg.sender].hasActiveLoan, "User already has an active loan");
        
        uint256 requiredCollateral = _amount.mul(COLLATERAL_RATIO).div(100);
        require(msg.value >= requiredCollateral, "Insufficient collateral");
        require(address(this).balance >= _amount, "Insufficient liquidity");
        
        uint256 currentRate = getCurrentInterestRate();
        
        // Create loan
        loans[msg.sender] = Loan({
            amount: _amount,
            collateral: msg.value,
            timestamp: block.timestamp,
            interestRate: currentRate,
            duration: _duration,
            isActive: true
        });
        
        // Update user state
        users[msg.sender].borrowed = _amount;
        users[msg.sender].collateralDeposited = msg.value;
        users[msg.sender].hasActiveLoan = true;
        
        // Update global state
        totalBorrowed = totalBorrowed.add(_amount);
        totalCollateral = totalCollateral.add(msg.value);
        
        // Transfer borrowed amount to user
        payable(msg.sender).transfer(_amount);
        
        emit Borrowed(msg.sender, _amount, msg.value, _duration);
    }

    /**
     * @dev Original borrow function (backwards compatibility)
     */
    function borrow(uint256 _amount) external payable nonReentrant whenNotPaused {
        this.borrowWithDuration{value: msg.value}(_amount, 30 days); // Default 30 days
    }

    /**
     * @dev NEW FEATURE 3: Partial loan repayment
     */
    function partialRepay(uint256 _repayAmount) external payable nonReentrant {
        require(users[msg.sender].hasActiveLoan, "No active loan found");
        require(_repayAmount > 0, "Repay amount must be greater than 0");
        require(msg.value >= _repayAmount, "Insufficient payment");
        
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "Loan is not active");
        
        // Calculate current debt with interest
        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(100).div(SECONDS_PER_YEAR);
        uint256 totalDebt = loan.amount.add(interest);
        
        require(_repayAmount <= totalDebt, "Repay amount exceeds total debt");
        
        // Calculate how much of principal is being repaid
        uint256 principalRepaid = _repayAmount > interest ? _repayAmount.sub(interest) : 0;
        uint256 interestRepaid = _repayAmount > interest ? interest : _repayAmount;
        
        // Update loan
        loan.amount = loan.amount.sub(principalRepaid);
        loan.timestamp = block.timestamp; // Reset timestamp for future interest calculations
        
        // Update user borrowed amount
        users[msg.sender].borrowed = loan.amount;
        totalBorrowed = totalBorrowed.sub(principalRepaid);
        
        // Add to protocol fees
        protocolFees = protocolFees.add(interestRepaid);
        
        // Return excess payment
        if (msg.value > _repayAmount) {
            payable(msg.sender).transfer(msg.value.sub(_repayAmount));
        }
        
        emit PartialRepayment(msg.sender, _repayAmount);
    }

    /**
     * @dev Enhanced repay function
     */
    function repay() external payable nonReentrant {
        require(users[msg.sender].hasActiveLoan, "No active loan found");
        
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "Loan is not active");
        
        // Calculate interest
        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(100).div(SECONDS_PER_YEAR);
        uint256 totalRepayment = loan.amount.add(interest);
        
        require(msg.value >= totalRepayment, "Insufficient repayment amount");
        
        // Update state
        users[msg.sender].borrowed = 0;
        users[msg.sender].hasActiveLoan = false;
        totalBorrowed = totalBorrowed.sub(loan.amount);
        totalCollateral = totalCollateral.sub(loan.collateral);
        
        // Add interest to protocol fees
        protocolFees = protocolFees.add(interest);
        
        // Return collateral to user
        uint256 collateralToReturn = loan.collateral;
        users[msg.sender].collateralDeposited = 0;
        
        // Mark loan as inactive
        loan.isActive = false;
        
        // Return excess payment if any
        if (msg.value > totalRepayment) {
            payable(msg.sender).transfer(msg.value.sub(totalRepayment));
        }
        
        // Return collateral
        payable(msg.sender).transfer(collateralToReturn);
        
        emit Repaid(msg.sender, loan.amount, interest);
    }

    /**
     * @dev NEW FEATURE 4: Extend loan duration
     */
    function extendLoan(uint256 _additionalDuration) external payable nonReentrant {
        require(users[msg.sender].hasActiveLoan, "No active loan found");
        require(_additionalDuration > 0, "Additional duration must be greater than 0");
        
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "Loan is not active");
        
        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        require(timeElapsed.add(_additionalDuration) <= MAX_LOAN_DURATION, "Total duration exceeds maximum");
        
        // Calculate extension fee (1% of loan amount)
        uint256 extensionFee = loan.amount.div(100);
        require(msg.value >= extensionFee, "Insufficient extension fee");
        
        loan.duration = loan.duration.add(_additionalDuration);
        protocolFees = protocolFees.add(extensionFee);
        
        // Return excess payment
        if (msg.value > extensionFee) {
            payable(msg.sender).transfer(msg.value.sub(extensionFee));
        }
        
        emit LoanExtended(msg.sender, loan.duration);
    }

    /**
     * @dev NEW FEATURE 5: Flash loans
     */
    function flashLoan(uint256 _amount, bytes calldata _params) external nonReentrant whenNotPaused {
        require(_amount > 0, "Flash loan amount must be greater than 0");
        require(_amount <= address(this).balance, "Insufficient liquidity for flash loan");
        
        uint256 fee = _amount.mul(flashLoanFee).div(10000);
        uint256 balanceBefore = address(this).balance;
        
        // Transfer funds to borrower
        payable(msg.sender).transfer(_amount);
        
        // Execute borrower's logic
        IFlashLoanReceiver(msg.sender).executeOperation(_amount, _params);
        
        // Check that funds + fee were returned
        require(address(this).balance >= balanceBefore.add(fee), "Flash loan not repaid with fee");
        
        protocolFees = protocolFees.add(fee);
        
        emit FlashLoan(msg.sender, _amount, fee);
    }

    /**
     * @dev NEW FEATURE 6: Reward system for depositors
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalDeposits == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored.add(
            block.timestamp.sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(totalDeposits)
        );
    }

    function earned(address account) public view returns (uint256) {
        return users[account].deposited.mul(
            rewardPerToken().sub(userRewardPerTokenPaid[account])
        ).div(1e18).add(rewards[account]);
    }

    function claimReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            // In a real implementation, you would mint/transfer reward tokens here
            // For this example, we'll just emit an event
            emit RewardClaimed(msg.sender, reward);
        }
    }

    /**
     * @dev Enhanced withdraw with time lock (optional security feature)
     */
    function withdraw(uint256 _amount) external nonReentrant updateReward(msg.sender) {
        require(_amount > 0, "Withdrawal amount must be greater than 0");
        require(users[msg.sender].deposited >= _amount, "Insufficient deposited balance");
        require(address(this).balance >= _amount, "Insufficient contract balance");
        
        users[msg.sender].deposited = users[msg.sender].deposited.sub(_amount);
        totalDeposits = totalDeposits.sub(_amount);
        
        payable(msg.sender).transfer(_amount);
        
        emit Withdrawn(msg.sender, _amount);
    }

    /**
     * @dev NEW FEATURE 7: Authorized liquidator system
     */
    function setLiquidatorAuthorization(address _liquidator, bool _authorized) external onlyOwner {
        authorizedLiquidators[_liquidator] = _authorized;
        emit LiquidatorAuthorized(_liquidator, _authorized);
    }

    /**
     * @dev Enhanced liquidation with bonus
     */
    function liquidate(address _borrower) external nonReentrant {
        require(authorizedLiquidators[msg.sender] || msg.sender == owner(), "Not authorized to liquidate");
        require(users[_borrower].hasActiveLoan, "No active loan found");
        
        Loan storage loan = loans[_borrower];
        require(loan.isActive, "Loan is not active");
        
        // Check if loan is overdue or undercollateralized
        uint256 currentRatio = loan.collateral.mul(100).div(loan.amount);
        bool isOverdue = block.timestamp > loan.timestamp.add(loan.duration);
        bool isUndercollateralized = currentRatio < LIQUIDATION_THRESHOLD;
        
        require(isOverdue || isUndercollateralized, "Loan cannot be liquidated");
        
        // Calculate liquidator bonus
        uint256 bonus = loan.collateral.mul(LIQUIDATION_BONUS).div(100);
        uint256 collateralToLiquidator = loan.collateral.add(bonus);
        
        // Update state
        users[_borrower].borrowed = 0;
        users[_borrower].hasActiveLoan = false;
        users[_borrower].collateralDeposited = 0;
        totalBorrowed = totalBorrowed.sub(loan.amount);
        totalCollateral = totalCollateral.sub(loan.collateral);
        
        loan.isActive = false;
        
        payable(msg.sender).transfer(collateralToLiquidator);
        
        emit Liquidated(_borrower, loan.collateral, loan.amount, msg.sender);
    }

    // Admin functions
    function setBaseInterestRate(uint256 _newRate) external onlyOwner {
        baseInterestRate = _newRate;
        emit InterestRateUpdated(_newRate);
    }
    
    function setFlashLoanFee(uint256 _newFee) external onlyOwner {
        require(_newFee <= 100, "Fee too high"); // Max 1%
        flashLoanFee = _newFee;
    }
    
    function setRewardRate(uint256 _newRate) external onlyOwner {
        rewardRate = _newRate;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function withdrawProtocolFees() external onlyOwner {
        uint256 fees = protocolFees;
        protocolFees = 0;
        payable(owner()).transfer(fees);
    }

    // View functions
    function getUserInfo(address _user) external view returns (
        uint256 deposited,
        uint256 borrowed,
        uint256 collateralDeposited,
        bool hasActiveLoan,
        uint256 pendingRewards
    ) {
        User storage user = users[_user];
        return (
            user.deposited,
            user.borrowed,
            user.collateralDeposited,
            user.hasActiveLoan,
            earned(_user)
        );
    }

    function getLoanInfo(address _user) external view returns (
        uint256 amount,
        uint256 collateral,
        uint256 timestamp,
        uint256 interestRate,
        uint256 duration,
        bool isActive,
        uint256 currentDebt
    ) {
        Loan storage loan = loans[_user];
        uint256 timeElapsed = block.timestamp.sub(loan.timestamp);
        uint256 interest = loan.amount.mul(loan.interestRate).mul(timeElapsed).div(100).div(SECONDS_PER_YEAR);
        
        return (
            loan.amount,
            loan.collateral,
            loan.timestamp,
            loan.interestRate,
            loan.duration,
            loan.isActive,
            loan.amount.add(interest)
        );
    }

    function getProtocolStats() external view returns (
        uint256 deposits,
        uint256 borrowed,
        uint256 collateral,
        uint256 availableLiquidity,
        uint256 utilizationRate,
        uint256 currentInterestRate,
        uint256 totalFees
    ) {
        uint256 utilization = totalDeposits > 0 ? totalBorrowed.mul(100).div(totalDeposits) : 0;
        
        return (
            totalDeposits,
            totalBorrowed,
            totalCollateral,
            address(this).balance,
            utilization,
            getCurrentInterestRate(),
            protocolFees
        );
    }

    // Keep existing functions for backwards compatibility
    function addCollateral() external payable nonReentrant {
        require(users[msg.sender].hasActiveLoan, "No active loan found");
        require(msg.value > 0, "Collateral amount must be greater than 0");
        
        loans[msg.sender].collateral = loans[msg.sender].collateral.add(msg.value);
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        totalCollateral = totalCollateral.add(msg.value);
        
        emit CollateralAdded(msg.sender, msg.value);
    }

    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    receive() external payable {}
}
