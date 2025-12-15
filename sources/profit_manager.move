/// Profit calculation, tracking, and distribution module
/// Handles gas cost accounting, profit distribution, and treasury management
module predictionm::profit_manager {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID};
    use sui::event;
    use sui::transfer;

    // Error codes
    const E_INSUFFICIENT_PROFIT: u64 = 300;
    const E_ZERO_AMOUNT: u64 = 301;
    const E_INVALID_DISTRIBUTION: u64 = 302;
    const E_UNAUTHORIZED: u64 = 303;

    // Constants
    const TREASURY_SHARE_BPS: u64 = 1000; // 10% goes to treasury
    const REINVESTMENT_SHARE_BPS: u64 = 3000; // 30% for reinvestment
    const TRADER_SHARE_BPS: u64 = 6000; // 60% to trader
    const BASIS_POINTS: u64 = 10000;

    /// Profit tracking structure
    public struct ProfitTracker has key, store {
        id: UID,
        total_profits: u64,
        total_losses: u64,
        successful_trades: u64,
        failed_trades: u64,
        total_gas_spent: u64,
        total_fees_paid: u64,
    }

    /// Profit distribution result
    public struct ProfitDistribution has drop {
        gross_profit: u64,
        treasury_amount: u64,
        reinvestment_amount: u64,
        trader_amount: u64,
        gas_costs: u64,
        net_profit: u64,
    }

    /// Treasury object for holding protocol profits
    public struct Treasury<phantom CoinType> has key, store {
        id: UID,
        balance: Balance<CoinType>,
        total_collected: u64,
        withdrawal_count: u64,
    }

    // ========== Events ==========

    public struct ProfitEarnedEvent has copy, drop {
        trader: address,
        gross_profit: u64,
        net_profit: u64,
        gas_costs: u64,
        fees_paid: u64,
    }

    public struct ProfitDistributedEvent has copy, drop {
        trader: address,
        trader_share: u64,
        treasury_share: u64,
        reinvestment_share: u64,
    }

    public struct LossRecordedEvent has copy, drop {
        trader: address,
        loss_amount: u64,
        gas_costs: u64,
    }

    // ========== Core Functions ==========

    /// Calculate net profit after all costs
    public fun calculate_net_profit(
        gross_profit: u64,
        flash_loan_fee: u64,
        gas_costs: u64,
        swap_fees: u64
    ): u64 {
        let total_costs = flash_loan_fee + gas_costs + swap_fees;
        if (gross_profit > total_costs) {
            gross_profit - total_costs
        } else {
            0
        }
    }

    /// Calculate profit distribution according to protocol shares
    public fun calculate_profit_distribution(
        gross_profit: u64,
        gas_costs: u64,
        fees_paid: u64
    ): ProfitDistribution {
        let net_profit = if (gross_profit > (gas_costs + fees_paid)) {
            gross_profit - gas_costs - fees_paid
        } else {
            0
        };

        // Calculate shares
        let treasury_amount = (net_profit * TREASURY_SHARE_BPS) / BASIS_POINTS;
        let reinvestment_amount = (net_profit * REINVESTMENT_SHARE_BPS) / BASIS_POINTS;
        let trader_amount = (net_profit * TRADER_SHARE_BPS) / BASIS_POINTS;

        ProfitDistribution {
            gross_profit,
            treasury_amount,
            reinvestment_amount,
            trader_amount,
            gas_costs,
            net_profit,
        }
    }

    /// Distribute profit according to calculated shares
    public fun distribute_profit<CoinType>(
        profit_balance: Balance<CoinType>,
        distribution: &ProfitDistribution,
        trader: address,
        treasury: &mut Treasury<CoinType>,
        ctx: &mut TxContext
    ) {
        let total_profit = balance::value(&profit_balance);
        assert!(total_profit >= distribution.net_profit, E_INSUFFICIENT_PROFIT);

        // Split profit into shares
        let treasury_balance = balance::split(&mut profit_balance, distribution.treasury_amount);
        let reinvestment_balance = balance::split(&mut profit_balance, distribution.reinvestment_amount);
        // Remaining goes to trader

        // Add to treasury
        balance::join(&mut treasury.balance, treasury_balance);
        treasury.total_collected = treasury.total_collected + distribution.treasury_amount;

        // Send reinvestment to protocol address (could be staking, LP, etc.)
        let reinvestment_coin = coin::from_balance(reinvestment_balance, ctx);
        transfer::public_transfer(reinvestment_coin, trader); // For now, to trader

        // Send trader share
        let trader_coin = coin::from_balance(profit_balance, ctx);
        transfer::public_transfer(trader_coin, trader);

        // Emit event
        event::emit(ProfitDistributedEvent {
            trader,
            trader_share: distribution.trader_amount,
            treasury_share: distribution.treasury_amount,
            reinvestment_share: distribution.reinvestment_amount,
        });
    }

    /// Simple profit distribution (all to trader)
    public fun distribute_profit_simple<CoinType>(
        profit_balance: Balance<CoinType>,
        trader: address,
        ctx: &mut TxContext
    ) {
        let profit_amount = balance::value(&profit_balance);
        let profit_coin = coin::from_balance(profit_balance, ctx);
        transfer::public_transfer(profit_coin, trader);

        event::emit(ProfitEarnedEvent {
            trader,
            gross_profit: profit_amount,
            net_profit: profit_amount,
            gas_costs: 0,
            fees_paid: 0,
        });
    }

    // ========== Profit Tracker Functions ==========

    /// Create new profit tracker
    public fun create_profit_tracker(ctx: &mut TxContext): ProfitTracker {
        ProfitTracker {
            id: object::new(ctx),
            total_profits: 0,
            total_losses: 0,
            successful_trades: 0,
            failed_trades: 0,
            total_gas_spent: 0,
            total_fees_paid: 0,
        }
    }

    /// Record successful trade
    public fun record_successful_trade(
        tracker: &mut ProfitTracker,
        profit: u64,
        gas_cost: u64,
        fees: u64
    ) {
        tracker.total_profits = tracker.total_profits + profit;
        tracker.successful_trades = tracker.successful_trades + 1;
        tracker.total_gas_spent = tracker.total_gas_spent + gas_cost;
        tracker.total_fees_paid = tracker.total_fees_paid + fees;
    }

    /// Record failed trade
    public fun record_failed_trade(
        tracker: &mut ProfitTracker,
        loss: u64,
        gas_cost: u64
    ) {
        tracker.total_losses = tracker.total_losses + loss;
        tracker.failed_trades = tracker.failed_trades + 1;
        tracker.total_gas_spent = tracker.total_gas_spent + gas_cost;
    }

    /// Get net total profit
    public fun get_net_total_profit(tracker: &ProfitTracker): u64 {
        if (tracker.total_profits > tracker.total_losses) {
            tracker.total_profits - tracker.total_losses
        } else {
            0
        }
    }

    /// Calculate win rate
    public fun get_win_rate_bps(tracker: &ProfitTracker): u64 {
        let total_trades = tracker.successful_trades + tracker.failed_trades;
        if (total_trades == 0) {
            return 0
        };
        (tracker.successful_trades * 10000) / total_trades
    }

    /// Get average profit per successful trade
    public fun get_avg_profit_per_trade(tracker: &ProfitTracker): u64 {
        if (tracker.successful_trades == 0) {
            return 0
        };
        tracker.total_profits / tracker.successful_trades
    }

    // ========== Treasury Functions ==========

    /// Create new treasury
    public fun create_treasury<CoinType>(ctx: &mut TxContext): Treasury<CoinType> {
        Treasury {
            id: object::new(ctx),
            balance: balance::zero<CoinType>(),
            total_collected: 0,
            withdrawal_count: 0,
        }
    }

    /// Withdraw from treasury (admin only in production)
    public fun withdraw_from_treasury<CoinType>(
        treasury: &mut Treasury<CoinType>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(balance::value(&treasury.balance) >= amount, E_INSUFFICIENT_PROFIT);

        let withdrawn = balance::split(&mut treasury.balance, amount);
        let coin = coin::from_balance(withdrawn, ctx);
        transfer::public_transfer(coin, recipient);

        treasury.withdrawal_count = treasury.withdrawal_count + 1;
    }

    /// Get treasury balance
    public fun treasury_balance<CoinType>(treasury: &Treasury<CoinType>): u64 {
        balance::value(&treasury.balance)
    }

    // ========== Gas Cost Functions ==========

    /// Estimate gas cost for arbitrage transaction
    public fun estimate_arbitrage_gas_cost(): u64 {
        // Rough estimates for Sui gas costs:
        // - Flash loan initiation: ~500k gas
        // - Each swap: ~300k gas
        // - Flash loan repayment: ~300k gas
        // - Profit distribution: ~200k gas
        // Total: ~1.9M gas units
        // At typical gas price: ~0.002 SUI

        2000000 // 2M gas units as safety buffer
    }

    /// Calculate gas cost in coin terms
    public fun calculate_gas_cost_in_coin(
        gas_units: u64,
        gas_price: u64
    ): u64 {
        gas_units * gas_price
    }

    /// Check if profit covers minimum threshold after gas
    public fun is_profitable_after_gas(
        gross_profit: u64,
        gas_estimate: u64,
        min_profit_threshold: u64
    ): bool {
        if (gross_profit <= gas_estimate) {
            return false
        };
        let net_profit = gross_profit - gas_estimate;
        net_profit >= min_profit_threshold
    }

    // ========== Validation Functions ==========

    /// Validate profit distribution percentages sum to 100%
    public fun validate_distribution_shares(
        treasury_bps: u64,
        reinvestment_bps: u64,
        trader_bps: u64
    ): bool {
        treasury_bps + reinvestment_bps + trader_bps == BASIS_POINTS
    }

    /// Check if trade meets minimum profit requirements
    public fun meets_min_profit_requirement(
        net_profit: u64,
        min_profit_bps: u64,
        principal_amount: u64
    ): bool {
        let min_required = (principal_amount * min_profit_bps) / BASIS_POINTS;
        net_profit >= min_required
    }

    // ========== Getter Functions ==========

    // ProfitTracker getters
    public fun total_profits(tracker: &ProfitTracker): u64 { tracker.total_profits }
    public fun total_losses(tracker: &ProfitTracker): u64 { tracker.total_losses }
    public fun successful_trades(tracker: &ProfitTracker): u64 { tracker.successful_trades }
    public fun failed_trades(tracker: &ProfitTracker): u64 { tracker.failed_trades }
    public fun total_gas_spent(tracker: &ProfitTracker): u64 { tracker.total_gas_spent }
    public fun total_fees_paid(tracker: &ProfitTracker): u64 { tracker.total_fees_paid }

    // ProfitDistribution getters
    public fun gross_profit(dist: &ProfitDistribution): u64 { dist.gross_profit }
    public fun treasury_amount(dist: &ProfitDistribution): u64 { dist.treasury_amount }
    public fun reinvestment_amount(dist: &ProfitDistribution): u64 { dist.reinvestment_amount }
    public fun trader_amount(dist: &ProfitDistribution): u64 { dist.trader_amount }
    public fun gas_costs(dist: &ProfitDistribution): u64 { dist.gas_costs }
    public fun net_profit(dist: &ProfitDistribution): u64 { dist.net_profit }

    // Treasury getters
    public fun total_collected<CoinType>(treasury: &Treasury<CoinType>): u64 { treasury.total_collected }
    public fun withdrawal_count<CoinType>(treasury: &Treasury<CoinType>): u64 { treasury.withdrawal_count }
}
