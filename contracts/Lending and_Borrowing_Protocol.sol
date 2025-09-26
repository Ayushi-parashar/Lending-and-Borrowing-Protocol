// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * EnhancedProjectV9
 * - Adds comprehensive risk management & fee handling
 * - Protocol fee on borrow
 * - Partial repayment support
 * - Liquidity ratio requirement for borrows
 * - Late fee handling
 * - Deposit & borrow limits
 * - Early repayment discount
 * - Adjustable parameters
 */
contract EnhancedProjectV9 is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;

    struct Loan {
        uint256 principal;
        uint256 interestAccrued;
        uint256 startTime;
        bool isActive;
    }

    struct User {
        uint256 deposited;
        uint256 borrowed;
    }

    mapping(address => User) public users;
    mapping(address => Loan) public loans;

    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public baseInterestRate = 5; // 5% base
    uint256 public ownerFees;
    uint256 public protocolFeePercent = 1; // 1% borrow fee
    uint256 public lateFeeRate = 2; // 2% per week
    uint256 public liquidityRatioThreshold = 150; // 150% requirement

    uint256 public maxDepositPerUser = 50 ether;
    uint256 public maxBorrowPerUser = 20 ether;
    uint256 public earlyRepaymentDiscountPercent = 1; // 1% discount if repaid early

    mapping(address => bool) public blacklisted;
    bool public depositsPaused;
    bool public borrowPaused;
    bool public repaymentPaused;

    // --------- Events ---------
    event Deposited(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount, uint256 fee);
    event Repaid(address indexed user, uint256 amount);
    event PartialRepayment(address indexed payer, address indexed borrower, uint256 amount, uint256 principalReduced);
    event Withdrawn(address indexed user, uint256 amount);
    event OwnerWithdrawal(uint256 amount);
    event Blacklisted(address indexed user, bool status);
    event PausedAction(string action, bool status);
    event LiquidityRatioTooLow(address indexed user, uint256 currentRatio, uint256 requestedAmount);

    // --------- Modifiers ---------
    modifier notBlacklisted() {
        require(!blacklisted[msg.sender], "Blacklisted");
        _;
    }

    modifier whenDepositsNotPaused() {
        require(!depositsPaused, "Deposits paused");
        _;
    }

    modifier whenBorrowNotPaused() {
        require(!borrowPaused, "Borrow paused");
        _;
    }

    modifier whenRepaymentNotPaused() {
        require(!repaymentPaused, "Repayment paused");
        _;
    }

    modifier withinDepositLimit(uint256 amount) {
        require(users[msg.sender].deposited.add(amount) <= maxDepositPerUser, "Exceeds max deposit");
        _;
    }

    modifier withinBorrowLimit(uint256 amount) {
        require(users[msg.sender].borrowed.add(amount) <= maxBorrowPerUser, "Exceeds max borrow");
        _;
    }

    // --------- Admin Controls ---------
    function setBlacklist(address user, bool status) external onlyOwner {
        blacklisted[user] = status;
        emit Blacklisted(user, status);
    }

    function setPauseDeposits(bool status) external onlyOwner {
        depositsPaused = status;
        emit PausedAction("deposits", status);
    }

    function setPauseBorrow(bool status) external onlyOwner {
        borrowPaused = status;
        emit PausedAction("borrow", status);
    }

    function setPauseRepayment(bool status) external onlyOwner {
        repaymentPaused = status;
        emit PausedAction("repayment", status);
    }

    function emergencyPauseAll() external onlyOwner {
        _pause();
    }

    function resumeAll() external onlyOwner {
        _unpause();
    }

    // Adjustable parameters
    function setBaseInterestRate(uint256 rate) external onlyOwner {
        baseInterestRate = rate;
    }

    function setProtocolFeePercent(uint256 fee) external onlyOwner {
        protocolFeePercent = fee;
    }

    function setLateFeeRate(uint256 fee) external onlyOwner {
        lateFeeRate = fee;
    }

    function setLiquidityRatioThreshold(uint256 ratio) external onlyOwner {
        liquidityRatioThreshold = ratio;
    }

    function setMaxDepositPerUser(uint256 amount) external onlyOwner {
        maxDepositPerUser = amount;
    }

    function setMaxBorrowPerUser(uint256 amount) external onlyOwner {
        maxBorrowPerUser = amount;
    }

    function setEarlyRepaymentDiscountPercent(uint256 percent) external onlyOwner {
        earlyRepaymentDiscountPercent = percent;
    }

    // --------- Core Functions ---------
    function deposit() external payable whenDepositsNotPaused nonReentrant notBlacklisted whenNotPaused withinDepositLimit(msg.value) {
        require(msg.value > 0, "Must deposit >0");
        users[msg.sender].deposited = users[msg.sender].deposited.add(msg.value);
        totalDeposits = totalDeposits.add(msg.value);
        emit Deposited(msg.sender, msg.value);
    }

    function getUtilizationRate() public view returns (uint256) {
        if (totalDeposits == 0) return 0;
        return totalBorrowed.mul(100).div(totalDeposits);
    }

    function getCurrentInterestRate() public view returns (uint256) {
        uint256 utilization = getUtilizationRate();
        return baseInterestRate.add(utilization.div(10)); // scale with utilization
    }

    function borrow(uint256 amount) external whenBorrowNotPaused nonReentrant notBlacklisted whenNotPaused withinBorrowLimit(amount) {
        require(amount > 0, "Invalid borrow amount");

        // Liquidity check
        uint256 liquidityRatio = totalDeposits.mul(100).div(totalBorrowed.add(amount));
        if (liquidityRatio < liquidityRatioThreshold) {
            emit LiquidityRatioTooLow(msg.sender, liquidityRatio, amount);
            revert("Liquidity ratio too low");
        }

        uint256 fee = amount.mul(protocolFeePercent).div(100);
        uint256 amountAfterFee = amount.sub(fee);

        totalBorrowed = totalBorrowed.add(amount);
        users[msg.sender].borrowed = users[msg.sender].borrowed.add(amount);

        Loan storage loan = loans[msg.sender];
        loan.principal = loan.principal.add(amount);
        loan.startTime = block.timestamp;
        loan.isActive = true;

        ownerFees = ownerFees.add(fee);

        (bool sent, ) = msg.sender.call{value: amountAfterFee}("");
        require(sent, "Transfer failed");

        emit Borrowed(msg.sender, amount, fee);
    }

    function calculateLateFee(address borrower) public view returns (uint256) {
        Loan storage loan = loans[borrower];
        if (!loan.isActive) return 0;

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        if (elapsed <= 30 days) return 0;

        uint256 overdueWeeks = elapsed.sub(30 days).div(7 days);
        return loan.principal.mul(lateFeeRate).mul(overdueWeeks).div(100);
    }

    function updateInterest(address borrower) public {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 rate = getCurrentInterestRate();
        uint256 interest = loan.principal.mul(rate).mul(elapsed).div(365 days).div(100);

        loan.interestAccrued = loan.interestAccrued.add(interest);
        loan.startTime = block.timestamp;
    }

    function repay() external payable whenRepaymentNotPaused nonReentrant notBlacklisted whenNotPaused {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 rate = getCurrentInterestRate();
        uint256 interest = loan.principal.mul(rate).mul(elapsed).div(365 days).div(100);
        uint256 lateFee = calculateLateFee(msg.sender);
        uint256 totalOwed = loan.principal.add(interest).add(lateFee);

        // Early repayment discount
        if (elapsed <= 15 days) {
            totalOwed = totalOwed.mul(uint256(100).sub(earlyRepaymentDiscountPercent)).div(100);
        }

        require(msg.value >= totalOwed, "Insufficient repay");

        totalBorrowed = totalBorrowed.sub(loan.principal);
        users[msg.sender].borrowed = 0;
        loan.isActive = false;

        uint256 excess = msg.value.sub(totalOwed);
        if (excess > 0) {
            (bool refund, ) = msg.sender.call{value: excess}("");
            require(refund, "Refund failed");
        }

        emit Repaid(msg.sender, totalOwed);
    }

    function partialRepay(address borrower) external payable whenRepaymentNotPaused nonReentrant notBlacklisted whenNotPaused {
        require(msg.value > 0, "Must send funds");
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan");

        updateInterest(borrower); // ensure interestAccrued is updated

        uint256 remaining = msg.value;

        // Step 1: Pay accrued interest + fees first
        uint256 totalInterestAndFees = loan.interestAccrued.add(calculateLateFee(borrower));
        if (remaining >= totalInterestAndFees) {
            remaining = remaining.sub(totalInterestAndFees);
            loan.interestAccrued = 0;
            loan.startTime = block.timestamp;
        } else {
            if (loan.interestAccrued >= remaining) {
                loan.interestAccrued = loan.interestAccrued.sub(remaining);
            } else {
                loan.interestAccrued = 0;
            }
            remaining = 0;
        }

        // Step 2: Reduce principal
        uint256 principalReduced = 0;
        if (remaining > 0) {
            if (remaining >= loan.principal) {
                principalReduced = loan.principal;
                remaining = remaining.sub(loan.principal);
                totalBorrowed = totalBorrowed.sub(loan.principal);
                users[borrower].borrowed = 0;
                loan.principal = 0;
                loan.isActive = false;
            } else {
                principalReduced = remaining;
                loan.principal = loan.principal.sub(remaining);
                users[borrower].borrowed = users[borrower].borrowed.sub(remaining);
                totalBorrowed = totalBorrowed.sub(remaining);
                remaining = 0;
            }
        }

        // Step 3: Refund leftovers
        if (remaining > 0) {
            (bool refund, ) = msg.sender.call{value: remaining}("");
            require(refund, "Refund failed");
        }

        emit PartialRepayment(msg.sender, borrower, msg.value, principalReduced);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Invalid amount");
        require(users[msg.sender].deposited >= amount, "Insufficient balance");
        require(address(this).balance.sub(ownerFees) >= amount, "Not enough liquidity");

        users[msg.sender].deposited = users[msg.sender].deposited.sub(amount);
        totalDeposits = totalDeposits.sub(amount);

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Withdraw failed");

        emit Withdrawn(msg.sender, amount);
    }

    function ownerWithdrawFees(uint256 amount) external onlyOwner {
        require(amount <= ownerFees, "Exceeds fees");
        ownerFees = ownerFees.sub(amount);

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Withdraw failed");

        emit OwnerWithdrawal(amount);
    }

    // --------- Helper ---------
    function getOutstandingDebt(address borrower) external view returns (uint256) {
        Loan storage loan = loans[borrower];
        if (!loan.isActive) return 0;

        uint256 elapsed = block.timestamp.sub(loan.startTime);
        uint256 rate = getCurrentInterestRate();
        uint256 interest = loan.principal.mul(rate).mul(elapsed).div(365 days).div(100);
        uint256 lateFee = calculateLateFee(borrower);

        return loan.principal.add(interest).add(lateFee);
    }

    function getLoanSummary(address borrower) external view returns (uint256 principal, uint256 interestAccrued, uint256 lateFee, bool isActive) {
        Loan storage loan = loans[borrower];
        principal = loan.principal;
        interestAccrued = loan.interestAccrued;
        lateFee = calculateLateFee(borrower);
        isActive = loan.isActive;
    }
}
