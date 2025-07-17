// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/**
 * @title Lending and Borrowing Protocol
 * @dev A decentralized lending and borrowing protocol with collateral management
 */
contract Project is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    // State variables
    uint256 public constant COLLATERAL_RATIO = 150; // 150% collateralization required
    uint256 public constant LIQUIDATION_THRESHOLD = 120; // 120% liquidation threshold
    uint256 public constant INTEREST_RATE = 5; // 5% annual interest rate
    uint256 public constant SECONDS_PER_YEAR = 365 * 24 * 60 * 60;

    struct Loan {
        uint256 amount;
        uint256 collateral;
        uint256 timestamp;
        uint256 interestRate;
        bool isActive;
    }

    struct User {
        uint256 deposited;
        uint256 borrowed;
        uint256 collateralDeposited;
        bool hasActiveLoan;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;
    
    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public totalCollateral;

    // Events
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 collateral);
    event Repaid(address indexed user, uint256 amount, uint256 interest);
    event CollateralAdded(address indexed user, uint256 amount);
    event Liquidated(address indexed user, uint256 collateral, uint256 debt);

    constructor() Ownable(msg.sender) {}

    /**
     * @dev Core Function 1: Deposit funds to the protocol
     * Users can deposit ETH to earn interest and provide liquidity
     */
    function deposit() external payable nonReentrant {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        
        users[msg.sender].deposited = users[msg.sender].deposited.add(msg.value);
        totalDeposits = totalDeposits.add(msg.value);
        
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @dev Core Function 2: Borrow funds with collateral
     * Users can borrow ETH by providing collateral (150% collateralization)
     */
    function borrow(uint256 _amount) external payable nonReentrant {
        require(_amount > 0, "Borrow amount must be greater than 0");
        require(msg.value > 0, "Collateral required");
        require(!users[msg.sender].hasActiveLoan, "User already has an active loan");
        
        uint256 requiredCollateral = _amount.mul(COLLATERAL_RATIO).div(100);
        require(msg.value >= requiredCollateral, "Insufficient collateral");
        require(address(this).balance >= _amount, "Insufficient liquidity");
        
        // Create loan
        loans[msg.sender] = Loan({
            amount: _amount,
            collateral: msg.value,
            timestamp: block.timestamp,
            interestRate: INTEREST_RATE,
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
        
        emit Borrowed(msg.sender, _amount, msg.value);
    }

    /**
     * @dev Core Function 3: Repay loan with interest
     * Users can repay their loan to get back their collateral
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
     * @dev Withdraw deposited funds
     * Users can withdraw their deposited funds
     */
    function withdraw(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Withdrawal amount must be greater than 0");
        require(users[msg.sender].deposited >= _amount, "Insufficient deposited balance");
        require(address(this).balance >= _amount, "Insufficient contract balance");
        
        users[msg.sender].deposited = users[msg.sender].deposited.sub(_amount);
        totalDeposits = totalDeposits.sub(_amount);
        
        payable(msg.sender).transfer(_amount);
        
        emit Withdrawn(msg.sender, _amount);
    }

    /**
     * @dev Add additional collateral to existing loan
     */
    function addCollateral() external payable nonReentrant {
        require(users[msg.sender].hasActiveLoan, "No active loan found");
        require(msg.value > 0, "Collateral amount must be greater than 0");
        
        loans[msg.sender].collateral = loans[msg.sender].collateral.add(msg.value);
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.add(msg.value);
        totalCollateral = totalCollateral.add(msg.value);
        
        emit CollateralAdded(msg.sender, msg.value);
    }

    /**
     * @dev Liquidate undercollateralized loans
     * Anyone can liquidate loans that fall below the liquidation threshold
     */
    function liquidate(address _borrower) external nonReentrant {
        require(users[_borrower].hasActiveLoan, "No active loan found");
        
        Loan storage loan = loans[_borrower];
        require(loan.isActive, "Loan is not active");
        
        // Calculate current collateral ratio
        uint256 currentRatio = loan.collateral.mul(100).div(loan.amount);
        require(currentRatio < LIQUIDATION_THRESHOLD, "Loan is not undercollateralized");
        
        // Update state
        users[_borrower].borrowed = 0;
        users[_borrower].hasActiveLoan = false;
        users[_borrower].collateralDeposited = 0;
        totalBorrowed = totalBorrowed.sub(loan.amount);
        totalCollateral = totalCollateral.sub(loan.collateral);
        
        // Transfer collateral to liquidator
        uint256 collateralToLiquidator = loan.collateral;
        loan.isActive = false;
        
        payable(msg.sender).transfer(collateralToLiquidator);
        
        emit Liquidated(_borrower, collateralToLiquidator, loan.amount);
    }

    /**
     * @dev Get user information
     */
    function getUserInfo(address _user) external view returns (
        uint256 deposited,
        uint256 borrowed,
        uint256 collateralDeposited,
        bool hasActiveLoan
    ) {
        User storage user = users[_user];
        return (
            user.deposited,
            user.borrowed,
            user.collateralDeposited,
            user.hasActiveLoan
        );
    }

    /**
     * @dev Get loan information
     */
    function getLoanInfo(address _user) external view returns (
        uint256 amount,
        uint256 collateral,
        uint256 timestamp,
        uint256 interestRate,
        bool isActive
    ) {
        Loan storage loan = loans[_user];
        return (
            loan.amount,
            loan.collateral,
            loan.timestamp,
            loan.interestRate,
            loan.isActive
        );
    }

    /**
     * @dev Get protocol statistics
     */
    function getProtocolStats() external view returns (
        uint256 deposits,
        uint256 borrowed,
        uint256 collateral,
        uint256 availableLiquidity
    ) {
        return (
            totalDeposits,
            totalBorrowed,
            totalCollateral,
            address(this).balance
        );
    }

    /**
     * @dev Emergency withdrawal function (only owner)
     */
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable {}
}
