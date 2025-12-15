/// Tests for Cetus data extraction module
#[test_only]
module predictionm::cetus_data_tests {
    use predictionm::cetus_data;

    #[test]
    fun test_sqrt_price_conversion() {
        // Test basic sqrt price to price conversion
        // sqrt_price in Q64.64 format
        // Example: if sqrt_price = 2^64, then price = 1
        let sqrt_price = 1u128 << 64; // 2^64
        let price = cetus_data::sqrt_price_to_price(sqrt_price);

        // Price should be 1 (since (2^64 / 2^64)^2 = 1)
        assert!(price == 1, 0);
    }

    #[test]
    fun test_sqrt_price_conversion_with_decimals() {
        // Test with USDC (6 decimals) and SUI (9 decimals)
        let sqrt_price = 1u128 << 64;

        // USDC has 6 decimals, SUI has 9 decimals
        let price = cetus_data::sqrt_price_to_price_with_decimals(
            sqrt_price,
            6, // USDC decimals
            9, // SUI decimals
        );

        // With 3 decimal difference, price should be adjusted
        assert!(price == 1000, 1); // 1 * 10^3
    }

    #[test]
    fun test_real_world_sqrt_price() {
        // Test with a realistic sqrt price value
        // If SUI = $4 USDC, and accounting for decimals:
        // USDC has 6 decimals, SUI has 9 decimals
        // sqrt(4 * 10^3) = 63.24... ≈ 63 (simplified)
        // In Q64.64: 63 * 2^64

        let sqrt_price = 63u128 << 64;
        let price = cetus_data::sqrt_price_to_price_with_decimals(
            sqrt_price,
            6, // USDC decimals
            9, // SUI decimals
        );

        // Price should be approximately 63^2 * 1000 = 3,969,000
        // (accounting for the 3 decimal difference)
        assert!(price > 3900000 && price < 4000000, 12);
    }

    // Note: Tests for get_pool_info_from_pool and extract functions removed
    // These require actual Pool objects which cannot be easily mocked in tests
    // For integration testing, use a testnet deployment with real pools
    //
    // See arbitrage_example.move for usage patterns with actual Pool references
}
