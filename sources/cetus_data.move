/// Module for extracting real-time data from Cetus CLMM pools
/// Focuses on arbitrage opportunity detection across multiple pools
///
/// IMPORTANT: This module requires Pool objects to be passed as transaction parameters.
/// Pool objects cannot be loaded by ID in Move due to dynamic field access limitations.
/// See arbitrage_example.move for complete usage patterns.
module predictionm::cetus_data {
    use sui::balance;
    use std::string::String;
    use integer_mate::i32::I32;
    use cetusclmm::pool::{Self, Pool};

    // Error codes
    const E_PRICE_OVERFLOW: u64 = 1;
    const E_ZERO_LIQUIDITY: u64 = 4;

    // Minimum profit threshold in basis points (30 = 0.3%)
    // Can be overridden using calculate_arbitrage_with_threshold()
    const MIN_PROFIT_BPS: u128 = 30;

    /// Basic pool data structure containing essential pricing information
    public struct PoolInfo has copy, drop, store {
        pool_id: ID,
        token_a: String,
        token_b: String,
        sqrt_price: u128,      // Current sqrt price (Q64.64)
        liquidity: u128,       // Current liquidity
        fee_rate: u64,         // Fee rate (numerator, denominator is 1,000,000)
        tick_spacing: u32,     // Tick spacing
        current_tick: I32,     // Current tick index
        balance_a: u64,        // Balance of token A
        balance_b: u64,        // Balance of token B
    }

    /// Price data structure with human-readable price
    public struct PriceData has copy, drop, store {
        pool_id: ID,
        token_a: String,
        token_b: String,
        price: u128,           // Actual price (not sqrt)
        sqrt_price: u128,      // Original sqrt price
        liquidity: u128,
        fee_rate: u64,
    }

    /// Extracts pool information from a Cetus CLMM pool reference
    /// Reads real-time data from the pool using Cetus CLMM interface
    public fun get_pool_info_from_pool<CoinTypeA, CoinTypeB>(
        pool: &Pool<CoinTypeA, CoinTypeB>,
        token_a: String,
        token_b: String,
    ): PoolInfo {
        let pool_id = object::id(pool);
        let sqrt_price = pool::current_sqrt_price(pool);
        let liquidity_val = pool::liquidity(pool);
        let fee_rate_val = pool::fee_rate(pool);
        let tick_spacing_val = pool::tick_spacing(pool);
        let current_tick = pool::current_tick_index(pool);

        // Get balances
        let (balance_a_ref, balance_b_ref) = pool::balances(pool);
        let balance_a_val = balance::value(balance_a_ref);
        let balance_b_val = balance::value(balance_b_ref);

        PoolInfo {
            pool_id,
            token_a,
            token_b,
            sqrt_price,
            liquidity: liquidity_val,
            fee_rate: fee_rate_val,
            tick_spacing: tick_spacing_val,
            current_tick,
            balance_a: balance_a_val,
            balance_b: balance_b_val,
        }
    }

    // Note: Pool loading from ID is not possible in Move due to dynamic field access limitations
    // Pool objects must be passed as references in transaction parameters
    // See arbitrage_example.move for usage patterns

    /// Converts sqrt price (Q64.64) to actual price
    /// Formula: price = (sqrt_price / 2^64)^2
    public fun sqrt_price_to_price(sqrt_price: u128): u128 {
        // sqrt_price is in Q64.64 format
        // To get actual price: (sqrt_price / 2^64)^2
        let q64 = 1u128 << 64;
        let price_sqrt = sqrt_price / q64;
        price_sqrt * price_sqrt
    }

    /// Converts sqrt price to price with decimal adjustment
    /// Takes into account token decimals (typically 6 for USDC, 9 for SUI/WAL)
    public fun sqrt_price_to_price_with_decimals(
        sqrt_price: u128,
        decimals_a: u8,
        decimals_b: u8,
    ): u128 {
        // Basic sqrt price conversion
        let base_price = sqrt_price_to_price(sqrt_price);

        // Adjust for decimal differences
        // If token A has fewer decimals, price needs adjustment
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

    /// Helper function to calculate 10^n
    fun power_of_10(n: u8): u128 {
        let mut result = 1u128;
        let mut i = 0u8;
        while (i < n) {
            result = result * 10;
            i = i + 1;
        };
        result
    }

    // Pool extraction functions removed - pools must be passed as transaction parameters
    // For usage examples, see arbitrage_example.move

    /// Converts PoolInfo to PriceData with calculated price
    public fun pool_info_to_price_data(
        pool_info: &PoolInfo,
        decimals_a: u8,
        decimals_b: u8,
    ): PriceData {
        let price = sqrt_price_to_price_with_decimals(
            pool_info.sqrt_price,
            decimals_a,
            decimals_b,
        );

        PriceData {
            pool_id: pool_info.pool_id,
            token_a: pool_info.token_a,
            token_b: pool_info.token_b,
            price,
            sqrt_price: pool_info.sqrt_price,
            liquidity: pool_info.liquidity,
            fee_rate: pool_info.fee_rate,
        }
    }

    /// Extracts PriceData directly from a Cetus pool
    /// This combines pool data reading and price calculation in one function
    public fun get_price_data_from_pool<CoinTypeA, CoinTypeB>(
        pool: &Pool<CoinTypeA, CoinTypeB>,
        token_a: String,
        token_b: String,
        decimals_a: u8,
        decimals_b: u8,
    ): PriceData {
        let pool_id = object::id(pool);
        let sqrt_price = pool::current_sqrt_price(pool);
        let liquidity_val = pool::liquidity(pool);
        let fee_rate_val = pool::fee_rate(pool);

        // Calculate actual price from sqrt_price
        let price = sqrt_price_to_price_with_decimals(
            sqrt_price,
            decimals_a,
            decimals_b,
        );

        PriceData {
            pool_id,
            token_a,
            token_b,
            price,
            sqrt_price,
            liquidity: liquidity_val,
            fee_rate: fee_rate_val,
        }
    }

    /// Calculate arbitrage opportunity between three pools with fee consideration
    /// Returns (has_opportunity, net_profit_bps)
    /// Example: USDC -> SUI -> WAL -> USDC
    ///
    /// Net profit is calculated after subtracting fees from all three swaps
    /// Minimum profit threshold must be exceeded for opportunity to be considered viable
    public fun calculate_arbitrage_opportunity(
        usdc_sui_price: &PriceData,  // Price of SUI in USDC
        wal_sui_price: &PriceData,   // Price of WAL in SUI
        wal_usdc_price: &PriceData,  // Price of WAL in USDC
    ): (bool, u128) {
        calculate_arbitrage_with_threshold(
            usdc_sui_price,
            wal_sui_price,
            wal_usdc_price,
            MIN_PROFIT_BPS
        )
    }

    /// Calculate arbitrage opportunity with custom minimum profit threshold
    /// Returns (has_opportunity, net_profit_bps)
    ///
    /// min_profit_bps: Minimum profit in basis points (10000 = 100%)
    /// This should account for gas costs and slippage
    ///
    /// Note: This function checks for price discrepancies but does NOT account for:
    /// - Price impact from large trades
    /// - Actual liquidity depth required for the trade
    /// - Slippage during execution
    /// Callers should validate sufficient liquidity exists before executing trades.
    public fun calculate_arbitrage_with_threshold(
        usdc_sui_price: &PriceData,
        wal_sui_price: &PriceData,
        wal_usdc_price: &PriceData,
        min_profit_bps: u128,
    ): (bool, u128) {
        // Validate pool liquidity is non-zero
        assert!(usdc_sui_price.liquidity > 0, E_ZERO_LIQUIDITY);
        assert!(wal_sui_price.liquidity > 0, E_ZERO_LIQUIDITY);
        assert!(wal_usdc_price.liquidity > 0, E_ZERO_LIQUIDITY);

        // Calculate implied WAL/USDC price through SUI
        // Using safe math to avoid overflow
        let price_a = usdc_sui_price.price;
        let price_b = wal_sui_price.price;

        // Check for zero price (invalid pool state)
        assert!(price_b != 0, E_PRICE_OVERFLOW);
        assert!(price_a != 0, E_PRICE_OVERFLOW);

        // Check for potential overflow before multiplication
        let max_safe_value = 340282366920938463463374607431768211455u128; // u128::MAX
        assert!(price_a <= max_safe_value / price_b, E_PRICE_OVERFLOW);

        let implied_wal_usdc = (price_a * price_b) / (1u128 << 64);
        let actual_wal_usdc = wal_usdc_price.price;

        // Calculate total fees for the arbitrage path (3 swaps)
        // Fee rates are stored as numerator with denominator 1,000,000
        let fee_1 = (usdc_sui_price.fee_rate as u128);   // USDC -> SUI
        let fee_2 = (wal_sui_price.fee_rate as u128);     // SUI -> WAL (reverse)
        let fee_3 = (wal_usdc_price.fee_rate as u128);    // WAL -> USDC

        // Total fee in basis points (convert from per-million to per-10000)
        // Each swap incurs a fee, so total cost = fee_1 + fee_2 + fee_3
        let total_fee_bps = ((fee_1 + fee_2 + fee_3) * 10000) / 1000000;

        // Calculate gross profit before fees
        let gross_profit_bps = if (implied_wal_usdc > actual_wal_usdc) {
            // Path: Buy WAL with USDC directly, decompose to SUI, sell SUI for USDC
            ((implied_wal_usdc - actual_wal_usdc) * 10000) / actual_wal_usdc
        } else if (actual_wal_usdc > implied_wal_usdc) {
            // Path: Buy SUI with USDC, buy WAL with SUI, sell WAL for USDC
            ((actual_wal_usdc - implied_wal_usdc) * 10000) / implied_wal_usdc
        } else {
            0
        };

        // Net profit = Gross profit - Total fees
        let net_profit_bps = if (gross_profit_bps > total_fee_bps) {
            gross_profit_bps - total_fee_bps
        } else {
            0
        };

        // Opportunity exists only if net profit exceeds minimum threshold
        let has_opportunity = net_profit_bps >= min_profit_bps;

        (has_opportunity, net_profit_bps)
    }

    // Getter functions for PoolInfo
    public fun pool_id(pool_info: &PoolInfo): ID { pool_info.pool_id }
    public fun token_a(pool_info: &PoolInfo): String { pool_info.token_a }
    public fun token_b(pool_info: &PoolInfo): String { pool_info.token_b }
    public fun sqrt_price(pool_info: &PoolInfo): u128 { pool_info.sqrt_price }
    public fun liquidity(pool_info: &PoolInfo): u128 { pool_info.liquidity }
    public fun fee_rate(pool_info: &PoolInfo): u64 { pool_info.fee_rate }
    public fun balance_a(pool_info: &PoolInfo): u64 { pool_info.balance_a }
    public fun balance_b(pool_info: &PoolInfo): u64 { pool_info.balance_b }

    // Getter functions for PriceData
    public fun price_pool_id(price_data: &PriceData): ID { price_data.pool_id }
    public fun price_token_a(price_data: &PriceData): String { price_data.token_a }
    public fun price_token_b(price_data: &PriceData): String { price_data.token_b }
    public fun price(price_data: &PriceData): u128 { price_data.price }
    public fun price_sqrt(price_data: &PriceData): u128 { price_data.sqrt_price }
    public fun price_liquidity(price_data: &PriceData): u128 { price_data.liquidity }
    public fun price_fee_rate(price_data: &PriceData): u64 { price_data.fee_rate }
}
