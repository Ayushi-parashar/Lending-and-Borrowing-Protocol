# Lending and Borrowing Protocol

A decentralized lending and borrowing protocol built on Ethereum using Solidity and Hardhat, deployed on Core Testnet 2.

## Project Description

The Lending and Borrowing Protocol is a DeFi smart contract system that enables users to deposit funds, borrow against collateral, and earn interest. The protocol implements a secure and transparent lending mechanism with proper collateralization requirements, interest calculations, and liquidation mechanisms to ensure the protocol's stability and users' fund security.

The protocol features a collateral-based lending system where users must provide 150% collateral to borrow funds, with automatic liquidation when the collateral ratio falls below 120%. This ensures the protocol remains solvent while providing users with access to liquidity.

## Project Vision

Our vision is to create a fully decentralized, trustless, and efficient lending and borrowing ecosystem that democratizes access to financial services. We aim to eliminate traditional banking intermediaries while maintaining security and stability through smart contract automation and transparent governance.

The protocol seeks to become a cornerstone of the DeFi ecosystem by providing:
- Permissionless access to lending and borrowing services
- Competitive interest rates determined by market dynamics
- Robust risk management through over-collateralization
- Complete transparency through blockchain technology
- Global accessibility without geographical restrictions

## Key Features

### 🏦 **Core Lending Functions**
- **Deposit**: Users can deposit ETH to earn interest and provide liquidity to the protocol
- **Borrow**: Secure borrowing with 150% collateralization requirement
- **Repay**: Loan repayment with automatic interest calculation based on time elapsed

### 🔐 **Security & Risk Management**
- **Over-collateralization**: 150% collateral requirement ensures protocol stability
- **Liquidation System**: Automatic liquidation when collateral ratio drops below 120%
- **Reentrancy Protection**: Built-in security measures to prevent common attacks
- **Access Control**: Owner-only emergency functions for protocol management

### 📊 **Advanced Features**
- **Real-time Interest Calculation**: 5% annual interest rate calculated per second
- **Collateral Management**: Users can add additional collateral to existing loans
- **Protocol Statistics**: Comprehensive view of total deposits, loans, and liquidity
- **User Information**: Detailed user balance and loan information retrieval

### 🛡️ **Smart Contract Security**
- **OpenZeppelin Integration**: Utilizing battle-tested security libraries
- **SafeMath Operations**: Protection against integer overflow/underflow
- **Nonreentrant Modifiers**: Prevention of reentrancy attacks
- **Ownership Controls**: Secure admin functions for protocol management

## Future Scope

### 🚀 **Short-term Enhancements (3-6 months)**
- **Multi-token Support**: Expand beyond ETH to support ERC-20 tokens as collateral and borrowing assets
- **Dynamic Interest Rates**: Implement utilization-based interest rate models
- **Improved Liquidation**: Partial liquidation system and liquidation incentives
- **Frontend Integration**: Web3 user interface for seamless interaction

### 🌟 **Medium-term Development (6-12 months)**
- **Governance Token**: Launch native governance token for protocol decisions
- **Flash Loans**: Implement uncollateralized flash loan functionality
- **Cross-chain Support**: Expand to multiple blockchain networks
- **Advanced Analytics**: Real-time protocol metrics and user dashboards

### 🔮 **Long-term Vision (1-2 years)**
- **Institutional Features**: Large-scale lending solutions for institutions
- **Credit Scoring**: On-chain credit scoring system for unsecured loans
- **Insurance Integration**: Protocol insurance for additional security
- **Decentralized Governance**: Full transition to community-driven governance

### 📈 **Advanced DeFi Features**
- **Yield Farming**: Liquidity mining rewards for protocol participants
- **Automated Market Making**: Integration with AMM protocols for better liquidity
- **Derivatives Support**: Options and futures contracts on protocol assets
- **AI-Powered Risk Assessment**: Machine learning for improved risk management

## Technical Specifications

### Smart Contract Architecture
- **Solidity Version**: 0.8.20
- **Framework**: Hardhat
- **Security**: OpenZeppelin Contracts
- **Network**: Core Testnet 2 (Chain ID: 1115)

### Protocol Parameters
- **Collateral Ratio**: 150%
- **Liquidation Threshold**: 120%
- **Interest Rate**: 5% annually
- **Minimum Deposit**: No minimum
- **Gas Optimization**: Enabled with 200 runs

## Installation and Setup

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd lending-and-borrowing-protocol
   ```

2. **Install dependencies**
   ```bash
   npm install
   ```

3. **Configure environment**
   ```bash
   cp .env.example .env
   # Edit .env with your private key and other configurations
   ```

4. **Compile contracts**
   ```bash
   npm run compile
   ```

5. **Deploy to Core Testnet 2**
   ```bash
   npm run deploy
   ```

## Usage Examples

### Depositing Funds
```solidity
// Deposit 1 ETH to earn interest
contract.deposit{value: 1 ether}();
```

### Borrowing with Collateral
```solidity
// Borrow 0.5 ETH with 0.75 ETH collateral (150% ratio)
contract.borrow{value: 0.75 ether}(0.5 ether);
```

### Repaying Loan
```solidity
// Repay loan with interest
contract.repay{value: loanAmount + interest}();
```

## Testing

Run the test suite:
```bash
npm run test
```

## Security Considerations

- All functions use reentrancy guards
- Proper access control for administrative functions
- Input validation and error handling
- Gas optimization for cost efficiency
- Emergency withdrawal functionality for protocol safety

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Disclaimer

This protocol is experimental and should be used at your own risk. Always conduct thorough testing and auditing before deploying to mainnet. The protocol is provided as-is without any warranties.

0xEe20f3AfF9Efb303bf8896Ef182E512eC417061F
<img width="946" height="449" alt="Transactn" src="https://github.com/user-attachments/assets/514ed305-4b53-40cc-a45c-51f20194d822" />
