/// Main arbitrage orchestrator - coordinates all components
/// This is the entry point for executing complete arbitrage transactions
module predictionm::arbitrage_orchestrator {
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;
    use sui::event;
    use cetusclmm::pool::Pool;
    use cetusclmm::config::GlobalConfig;
    use std::string;

    use predictionm::cetus_data;
    use predictionm::swap_executor;
    use predictionm::profit_manager::{Self, AdminCap, Treasury};

    // Error codes
    const E_NO_ARBITRAGE_OPPORTUNITY: u64 = 400;
    const E_EXECUTION_FAILED: u64 = 403;

    // Constants
    const MIN_LIQUIDITY_MULTIPLIER: u128 = 10; // Need 10x liquidity vs trade size

    /// Complete arbitrage execution result
    public struct ArbitrageExecution has drop {
        input_amount: u64,
        output_amount: u64,
        gross_profit: u64,
        net_profit: u64,
        gas_cost: u64,
        total_fees: u64,
        execution_time_ms: u64,
        successful: bool,
    }

    /// Arbitrage opportunity detected event
    public struct OpportunityDetectedEvent has copy, drop {
        profit_bps: u128,
        estimated_profit: u64,
        usdc_sui_pool: address,
        sui_wal_pool: address,
        wal_usdc_pool: address,
    }

    /// Arbitrage executed event
    public struct ArbitrageExecutedEvent has copy, drop {
        trader: address,
        input_amount: u64,
        output_amount: u64,
        net_profit: u64,
        gas_cost: u64,
        successful: bool,
    }

    /// Arbitrage failed event
    public struct ArbitrageFailedEvent has copy, drop {
        trader: address,
        reason: u64, // Error code
        attempted_amount: u64,
    }

    // ========== Main Orchestration Functions ==========

    /// Complete arbitrage check and execution flow
    /// Main entry point for automated arbitrage
    /// ADMIN ONLY - requires AdminCap to execute
    /// Note: Pool types must match swap path - for USDC→SUI→WAL→USDC we need:
    ///   - Pool<USDC, SUI> for USDC→SUI
    ///   - Pool<SUI, WAL> for SUI→WAL
    ///   - Pool<WAL, USDC> for WAL→USDC
    public fun check_and_execute_arbitrage<USDC, SUI, WAL>(
        _admin: &AdminCap,  // Only admin can execute arbitrage
        config: &GlobalConfig,
        usdc_sui_pool: &mut Pool<USDC, SUI>,
        sui_wal_pool: &mut Pool<SUI, WAL>,
        wal_usdc_pool: &mut Pool<WAL, USDC>,
        treasury: &mut Treasury<USDC>,
        input_usdc: Coin<USDC>,
        min_profit_required: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let admin = tx_context::sender(ctx);
        let input_amount = coin::value(&input_usdc);

        // Phase 1: Validate opportunity exists
        let opportunity_result = validate_arbitrage_opportunity<USDC, SUI, WAL>(
            usdc_sui_pool,
            sui_wal_pool,
            wal_usdc_pool,
            input_amount,
            min_profit_required
        );

        if (!opportunity_result) {
            // No opportunity, return funds
            transfer::public_transfer(input_usdc, admin);
            event::emit(ArbitrageFailedEvent {
                trader: admin,
                reason: E_NO_ARBITRAGE_OPPORTUNITY,
                attempted_amount: input_amount,
            });
            return
        };

        // Phase 2: Execute swaps
        let execution_result = execute_arbitrage_swaps<USDC, SUI, WAL>(
            config,
            usdc_sui_pool,
            sui_wal_pool,
            wal_usdc_pool,
            treasury,
            input_usdc,
            min_profit_required,
            admin,
            clock,
            ctx
        );

        // Phase 3: Handle result
        if (execution_result.successful) {
            event::emit(ArbitrageExecutedEvent {
                trader: admin,
                input_amount: execution_result.input_amount,
                output_amount: execution_result.output_amount,
                net_profit: execution_result.net_profit,
                gas_cost: execution_result.gas_cost,
                successful: true,
            });
        } else {
            event::emit(ArbitrageFailedEvent {
                trader: admin,
                reason: E_EXECUTION_FAILED,
                attempted_amount: input_amount,
            });
        };
    }

    /// Validate that arbitrage opportunity exists and is profitable
    public fun validate_arbitrage_opportunity<USDC, SUI, WAL>(
        usdc_sui_pool: &Pool<USDC, SUI>,
        sui_wal_pool: &Pool<SUI, WAL>,
        wal_usdc_pool: &Pool<WAL, USDC>,
        input_amount: u64,
        min_profit: u64
    ): bool {
        // Step 1: Extract price data
        let price_usdc_sui = cetus_data::get_price_data_from_pool(
            usdc_sui_pool,
            string::utf8(b"USDC"),
            string::utf8(b"SUI"),
            6, 9
        );

        let price_wal_sui = cetus_data::get_price_data_from_pool(
            sui_wal_pool,
            string::utf8(b"WAL"),
            string::utf8(b"SUI"),
            9, 9
        );

        let price_wal_usdc = cetus_data::get_price_data_from_pool(
            wal_usdc_pool,
            string::utf8(b"WAL"),
            string::utf8(b"USDC"),
            9, 6
        );

        // Step 2: Calculate arbitrage opportunity
        let (has_opportunity, profit_bps) = cetus_data::calculate_arbitrage_opportunity(
            &price_usdc_sui,
            &price_wal_sui,
            &price_wal_usdc
        );

        if (!has_opportunity) {
            return false
        };

        // Step 3: Validate liquidity
        let liquidity_valid = validate_pool_liquidities<USDC, SUI, WAL>(
            usdc_sui_pool,
            sui_wal_pool,
            wal_usdc_pool,
            input_amount
        );

        if (!liquidity_valid) {
            return false
        };

        // Step 4: Estimate profit and check threshold
        let estimated_profit = ((input_amount as u128) * profit_bps) / 10000;
        let gas_estimate = profit_manager::estimate_arbitrage_gas_cost();

        if ((estimated_profit as u64) <= gas_estimate + min_profit) {
            return false
        };

        // Emit opportunity event
        event::emit(OpportunityDetectedEvent {
            profit_bps,
            estimated_profit: (estimated_profit as u64),
            usdc_sui_pool: @0x0, // Would be pool address in production
            sui_wal_pool: @0x0,
            wal_usdc_pool: @0x0,
        });

        true
    }

    /// Execute the three-way arbitrage swaps
    fun execute_arbitrage_swaps<USDC, SUI, WAL>(
        config: &GlobalConfig,
        usdc_sui_pool: &mut Pool<USDC, SUI>,
        sui_wal_pool: &mut Pool<SUI, WAL>,
        wal_usdc_pool: &mut Pool<WAL, USDC>,
        treasury: &mut Treasury<USDC>,
        input_usdc: Coin<USDC>,
        min_profit: u64,
        admin: address,
        clock: &Clock,
        ctx: &mut TxContext
    ): ArbitrageExecution {
        let input_amount = coin::value(&input_usdc);

        // Calculate minimum acceptable output
        let min_output = input_amount + min_profit;

        // Execute multi-hop swap with error handling
        // Note: Pool type must match swap direction (SUI,WAL not WAL,SUI)
        let output_usdc = swap_executor::execute_multi_hop_swap<USDC, SUI, WAL, USDC>(
            config,
            usdc_sui_pool,
            sui_wal_pool,  // This should be Pool<SUI, WAL>
            wal_usdc_pool,
            input_usdc,
            min_output,
            clock,
            ctx
        );

        let output_amount = coin::value(&output_usdc);

        // Calculate results
        let successful = output_amount >= min_output;
        let gross_profit = if (output_amount > input_amount) {
            output_amount - input_amount
        } else {
            0
        };

        let gas_estimate = profit_manager::estimate_arbitrage_gas_cost();
        let net_profit = if (gross_profit > gas_estimate) {
            gross_profit - gas_estimate
        } else {
            0
        };

        // Deposit ALL profits to treasury (100%)
        let profit_balance = coin::into_balance(output_usdc);
        profit_manager::distribute_profit(profit_balance, treasury, admin);

        ArbitrageExecution {
            input_amount,
            output_amount,
            gross_profit,
            net_profit,
            gas_cost: gas_estimate,
            total_fees: 0, // Would track actual fees in production
            execution_time_ms: 0, // Would track actual time
            successful,
        }
    }

    // ========== Validation Functions ==========

    /// Validate all pools have sufficient liquidity
    fun validate_pool_liquidities<USDC, SUI, WAL>(
        usdc_sui_pool: &Pool<USDC, SUI>,
        sui_wal_pool: &Pool<SUI, WAL>,
        wal_usdc_pool: &Pool<WAL, USDC>,
        input_amount: u64
    ): bool {
        let min_liquidity = (input_amount as u128) * MIN_LIQUIDITY_MULTIPLIER;

        // Check each pool
        let valid_1 = swap_executor::is_pool_healthy(usdc_sui_pool, min_liquidity);
        let valid_2 = swap_executor::is_pool_healthy(sui_wal_pool, min_liquidity);
        let valid_3 = swap_executor::is_pool_healthy(wal_usdc_pool, min_liquidity);

        valid_1 && valid_2 && valid_3
    }

    /// Pre-flight checks before execution
    public fun pre_flight_check<USDC, SUI, WAL>(
        usdc_sui_pool: &Pool<USDC, SUI>,
        sui_wal_pool: &Pool<SUI, WAL>,
        wal_usdc_pool: &Pool<WAL, USDC>,
        input_amount: u64,
        min_profit_bps: u64
    ): (bool, u128) {
        // Check 1: Pools are healthy
        if (!validate_pool_liquidities<USDC, SUI, WAL>(
            usdc_sui_pool,
            sui_wal_pool,
            wal_usdc_pool,
            input_amount
        )) {
            return (false, 0)
        };

        // Check 2: Arbitrage opportunity exists
        let price_usdc_sui = cetus_data::get_price_data_from_pool(
            usdc_sui_pool,
            string::utf8(b"USDC"),
            string::utf8(b"SUI"),
            6, 9
        );

        let price_wal_sui = cetus_data::get_price_data_from_pool(
            sui_wal_pool,
            string::utf8(b"WAL"),
            string::utf8(b"SUI"),
            9, 9
        );

        let price_wal_usdc = cetus_data::get_price_data_from_pool(
            wal_usdc_pool,
            string::utf8(b"WAL"),
            string::utf8(b"USDC"),
            9, 6
        );

        let (has_opportunity, profit_bps) = cetus_data::calculate_arbitrage_with_threshold(
            &price_usdc_sui,
            &price_wal_sui,
            &price_wal_usdc,
            (min_profit_bps as u128)
        );

        (has_opportunity, profit_bps)
    }

    // ========== Simulation Functions ==========

    /// Simulate arbitrage without executing (for testing/analysis)
    public fun simulate_arbitrage<USDC, SUI, WAL>(
        usdc_sui_pool: &Pool<USDC, SUI>,
        sui_wal_pool: &Pool<SUI, WAL>,
        wal_usdc_pool: &Pool<WAL, USDC>,
        input_amount: u64
    ): (bool, u64, u64) {
        // Extract prices
        let price_usdc_sui = cetus_data::get_price_data_from_pool(
            usdc_sui_pool,
            string::utf8(b"USDC"),
            string::utf8(b"SUI"),
            6, 9
        );

        let price_wal_sui = cetus_data::get_price_data_from_pool(
            sui_wal_pool,
            string::utf8(b"WAL"),
            string::utf8(b"SUI"),
            9, 9
        );

        let price_wal_usdc = cetus_data::get_price_data_from_pool(
            wal_usdc_pool,
            string::utf8(b"WAL"),
            string::utf8(b"USDC"),
            9, 6
        );

        // Calculate opportunity
        let (has_opportunity, profit_bps) = cetus_data::calculate_arbitrage_opportunity(
            &price_usdc_sui,
            &price_wal_sui,
            &price_wal_usdc
        );

        // Estimate profit
        let estimated_profit = ((input_amount as u128) * profit_bps) / 10000;
        let gas_cost = profit_manager::estimate_arbitrage_gas_cost();

        (has_opportunity, (estimated_profit as u64), gas_cost)
    }

    /// Estimate output amount for arbitrage
    public fun estimate_arbitrage_output<USDC, SUI, WAL>(
        usdc_sui_pool: &Pool<USDC, SUI>,
        sui_wal_pool: &Pool<SUI, WAL>,
        wal_usdc_pool: &Pool<WAL, USDC>,
        input_amount: u64
    ): u64 {
        // Estimate each hop
        let sui_amount = swap_executor::estimate_swap_output<USDC, SUI>(
            usdc_sui_pool,
            input_amount,
            true
        );

        let wal_amount = swap_executor::estimate_swap_output<SUI, WAL>(
            sui_wal_pool,
            sui_amount,
            true // SUI to WAL (a2b direction)
        );

        let usdc_amount = swap_executor::estimate_swap_output<WAL, USDC>(
            wal_usdc_pool,
            wal_amount,
            true
        );

        usdc_amount
    }

    // ========== Emergency Functions ==========

    /// Emergency cancel - returns funds to sender
    public fun emergency_return<CoinType>(
        coin: Coin<CoinType>,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(coin, sender);
    }

    // ========== Getter Functions ==========

    public fun execution_input_amount(exec: &ArbitrageExecution): u64 { exec.input_amount }
    public fun execution_output_amount(exec: &ArbitrageExecution): u64 { exec.output_amount }
    public fun execution_gross_profit(exec: &ArbitrageExecution): u64 { exec.gross_profit }
    public fun execution_net_profit(exec: &ArbitrageExecution): u64 { exec.net_profit }
    public fun execution_gas_cost(exec: &ArbitrageExecution): u64 { exec.gas_cost }
    public fun execution_successful(exec: &ArbitrageExecution): bool { exec.successful }
}
