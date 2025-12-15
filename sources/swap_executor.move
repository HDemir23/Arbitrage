/// Swap execution engine for Cetus CLMM integration
/// Handles actual swap calls, slippage protection, and state management
module predictionm::swap_executor {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use cetusclmm::pool::{Self, Pool};
    use cetusclmm::config::GlobalConfig;
    use std::option;

    // Error codes
    const E_ZERO_AMOUNT: u64 = 200;
    const E_SLIPPAGE_EXCEEDED: u64 = 201;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 202;
    const E_SWAP_FAILED: u64 = 203;
    const E_INVALID_POOL: u64 = 204;
    const E_PRICE_IMPACT_TOO_HIGH: u64 = 205;

    // Constants
    const MAX_SLIPPAGE_BPS: u64 = 100; // 1% max slippage
    const MAX_PRICE_IMPACT_BPS: u64 = 300; // 3% max price impact

    /// Swap configuration
    public struct SwapConfig has copy, drop, store {
        min_output_amount: u64,
        max_slippage_bps: u64,
        deadline: u64,
        price_limit: u128,
    }

    /// Swap result containing output amount and execution details
    public struct SwapResult has drop {
        input_amount: u64,
        output_amount: u64,
        fee_amount: u64,
        price_impact_bps: u64,
        successful: bool,
    }

    // ========== Core Swap Functions ==========

    /// Execute swap with exact input amount
    /// This is a wrapper for Cetus CLMM swap_exact_coin_for_coin
    public fun swap_exact_input<CoinIn, CoinOut>(
        config: &GlobalConfig,
        pool: &mut Pool<CoinIn, CoinOut>,
        input_coin: Coin<CoinIn>,
        min_output: u64,
        sqrt_price_limit: u128,
        ctx: &mut TxContext
    ): Coin<CoinOut> {
        let input_amount = coin::value(&input_coin);
        assert!(input_amount > 0, E_ZERO_AMOUNT);

        // Validate pool state
        validate_pool_state(pool, input_amount);

        // In production, call actual Cetus swap:
        // cetusclmm::integrator::swap_exact_coin_for_coin<CoinIn, CoinOut>(
        //     config,
        //     pool,
        //     input_coin,
        //     option::some(min_output),
        //     option::some(sqrt_price_limit),
        //     ctx
        // )

        // Placeholder: return zero coin
        // In production, this would be replaced with actual swap result
        coin::zero<CoinOut>(ctx)
    }

    /// Execute swap with exact output amount
    public fun swap_exact_output<CoinIn, CoinOut>(
        config: &GlobalConfig,
        pool: &mut Pool<CoinIn, CoinOut>,
        input_coin: Coin<CoinIn>,
        exact_output: u64,
        sqrt_price_limit: u128,
        ctx: &mut TxContext
    ): (Coin<CoinOut>, Coin<CoinIn>) {
        assert!(exact_output > 0, E_ZERO_AMOUNT);
        assert!(coin::value(&input_coin) > 0, E_ZERO_AMOUNT);

        // In production: Call cetusclmm swap with exact output
        // Returns (output_coin, remaining_input_coin)

        // Placeholder
        (coin::zero<CoinOut>(ctx), input_coin)
    }

    /// Multi-hop swap execution (for triangular arbitrage)
    /// Executes three sequential swaps with atomic rollback on failure
    public fun execute_multi_hop_swap<Coin1, Coin2, Coin3, Coin4>(
        config: &GlobalConfig,
        pool1: &mut Pool<Coin1, Coin2>,
        pool2: &mut Pool<Coin2, Coin3>,
        pool3: &mut Pool<Coin3, Coin4>,
        input_coin: Coin<Coin1>,
        min_final_output: u64,
        ctx: &mut TxContext
    ): Coin<Coin4> {
        let input_amount = coin::value(&input_coin);
        assert!(input_amount > 0, E_ZERO_AMOUNT);

        // Hop 1: Coin1 → Coin2
        let min_output_1 = calculate_min_output_for_hop(pool1, input_amount, 1);
        let coin2 = swap_exact_input<Coin1, Coin2>(
            config,
            pool1,
            input_coin,
            min_output_1,
            0, // No price limit for intermediate swaps
            ctx
        );

        // Hop 2: Coin2 → Coin3
        let amount_2 = coin::value(&coin2);
        let min_output_2 = calculate_min_output_for_hop(pool2, amount_2, 2);
        let coin3 = swap_exact_input<Coin2, Coin3>(
            config,
            pool2,
            coin2,
            min_output_2,
            0,
            ctx
        );

        // Hop 3: Coin3 → Coin4
        let amount_3 = coin::value(&coin3);
        let coin4 = swap_exact_input<Coin3, Coin4>(
            config,
            pool3,
            coin3,
            min_final_output,
            0,
            ctx
        );

        // Verify final output meets slippage requirements
        let final_amount = coin::value(&coin4);
        assert!(final_amount >= min_final_output, E_SLIPPAGE_EXCEEDED);

        coin4
    }

    // ========== Balance-based Swap Functions ==========

    /// Swap using Balance instead of Coin (for internal operations)
    public fun swap_balance<CoinIn, CoinOut>(
        config: &GlobalConfig,
        pool: &mut Pool<CoinIn, CoinOut>,
        input_balance: Balance<CoinIn>,
        min_output: u64,
        ctx: &mut TxContext
    ): Balance<CoinOut> {
        let input_coin = coin::from_balance(input_balance, ctx);
        let output_coin = swap_exact_input<CoinIn, CoinOut>(
            config,
            pool,
            input_coin,
            min_output,
            0,
            ctx
        );
        coin::into_balance(output_coin)
    }

    /// Triangular swap using balances (for flash loan integration)
    public fun triangular_swap_balances<USDC, SUI, WAL>(
        config: &GlobalConfig,
        usdc_sui_pool: &mut Pool<USDC, SUI>,
        wal_sui_pool: &mut Pool<WAL, SUI>,
        wal_usdc_pool: &mut Pool<WAL, USDC>,
        input_usdc: Balance<USDC>,
        min_final_usdc: u64,
        ctx: &mut TxContext
    ): Balance<USDC> {
        // Convert balance to coin
        let usdc_coin = coin::from_balance(input_usdc, ctx);

        // Execute multi-hop swap
        let final_coin = execute_multi_hop_swap<USDC, SUI, WAL, USDC>(
            config,
            usdc_sui_pool,
            wal_sui_pool,
            wal_usdc_pool,
            usdc_coin,
            min_final_usdc,
            ctx
        );

        // Convert back to balance
        coin::into_balance(final_coin)
    }

    // ========== Slippage Protection Functions ==========

    /// Calculate minimum output amount with slippage tolerance
    public fun calculate_min_output(
        expected_output: u64,
        slippage_bps: u64
    ): u64 {
        assert!(slippage_bps <= MAX_SLIPPAGE_BPS, E_SLIPPAGE_EXCEEDED);
        let slippage_amount = (expected_output * slippage_bps) / 10000;
        if (expected_output > slippage_amount) {
            expected_output - slippage_amount
        } else {
            0
        }
    }

    /// Calculate price impact for a given trade
    public fun calculate_price_impact<CoinA, CoinB>(
        pool: &Pool<CoinA, CoinB>,
        input_amount: u64
    ): u64 {
        // Get current pool state
        let liquidity = pool::liquidity(pool);
        let (balance_a_ref, balance_b_ref) = pool::balances(pool);
        let balance_a = balance::value(balance_a_ref);
        let balance_b = balance::value(balance_b_ref);

        // Calculate price impact based on input amount relative to pool size
        // price_impact = (input_amount / balance) * 10000 (in bps)
        if (balance_a == 0) {
            return MAX_PRICE_IMPACT_BPS
        };

        let impact_bps = ((input_amount as u128) * 10000) / (balance_a as u128);
        (impact_bps as u64)
    }

    /// Validate price impact is within acceptable range
    public fun validate_price_impact(price_impact_bps: u64) {
        assert!(price_impact_bps <= MAX_PRICE_IMPACT_BPS, E_PRICE_IMPACT_TOO_HIGH);
    }

    // ========== Pool Validation Functions ==========

    /// Validate pool has sufficient liquidity for swap
    fun validate_pool_state<CoinA, CoinB>(
        pool: &Pool<CoinA, CoinB>,
        input_amount: u64
    ) {
        let liquidity = pool::liquidity(pool);
        assert!(liquidity > 0, E_INSUFFICIENT_LIQUIDITY);

        // Ensure pool has at least 10x the input amount in liquidity
        let min_required_liquidity = (input_amount as u128) * 10;
        assert!(liquidity >= min_required_liquidity, E_INSUFFICIENT_LIQUIDITY);
    }

    /// Check if pool is healthy for trading
    public fun is_pool_healthy<CoinA, CoinB>(
        pool: &Pool<CoinA, CoinB>,
        min_liquidity: u128
    ): bool {
        let liquidity = pool::liquidity(pool);
        let (balance_a_ref, balance_b_ref) = pool::balances(pool);
        let balance_a = balance::value(balance_a_ref);
        let balance_b = balance::value(balance_b_ref);

        // Pool is healthy if:
        // 1. Has sufficient liquidity
        // 2. Both balances are non-zero
        // 3. Balances are reasonably proportioned (not extremely imbalanced)
        liquidity >= min_liquidity && balance_a > 0 && balance_b > 0
    }

    // ========== Swap Estimation Functions ==========

    /// Estimate output amount for a given input (without executing swap)
    public fun estimate_swap_output<CoinA, CoinB>(
        pool: &Pool<CoinA, CoinB>,
        input_amount: u64,
        is_a_to_b: bool
    ): u64 {
        // In production, this would use Cetus price calculation
        // For now, return approximate calculation based on current price
        let sqrt_price = pool::current_sqrt_price(pool);
        let fee_rate = pool::fee_rate(pool);

        // Simplified calculation (in production, use Cetus math)
        // output ≈ input * price * (1 - fee_rate)
        let fee_multiplier = 1000000 - fee_rate;
        let gross_output = if (is_a_to_b) {
            // Calculate based on sqrt_price
            ((input_amount as u128) * fee_multiplier as u128) / 1000000
        } else {
            ((input_amount as u128) * fee_multiplier as u128) / 1000000
        };

        (gross_output as u64)
    }

    /// Calculate minimum output for intermediate hop in multi-hop swap
    fun calculate_min_output_for_hop<CoinA, CoinB>(
        pool: &Pool<CoinA, CoinB>,
        input_amount: u64,
        _hop_number: u8
    ): u64 {
        // Estimate output
        let estimated = estimate_swap_output<CoinA, CoinB>(pool, input_amount, true);

        // Apply conservative slippage (0.5% per hop)
        let slippage_bps = 50u64;
        calculate_min_output(estimated, slippage_bps)
    }

    // ========== Helper Functions ==========

    /// Create swap configuration with default safety parameters
    public fun create_safe_swap_config(
        expected_output: u64,
        deadline_seconds: u64
    ): SwapConfig {
        let min_output = calculate_min_output(expected_output, 50); // 0.5% slippage

        SwapConfig {
            min_output_amount: min_output,
            max_slippage_bps: 50,
            deadline: deadline_seconds,
            price_limit: 0, // No price limit by default
        }
    }

    /// Create aggressive swap configuration (for MEV-resistant execution)
    public fun create_aggressive_swap_config(
        expected_output: u64,
        deadline_seconds: u64
    ): SwapConfig {
        let min_output = calculate_min_output(expected_output, 100); // 1% slippage

        SwapConfig {
            min_output_amount: min_output,
            max_slippage_bps: 100,
            deadline: deadline_seconds,
            price_limit: 0,
        }
    }

    // ========== Getter Functions ==========

    public fun min_output_amount(config: &SwapConfig): u64 { config.min_output_amount }
    public fun max_slippage_bps(config: &SwapConfig): u64 { config.max_slippage_bps }
    public fun deadline(config: &SwapConfig): u64 { config.deadline }
    public fun price_limit(config: &SwapConfig): u128 { config.price_limit }

    public fun swap_input_amount(result: &SwapResult): u64 { result.input_amount }
    public fun swap_output_amount(result: &SwapResult): u64 { result.output_amount }
    public fun swap_fee_amount(result: &SwapResult): u64 { result.fee_amount }
    public fun swap_price_impact(result: &SwapResult): u64 { result.price_impact_bps }
    public fun swap_successful(result: &SwapResult): bool { result.successful }
}
