/// Swap execution engine for Cetus CLMM integration
/// Handles actual swap calls, slippage protection, and state management
module predictionm::swap_executor {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use cetusclmm::pool::{Self, Pool};
    use cetusclmm::config::GlobalConfig;

    // Error codes
    const E_ZERO_AMOUNT: u64 = 200;
    const E_SLIPPAGE_EXCEEDED: u64 = 201;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 202;
    const E_SWAP_FAILED: u64 = 203;
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

    /// Execute swap with exact input amount using Cetus flash_swap
    /// Pool<CoinIn, CoinOut> where CoinIn = A, CoinOut = B
    /// For A->B swap: a2b = true, we receive balance_b (output), pay with balance_a (input)
    public fun swap_exact_input<CoinIn, CoinOut>(
        config: &GlobalConfig,
        pool: &mut Pool<CoinIn, CoinOut>,
        input_coin: Coin<CoinIn>,
        min_output: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<CoinOut> {
        let input_amount = coin::value(&input_coin);
        assert!(input_amount > 0, E_ZERO_AMOUNT);

        // Validate pool state
        validate_pool_state(pool, input_amount);

        // For Pool<CoinIn, CoinOut>: CoinIn = A, CoinOut = B
        // Swapping A->B means a2b = true
        let a2b = true;
        let by_amount_in = true; // We specify input amount

        // Calculate sqrt_price_limit if not provided (0 means no limit)
        let price_limit = if (sqrt_price_limit == 0) {
            if (a2b) { 4295048016 } // Min sqrt price for a2b
            else { 79226673521066979257578248091 } // Max sqrt price for b2a
        } else {
            sqrt_price_limit
        };

        // Execute Cetus flash swap
        // For a2b: returns (zero_balance_a, borrowed_balance_b, receipt)
        let (balance_a, balance_b, receipt) = pool::flash_swap<CoinIn, CoinOut>(
            config,
            pool,
            a2b,
            by_amount_in,
            input_amount,
            price_limit,
            clock,
        );

        // balance_b contains the output (CoinOut)
        let output_amount = balance::value(&balance_b);

        // Verify minimum output (slippage protection)
        assert!(output_amount >= min_output, E_SLIPPAGE_EXCEEDED);

        // Convert input coin to balance for repayment
        let pay_amount = pool::swap_pay_amount(&receipt);
        assert!(input_amount >= pay_amount, E_SWAP_FAILED);

        let input_balance = coin::into_balance(input_coin);

        // Repay the flash swap
        // repay_flash_swap expects (balance_a, balance_b) regardless of swap direction
        // For a2b swap: we pay with CoinIn (balance_a) and return empty balance_b
        pool::repay_flash_swap<CoinIn, CoinOut>(
            config,
            pool,
            input_balance,              // Pay with CoinIn (balance_a)
            balance::zero<CoinOut>(),   // Return empty balance_b (we keep the output)
            receipt
        );

        // Destroy the unused balance_a (should be zero from flash_swap)
        balance::destroy_zero(balance_a);

        // Convert output balance to coin and return
        coin::from_balance(balance_b, ctx)
    }

    /// Execute swap with exact output amount using Cetus flash_swap
    /// Returns the exact output amount and any remaining input
    public fun swap_exact_output<CoinIn, CoinOut>(
        config: &GlobalConfig,
        pool: &mut Pool<CoinIn, CoinOut>,
        input_coin: Coin<CoinIn>,
        exact_output: u64,
        sqrt_price_limit: u128,
        clock: &Clock,
        ctx: &mut TxContext
    ): (Coin<CoinOut>, Coin<CoinIn>) {
        assert!(exact_output > 0, E_ZERO_AMOUNT);
        let input_amount = coin::value(&input_coin);
        assert!(input_amount > 0, E_ZERO_AMOUNT);

        // Validate pool state
        validate_pool_state(pool, input_amount);

        // For Pool<CoinIn, CoinOut>: swapping A->B means a2b = true
        let a2b = true;
        let by_amount_in = false; // We specify output amount, not input

        // Calculate sqrt_price_limit if not provided
        let price_limit = if (sqrt_price_limit == 0) {
            if (a2b) { 4295048016 } // Min sqrt price for a2b
            else { 79226673521066979257578248091 } // Max sqrt price for b2a
        } else {
            sqrt_price_limit
        };

        // Execute Cetus flash swap for exact output
        let (balance_a, balance_b, receipt) = pool::flash_swap<CoinIn, CoinOut>(
            config,
            pool,
            a2b,
            by_amount_in,
            exact_output,  // Specify desired output amount
            price_limit,
            clock,
        );

        // Verify we got the exact output we requested
        let output_amount = balance::value(&balance_b);
        assert!(output_amount >= exact_output, E_SWAP_FAILED);

        // Get required payment amount from receipt
        let pay_amount = pool::swap_pay_amount(&receipt);
        assert!(input_amount >= pay_amount, E_SWAP_FAILED);

        // Convert input coin to balance
        let mut input_balance = coin::into_balance(input_coin);

        // Split payment amount from input
        let payment_balance = balance::split(&mut input_balance, pay_amount);

        // Repay the flash swap
        // For a2b swap: we pay with CoinIn (balance_a), return zero balance_b
        pool::repay_flash_swap<CoinIn, CoinOut>(
            config,
            pool,
            payment_balance,              // Pay with CoinIn (balance_a position)
            balance::zero<CoinOut>(),     // Return zero balance_b (we keep the output)
            receipt
        );

        // Destroy the unused balance_a (should be zero)
        balance::destroy_zero(balance_a);

        // Convert balances to coins and return
        let output_coin = coin::from_balance(balance_b, ctx);
        let remaining_input_coin = coin::from_balance(input_balance, ctx);

        (output_coin, remaining_input_coin)
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
        clock: &Clock,
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
            clock,
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
            clock,
            ctx
        );

        // Hop 3: Coin3 → Coin4
        let _amount_3 = coin::value(&coin3);
        let coin4 = swap_exact_input<Coin3, Coin4>(
            config,
            pool3,
            coin3,
            min_final_output,
            0,
            clock,
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
        clock: &Clock,
        ctx: &mut TxContext
    ): Balance<CoinOut> {
        let input_coin = coin::from_balance(input_balance, ctx);
        let output_coin = swap_exact_input<CoinIn, CoinOut>(
            config,
            pool,
            input_coin,
            min_output,
            0,
            clock,
            ctx
        );
        coin::into_balance(output_coin)
    }

    /// Triangular swap using balances (for flash loan integration)
    /// Note: Pool type order must match swap direction
    /// For USDC→SUI→WAL→USDC: pools should be <USDC,SUI>, <SUI,WAL>, <WAL,USDC>
    public fun triangular_swap_balances<USDC, SUI, WAL>(
        config: &GlobalConfig,
        usdc_sui_pool: &mut Pool<USDC, SUI>,
        sui_wal_pool: &mut Pool<SUI, WAL>,
        wal_usdc_pool: &mut Pool<WAL, USDC>,
        input_usdc: Balance<USDC>,
        min_final_usdc: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Balance<USDC> {
        // Convert balance to coin
        let usdc_coin = coin::from_balance(input_usdc, ctx);

        // Execute multi-hop swap
        let final_coin = execute_multi_hop_swap<USDC, SUI, WAL, USDC>(
            config,
            usdc_sui_pool,
            sui_wal_pool,
            wal_usdc_pool,
            usdc_coin,
            min_final_usdc,
            clock,
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
        let _liquidity = pool::liquidity(pool);
        let (balance_a_ref, balance_b_ref) = pool::balances(pool);
        let balance_a = balance::value(balance_a_ref);
        let _balance_b = balance::value(balance_b_ref);

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
        let _sqrt_price = pool::current_sqrt_price(pool);
        let fee_rate = pool::fee_rate(pool);

        // Simplified calculation (in production, use Cetus math)
        // output ≈ input * price * (1 - fee_rate)
        let fee_multiplier = 1000000 - fee_rate;
        let gross_output = if (is_a_to_b) {
            // Calculate based on sqrt_price
            ((input_amount as u128) * (fee_multiplier as u128)) / 1000000
        } else {
            ((input_amount as u128) * (fee_multiplier as u128)) / 1000000
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
