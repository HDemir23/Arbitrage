/// Example module demonstrating how to use cetus_data for arbitrage detection
/// This shows practical patterns for working with Cetus pools
module predictionm::arbitrage_example {
    use predictionm::cetus_data::{Self, PoolInfo, PriceData};
    use cetusclmm::pool::Pool;
    use std::string;

    // Token decimal constants
    const USDC_DECIMALS: u8 = 6;
    const SUI_DECIMALS: u8 = 9;
    const WAL_DECIMALS: u8 = 9;

    /// Example: Extract price data from a single pool
    /// In a real transaction, you would receive the pool object as a parameter
    ///
    /// Usage in transaction:
    /// ```
    /// public entry fun my_transaction(
    ///     usdc_sui_pool: &Pool<USDC, SUI>,
    ///     ctx: &mut TxContext
    /// ) {
    ///     let price_data = get_usdc_sui_price(usdc_sui_pool);
    ///     // Use price_data...
    /// }
    /// ```
    public fun get_usdc_sui_price<CoinTypeA, CoinTypeB>(
        pool: &Pool<CoinTypeA, CoinTypeB>
    ): PriceData {
        cetus_data::get_price_data_from_pool(
            pool,
            string::utf8(b"USDC"),
            string::utf8(b"SUI"),
            USDC_DECIMALS,
            SUI_DECIMALS,
        )
    }

    /// Example: Check for arbitrage opportunity across three pools
    ///
    /// This function demonstrates the complete workflow:
    /// 1. Extract price data from three pools
    /// 2. Calculate arbitrage opportunity
    /// 3. Return whether profitable trade exists
    ///
    /// In a real transaction, you would:
    /// - Receive all three pool objects as parameters
    /// - Check if arbitrage exists
    /// - Execute the swaps if profitable
    ///
    /// Usage in transaction:
    /// ```
    /// public entry fun check_and_execute_arbitrage(
    ///     usdc_sui_pool: &Pool<USDC, SUI>,
    ///     wal_sui_pool: &Pool<WAL, SUI>,
    ///     wal_usdc_pool: &Pool<WAL, USDC>,
    ///     ctx: &mut TxContext
    /// ) {
    ///     let (has_opportunity, profit) = check_arbitrage_opportunity(
    ///         usdc_sui_pool,
    ///         wal_sui_pool,
    ///         wal_usdc_pool
    ///     );
    ///
    ///     if (has_opportunity) {
    ///         // Execute swaps here
    ///         // 1. Swap USDC -> SUI (or WAL)
    ///         // 2. Swap intermediate token
    ///         // 3. Swap back to USDC
    ///     }
    /// }
    /// ```
    public fun check_arbitrage_opportunity<USDC, SUI, WAL>(
        usdc_sui_pool: &Pool<USDC, SUI>,
        wal_sui_pool: &Pool<WAL, SUI>,
        wal_usdc_pool: &Pool<WAL, USDC>,
    ): (bool, u128) {
        // Extract price data from all three pools
        let usdc_sui_price = cetus_data::get_price_data_from_pool(
            usdc_sui_pool,
            string::utf8(b"USDC"),
            string::utf8(b"SUI"),
            USDC_DECIMALS,
            SUI_DECIMALS,
        );

        let wal_sui_price = cetus_data::get_price_data_from_pool(
            wal_sui_pool,
            string::utf8(b"WAL"),
            string::utf8(b"SUI"),
            WAL_DECIMALS,
            SUI_DECIMALS,
        );

        let wal_usdc_price = cetus_data::get_price_data_from_pool(
            wal_usdc_pool,
            string::utf8(b"WAL"),
            string::utf8(b"USDC"),
            WAL_DECIMALS,
            USDC_DECIMALS,
        );

        // Calculate arbitrage opportunity
        // Returns (has_opportunity, net_profit_in_basis_points)
        cetus_data::calculate_arbitrage_opportunity(
            &usdc_sui_price,
            &wal_sui_price,
            &wal_usdc_price,
        )
    }

    /// Example: Get detailed pool information
    ///
    /// This extracts complete pool data including balances and liquidity
    /// Useful for analyzing pool depth before executing large trades
    public fun get_pool_details<CoinTypeA, CoinTypeB>(
        pool: &Pool<CoinTypeA, CoinTypeB>,
        token_a_name: vector<u8>,
        token_b_name: vector<u8>,
    ): PoolInfo {
        cetus_data::get_pool_info_from_pool(
            pool,
            string::utf8(token_a_name),
            string::utf8(token_b_name),
        )
    }

    /// Example: Custom arbitrage check with higher profit threshold
    ///
    /// This demonstrates how to use a custom minimum profit threshold
    /// to account for gas costs and slippage
    public fun check_arbitrage_with_custom_threshold<USDC, SUI, WAL>(
        usdc_sui_pool: &Pool<USDC, SUI>,
        wal_sui_pool: &Pool<WAL, SUI>,
        wal_usdc_pool: &Pool<WAL, USDC>,
        min_profit_bps: u128,  // e.g., 100 = 1% minimum profit
    ): (bool, u128) {
        // Extract prices
        let usdc_sui_price = cetus_data::get_price_data_from_pool(
            usdc_sui_pool,
            string::utf8(b"USDC"),
            string::utf8(b"SUI"),
            USDC_DECIMALS,
            SUI_DECIMALS,
        );

        let wal_sui_price = cetus_data::get_price_data_from_pool(
            wal_sui_pool,
            string::utf8(b"WAL"),
            string::utf8(b"SUI"),
            WAL_DECIMALS,
            SUI_DECIMALS,
        );

        let wal_usdc_price = cetus_data::get_price_data_from_pool(
            wal_usdc_pool,
            string::utf8(b"WAL"),
            string::utf8(b"USDC"),
            WAL_DECIMALS,
            USDC_DECIMALS,
        );

        // Calculate with custom threshold
        cetus_data::calculate_arbitrage_with_threshold(
            &usdc_sui_price,
            &wal_sui_price,
            &wal_usdc_price,
            min_profit_bps,
        )
    }

    /// Example: Extract and display pool information
    ///
    /// This shows how to read individual fields from PoolInfo
    public fun analyze_pool_liquidity<CoinTypeA, CoinTypeB>(
        pool: &Pool<CoinTypeA, CoinTypeB>
    ): (u128, u64, u64) {
        let pool_info = cetus_data::get_pool_info_from_pool(
            pool,
            string::utf8(b"TokenA"),
            string::utf8(b"TokenB"),
        );

        // Extract key metrics
        let liquidity = cetus_data::liquidity(&pool_info);
        let balance_a = cetus_data::balance_a(&pool_info);
        let balance_b = cetus_data::balance_b(&pool_info);

        (liquidity, balance_a, balance_b)
    }

    // ========== Helper Functions for Price Analysis ==========

    /// Get the current sqrt price from a pool
    public fun get_sqrt_price<CoinTypeA, CoinTypeB>(
        pool: &Pool<CoinTypeA, CoinTypeB>
    ): u128 {
        let price_data = cetus_data::get_price_data_from_pool(
            pool,
            string::utf8(b"A"),
            string::utf8(b"B"),
            9, 9, // Default decimals
        );
        cetus_data::price_sqrt(&price_data)
    }

    /// Get the current price (not sqrt) from a pool
    public fun get_price<CoinTypeA, CoinTypeB>(
        pool: &Pool<CoinTypeA, CoinTypeB>,
        decimals_a: u8,
        decimals_b: u8,
    ): u128 {
        let price_data = cetus_data::get_price_data_from_pool(
            pool,
            string::utf8(b"A"),
            string::utf8(b"B"),
            decimals_a,
            decimals_b,
        );
        cetus_data::price(&price_data)
    }

    /// Compare liquidity across pools to find the deepest one
    public fun compare_pool_liquidity<A, B>(
        pool1: &Pool<A, B>,
        pool2: &Pool<A, B>,
    ): bool {
        let info1 = cetus_data::get_pool_info_from_pool(
            pool1,
            string::utf8(b"A"),
            string::utf8(b"B"),
        );

        let info2 = cetus_data::get_pool_info_from_pool(
            pool2,
            string::utf8(b"A"),
            string::utf8(b"B"),
        );

        // Returns true if pool1 has more liquidity
        cetus_data::liquidity(&info1) > cetus_data::liquidity(&info2)
    }
}
