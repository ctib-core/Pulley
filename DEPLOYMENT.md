# Pulley Contract Deployment Guide

This guide covers deploying the Pulley ecosystem to Core Chain and Anvil local network.

## 📋 Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Core Chain wallet with native tokens for gas
- Make utility installed (`sudo apt install make` on Ubuntu)

## 🚀 Quick Start

### 1. Setup Environment

```bash
# Clone and setup
git clone <your-repo>
cd Pulley_contract

# Install dependencies and setup environment
make dev-setup
```

### 2. Configure Environment

Copy `env.example` to `.env` and fill in your values:

```bash
cp env.example .env
nano .env  # or use your preferred editor
```

**Required values:**
- `PRIVATE_KEY`: Your deployment private key (without 0x prefix)
- `CORE_API_KEY`: Core Chain API key for verification

### 3. Deploy to Anvil (Local Testing)

```bash
# Start local Anvil node and deploy
make quick-deploy-anvil

# Or step by step:
make start-anvil
make deploy-anvil
```

### 4. Deploy to Core Chain

```bash
# Test deployment first (dry run)
make deploy-core-dry

# Deploy to Core Chain mainnet
make deploy-core
```

## 📖 Available Commands

### Development
```bash
make help              # Show all available commands
make install           # Install dependencies
make build             # Build contracts
make test              # Run all tests
make test-unit         # Run unit tests only
make test-fuzz         # Run fuzz tests only
make test-invariant    # Run invariant tests only
```

### Local Development
```bash
make start-anvil       # Start Anvil local node
make stop-anvil        # Stop Anvil node
make deploy-anvil      # Deploy to Anvil
make deploy-anvil-dry  # Dry run deployment to Anvil
make interact-anvil    # Interact with Anvil contracts
```

### Core Chain
```bash
make deploy-core       # Deploy to Core Chain
make deploy-core-dry   # Dry run deployment to Core Chain
make interact-core     # Interact with Core Chain contracts
make verify-core       # Verify contracts on Core Chain
```

### Utilities
```bash
make gas-report        # Generate gas usage report
make coverage          # Generate test coverage
make format            # Format code
make lint              # Lint code
make check-deployment  # Check deployment status
```

## 🏗️ Contract Architecture

The deployment includes the following contracts:

1. **PermissionManager** - Access control system
2. **PulleyToken** - ERC20 token with insurance backing
3. **PulleyTokenEngine** - Liquidity management and loss coverage
4. **TradingPool** - Trading pool with P&L tracking
5. **CrossChainController** - Cross-chain fund management
6. **Gateway** - Main user entry point

### User Flow
```
User → Gateway → {PulleyTokenEngine, TradingPool} → CrossChainController → LayerZero
```

## 🔧 Configuration

### Network Configuration

**Anvil (Local)**
- Chain ID: 31337
- RPC: http://localhost:8545
- Private Key: Default Anvil key (for testing)

**Core Chain (Mainnet)**
- Chain ID: 1116
- RPC: https://rpc.coredao.org
- Private Key: Your production key

### Contract Addresses

After deployment, update these addresses in your scripts:

```solidity
// Update in script/Interact.s.sol and script/CheckDeployment.s.sol
address constant GATEWAY_ADDRESS = 0x...;
address constant PULLEY_TOKEN_ADDRESS = 0x...;
address constant MOCK_USDC_ADDRESS = 0x...;
```

## 🧪 Testing Deployment

### 1. Run Interaction Script
```bash
# Test on Anvil
make interact-anvil

# Test on Core Chain
make interact-core
```

### 2. Check Deployment Status
```bash
make check-deployment
```

### 3. Manual Testing

```bash
# Connect to deployed contracts
cast call $GATEWAY_ADDRESS "getTradingPoolMetrics()" --rpc-url $CORE_CHAIN_URL

# Check Pulley token supply
cast call $PULLEY_TOKEN_ADDRESS "totalSupply()" --rpc-url $CORE_CHAIN_URL
```

## 🔐 Security Considerations

### Private Key Management
- **Never** commit private keys to version control
- Use environment variables or secure key management
- Consider using hardware wallets for mainnet deployments

### Permission Setup
The deployment automatically sets up permissions:
- Gateway can interact with PulleyTokenEngine and TradingPool
- Contracts can interact with each other as needed
- Admin retains control for emergency functions

### Verification
Always verify contracts after deployment:
```bash
make verify-core
```

## 🐛 Troubleshooting

### Common Issues

**1. "Private key not set"**
```bash
# Check your .env file
cat .env | grep PRIVATE_KEY
```

**2. "Insufficient funds"**
```bash
# Check your balance
cast balance $YOUR_ADDRESS --rpc-url $CORE_CHAIN_URL
```

**3. "Contract not deployed"**
```bash
# Check deployment status
make check-deployment
```

**4. "Permission denied"**
- Ensure your account has the necessary permissions
- Check if contracts are properly configured

### Debug Commands

```bash
# Verbose deployment
forge script script/Deploy.s.sol --rpc-url $ANVIL_URL --broadcast -vvvv

# Check contract code
cast code $CONTRACT_ADDRESS --rpc-url $CORE_CHAIN_URL

# Check transaction receipt
cast receipt $TX_HASH --rpc-url $CORE_CHAIN_URL
```

## 📊 Gas Estimates

Typical gas usage for deployment:

| Contract | Gas Used | USD Cost* |
|----------|----------|-----------|
| PermissionManager | ~500K | ~$2 |
| PulleyToken | ~1.2M | ~$5 |
| PulleyTokenEngine | ~2.1M | ~$8 |
| TradingPool | ~1.8M | ~$7 |
| CrossChainController | ~3.2M | ~$13 |
| Gateway | ~1.1M | ~$4 |
| **Total** | **~9.9M** | **~$39** |

*Estimates based on 20 gwei gas price and $2000 ETH

## 🔄 Upgrade Process

For future upgrades:

1. Deploy new implementation contracts
2. Update proxy contracts (if using proxies)
3. Update permission mappings
4. Verify new contracts
5. Test thoroughly before switching

## 📞 Support

For deployment issues:
1. Check this documentation
2. Review the troubleshooting section
3. Check contract verification on block explorer
4. Contact the Core-Connect team

## 🎯 Next Steps

After successful deployment:

1. **Test the complete user flow**
2. **Set up monitoring and alerts**
3. **Configure cross-chain endpoints**
4. **Add real asset addresses**
5. **Set up automated profit/loss reporting**
6. **Implement emergency pause functionality**

---

**⚠️ Important**: Always test thoroughly on Anvil before deploying to mainnet!


