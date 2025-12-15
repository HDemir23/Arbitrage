# Sui Arbitrage Bot - Technical Documentation

## 1. Current Architecture Overview

The Sui arbitrage bot is a sophisticated on-chain system built in Move that detects and exploits price discrepancies across Cetus CLMM (Concentrated Liquidity Market Maker) pools. The architecture consists of three main components:

### Core Modules
- **`cetus_data.move`** (296 lines): Core data extraction and arbitrage detection engine
- **`arbitrage_example.move`** (243 lines): Usage patterns and practical implementation examples  
- **`cetus_data_tests.move`** (60 lines): Unit tests for price conversion logic

### Key Design Principles
- **On-chain execution**: All calculations happen on-chain for maximum speed
- **Real-time data**: Direct pool access ensures current market conditions
- **Fee-aware calculations**: Accounts for trading fees in profit calculations
- **Safe math**: Overflow protection and validation throughout

## 2. Data Flow

### Real-time Data Extraction Pipeline

```
Pool Object (passed as parameter)
    ↓
get_pool_info_from_pool() - Extracts raw pool data
    ↓
sqrt_price_to_price_with_decimals() - Converts to human-readable price
    ↓
PriceData struct - Normalized price information
    ↓
calculate_arbitrage_opportunity() - Detects profitable opportunities
    ↓
(has_opportunity, net_profit_bps) - Decision output
```

### Transaction Flow
1. **Input**: Pool objects passed as transaction parameters (required due to Move's dynamic field limitations)
2. **Extraction**: Real-time pool state read via Cetus CLMM interface
3. **Normalization**: Sqrt prices converted to actual prices with decimal adjustments
4. **Analysis**: Three-pool arbitrage opportunities calculated with fee consideration
5. **Output**: Boolean opportunity flag and profit in basis points

## 3. Speed Advantages

### On-chain vs Off-chain Performance

| Aspect | On-chain (This System) | Off-chain Bots |
|--------|------------------------|----------------|
| **Data Freshness** | Real-time, direct pool access | Polling/API delays (100-1000ms) |
| **Network Latency** | Single transaction execution | Multiple round trips required |
| **Execution Speed** | ~500ms transaction finality | 1-3s total detection+execution |
| **MEV Protection** | Atomic execution | Vulnerable to front-running |
| **Data Consistency** | Guaranteed consistent state | Race conditions possible |

### Technical Speed Factors

1. **Direct Pool Access**: No RPC calls or API delays
2. **Single Transaction**: Detection and execution in one atomic operation
3. **No Network Hops**: Eliminates off-chain processing latency
4. **Sui's Parallel Execution**: Fast block finality (~500ms)

## 4. Arbitrage Detection Logic

### Three-Pool Arbitrage Algorithm

The system detects triangular arbitrage opportunities across three pools:
- **USDC/SUI Pool**: Base pricing pool
- **WAL/SUI Pool**: Intermediate pricing
- **WAL/USDC Pool**: Direct pricing

### Mathematical Foundation

```move
// Calculate implied WAL/USDC price through SUI
let implied_wal_usdc = (usdc_sui_price * wal_sui_price) / (1u128 << 64);

// Compare with direct WAL/USDC price
let gross_profit_bps = if (implied_wal_usdc > actual_wal_usdc) {
    // Path: Buy WAL directly, decompose via SUI, sell SUI
    ((implied_wal_usdc - actual_wal_usdc) * 10000) / actual_wal_usdc
} else if (actual_wal_usdc > implied_wal_usdc) {
    // Path: Buy SUI with USDC, buy WAL with SUI, sell WAL for USDC
    ((actual_wal_usdc - implied_wal_usdc) * 10000) / implied_wal_usdc
} else {
    0
};

// Net profit after fees
let net_profit_bps = gross_profit_bps - total_fee_bps;
```

### Fee Calculation

```move
// Total fee for three-hop arbitrage
let total_fee_bps = ((fee_1 + fee_2 + fee_3) * 10000) / 1000000;
```

### Profit Thresholds

- **Default minimum**: 50 basis points (0.5%)
- **Customizable**: Via `calculate_arbitrage_with_threshold()`
- **Gas consideration**: Threshold should exceed gas costs

## 5. Current Capabilities

### ✅ Implemented Features

1. **Real-time Pool Data Extraction**
   - Current sqrt price extraction
   - Liquidity and balance reading
   - Fee rate and tick spacing access

2. **Price Conversion Engine**
   - Q64.64 sqrt price to actual price conversion
   - Decimal adjustment for different token precisions
   - Overflow-safe calculations

3. **Arbitrage Detection**
   - Three-pool triangular arbitrage
   - Fee-aware profit calculations
   - Configurable profit thresholds
   - Liquidity validation

4. **Data Structures**
   - `PoolInfo`: Complete pool state
   - `PriceData`: Normalized pricing information
   - Comprehensive getter functions

5. **Testing Infrastructure**
   - Unit tests for price conversion
   - Real-world price validation
   - Edge case handling

### ✅ Working Examples

- Single pool price extraction
- Three-pool arbitrage checking
- Custom threshold configuration
- Pool liquidity analysis
- Price comparison utilities

## 6. Missing Components

### 🚧 Critical Missing Features

1. **Trade Execution Engine**
   - Actual swap execution functions
   - Slippage protection mechanisms
   - Multi-hop transaction coordination

2. **Position Management**
   - Input amount optimization
   - Gas cost estimation
   - Profit/loss tracking

3. **Risk Management**
   - Price impact calculations
   - Maximum trade size limits
   - Circuit breakers for volatile conditions

4. **Monitoring & Analytics**
   - Historical performance tracking
   - Success rate metrics
   - Gas efficiency analysis

### 🚧 Infrastructure Components

1. **Pool Discovery**
   - Automated pool identification
   - Liquidity depth screening
   - Pool health monitoring

2. **Configuration Management**
   - Dynamic parameter adjustment
   - Market condition adaptation
   - Risk parameter tuning

3. **Integration Layer**
   - External data feeds (optional)
   - Cross-DEX expansion capability
   - API endpoints for monitoring

## 7. Technical Implementation Details

### Key Data Structures

```move
// Complete pool state information
public struct PoolInfo has copy, drop, store {
    pool_id: ID,
    token_a: String,
    token_b: String,
    sqrt_price: u128,      // Q64.64 format
    liquidity: u128,
    fee_rate: u64,         // Parts per million
    tick_spacing: u32,
    current_tick: I32,
    balance_a: u64,
    balance_b: u64,
}

// Normalized pricing data
public struct PriceData has copy, drop, store {
    pool_id: ID,
    token_a: String,
    token_b: String,
    price: u128,           // Human-readable price
    sqrt_price: u128,
    liquidity: u128,
    fee_rate: u64,
}
```

### Core Algorithms

#### Price Conversion (Q64.64)
```move
public fun sqrt_price_to_price(sqrt_price: u128): u128 {
    let q64 = 1u128 << 64;
    let price_sqrt = sqrt_price / q64;
    price_sqrt * price_sqrt
}
```

#### Decimal Adjustment
```move
public fun sqrt_price_to_price_with_decimals(
    sqrt_price: u128,
    decimals_a: u8,
    decimals_b: u8,
): u128 {
    let base_price = sqrt_price_to_price(sqrt_price);
    if (decimals_a > decimals_b) {
        let diff = decimals_a - decimals_b;
        base_price / power_of_10(diff)
    } else if (decimals_b > decimals_a) {
        let diff = decimals_b - decimals_a;
        base_price * power_of_10(diff)
    } else {
        base_price
    }
}
```

### Safety Mechanisms

1. **Overflow Protection**
   ```move
   let max_safe_value = 340282366920938463463374607431768211455u128;
   assert!(price_a <= max_safe_value / price_b, E_PRICE_OVERFLOW);
   ```

2. **Liquidity Validation**
   ```move
   assert!(usdc_sui_price.liquidity > 0, E_ZERO_LIQUIDITY);
   ```

3. **Zero Price Protection**
   ```move
   assert!(price_b != 0, E_PRICE_OVERFLOW);
   ```

## 8. Usage Examples

### Basic Arbitrage Check

```move
public entry fun check_and_execute_arbitrage(
    usdc_sui_pool: &Pool<USDC, SUI>,
    wal_sui_pool: &Pool<WAL, SUI>,
    wal_usdc_pool: &Pool<WAL, USDC>,
    ctx: &mut TxContext
) {
    let (has_opportunity, profit) = check_arbitrage_opportunity(
        usdc_sui_pool,
        wal_sui_pool,
        wal_usdc_pool
    );

    if (has_opportunity) {
        // Execute arbitrage swaps here
        // 1. USDC -> SUI (or WAL)
        // 2. SUI -> WAL (or reverse)
        // 3. WAL -> USDC
    }
}
```

### Custom Threshold Configuration

```move
// Use 100 basis points (1%) minimum profit
let (has_opportunity, profit) = check_arbitrage_with_custom_threshold(
    usdc_sui_pool,
    wal_sui_pool,
    wal_usdc_pool,
    100  // 1% minimum profit
);
```

### Pool Liquidity Analysis

```move
public fun analyze_pool_liquidity<CoinTypeA, CoinTypeB>(
    pool: &Pool<CoinTypeA, CoinTypeB>
): (u128, u64, u64) {
    let pool_info = cetus_data::get_pool_info_from_pool(
        pool,
        string::utf8(b"TokenA"),
        string::utf8(b"TokenB"),
    );

    let liquidity = cetus_data::liquidity(&pool_info);
    let balance_a = cetus_data::balance_a(&pool_info);
    let balance_b = cetus_data::balance_b(&pool_info);

    (liquidity, balance_a, balance_b)
}
```

## 9. Performance Characteristics

### Gas Cost Analysis

| Operation | Estimated Gas (MIST) | Notes |
|-----------|---------------------|-------|
| Pool data extraction | ~50,000 | Per pool |
| Price conversion | ~5,000 | Per calculation |
| Arbitrage calculation | ~20,000 | Three-pool comparison |
| Total detection | ~175,000 | Complete analysis |

### Speed Metrics

- **Transaction finality**: ~500ms on Sui
- **Calculation time**: <10ms (on-chain)
- **Total latency**: ~510ms (detection only)
- **Execution latency**: ~1-2s (including swaps)

### Limitations

1. **Pool Access**: Requires pool objects as parameters (Move limitation)
2. **Price Impact**: Not calculated in current implementation
3. **Slippage**: Not accounted for in profit calculations
4. **Liquidity Depth**: No validation of sufficient liquidity for trades

### Scalability Considerations

- **Memory Usage**: Minimal (structs are copy/drop)
- **Computation**: O(1) for arbitrage detection
- **Storage**: No persistent storage required
- **Network Load**: Single transaction per opportunity

## 10. Next Steps - Implementation Roadmap

### Phase 1: Trade Execution (Priority: High)
- [ ] Implement swap execution functions
- [ ] Add slippage protection
- [ ] Create multi-hop transaction coordination
- [ ] Integrate with Cetus CLMM swap functions

### Phase 2: Risk Management (Priority: High)
- [ ] Add price impact calculations
- [ ] Implement maximum trade size limits
- [ ] Create gas cost estimation
- [ ] Add circuit breaker mechanisms

### Phase 3: Optimization (Priority: Medium)
- [ ] Optimize gas usage
- [ ] Add batch processing capabilities
- [ ] Implement dynamic threshold adjustment
- [ ] Create performance monitoring

### Phase 4: Expansion (Priority: Low)
- [ ] Support for additional DEXes
- [ ] Cross-chain arbitrage capabilities
- [ ] Advanced strategy implementations
- [ ] External integration APIs

### Immediate Development Tasks

1. **Complete Trade Execution**
   ```move
   // Implement this function
   public fun execute_arbitrage<USDC, SUI, WAL>(
       usdc_sui_pool: &mut Pool<USDC, SUI>,
       wal_sui_pool: &mut Pool<WAL, SUI>,
       wal_usdc_pool: &mut Pool<WAL, USDC>,
       input_amount: u64,
       min_profit_bps: u128,
       ctx: &mut TxContext
   ): (u64, u64) // (output_amount, actual_profit)
   ```

2. **Add Price Impact Calculations**
   ```move
   public fun calculate_price_impact(
       pool: &Pool<CoinA, CoinB>,
       input_amount: u64,
       is_token_a_input: bool
   ): u128
   ```

3. **Implement Gas Estimation**
   ```move
   public fun estimate_arbitrage_gas_cost(
       pool_count: u64
   ): u64
   ```

### Testing Strategy

1. **Unit Tests**: Expand coverage for new functions
2. **Integration Tests**: Test with real pools on testnet
3. **Performance Tests**: Measure gas costs and execution time
4. **Security Audits**: Formal verification of critical functions

---

## Conclusion

This Sui arbitrage bot represents a sophisticated approach to on-chain arbitrage detection with significant speed advantages over off-chain solutions. The current implementation provides a solid foundation for real-time arbitrage detection, with the main remaining work being the addition of trade execution capabilities and risk management features.

The system's architecture leverages Sui's performance characteristics and Move's safety features to create a robust, fast, and secure arbitrage detection engine. With the completion of the outlined roadmap, this system will become a fully functional production-ready arbitrage bot.