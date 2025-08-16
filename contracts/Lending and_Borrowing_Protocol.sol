    // --- New: withdraw collateral (if still healthy) ---
    function withdrawCollateral(uint256 amount) external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan");
        require(amount > 0 && amount <= loan.collateral, "Invalid amount");

        // Check if loan remains healthy after collateral withdrawal
        uint256 newCollateral = loan.collateral.sub(amount);
        uint256 ratio = newCollateral.mul(100).div(loan.amount);
        require(ratio >= COLLATERAL_RATIO, "Would fall below collateral ratio");

        // Update state
        loan.collateral = newCollateral;
        users[msg.sender].collateralDeposited = users[msg.sender].collateralDeposited.sub(amount);
        totalCollateral = totalCollateral.sub(amount);

        payable(msg.sender).transfer(amount);
    }
