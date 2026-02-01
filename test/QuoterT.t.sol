// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IQuoter } from "../src/upgrades/IQuoter.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IQuoterV2 as IAeroQuoter } from "@aerodrome-finance/slipstream/contracts/periphery/interfaces/IQuoterV2.sol";
import { ICLPool as IAeroPool } from "@aerodrome-finance/slipstream/contracts/core/interfaces/ICLPool.sol";
//import { }

interface IQuoterMathWrapper {
    struct QuoteParams {
        bool zeroForOne;
        bool exactInput;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quote(IUniswapV3Pool pool, int256 amount, QuoteParams memory params) 
    external
    view
    returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed);
}

contract QuoterTest is Test {
    IQuoter quoter;
    IAeroQuoter aeroQuoter;
    IQuoterMathWrapper wrapper;

    function setUp() public {
        quoter = IQuoter(0x222cA98F00eD15B1faE10B61c277703a194cf5d2);
        aeroQuoter = IAeroQuoter(0x254cF9E1E6e233aa1AC962CB9B05b2cfeAaE15b0);
        bytes memory bytecode = vm.getCode(
            "out/QuoterMathWrapper.sol/QuoterMathWrapper.json"
        );
        
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        wrapper = IQuoterMathWrapper(addr);
    }

    function testQuote() public view {
        IUniswapV3Pool pool = IUniswapV3Pool(0xd0b53D9277642d899DF5C87A3966A349A798F224);
        IQuoter.QuoteExactInputSingleWithPoolParams memory params = IQuoter.QuoteExactInputSingleWithPoolParams({
            tokenIn: 0x4200000000000000000000000000000000000006,
            tokenOut: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            amountIn: 1e18,
            pool: address(pool),
            fee: 500,
            sqrtPriceLimitX96: 4295128740
        });

        (uint256 amountOut, , , ) = quoter.quoteExactInputSingleWithPool(params);
        console.log("Amount out:", amountOut);
    }

    function test_AeroQuote() public {
        uint256 gasStart = gasleft();
        IAeroPool pool = IAeroPool(0x7DE6c3Cf1C8b1E3b3f0D1B3A2e5e8E3ff4B2A1C3);

        IAeroQuoter.QuoteExactInputSingleParams memory params = IAeroQuoter.QuoteExactInputSingleParams({
            tokenIn: 0x4200000000000000000000000000000000000006,
            tokenOut: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            amountIn: 1e18,
            tickSpacing: 100,
            sqrtPriceLimitX96: 4295128740
        });

        (uint256 amountOut, , , ) = aeroQuoter.quoteExactInputSingle(params);

        console.log("Aero Amount out (cold): ", amountOut);


        console.log("Aero Gas used (cold): ", gasStart - gasleft());


        gasStart = gasleft();

        (amountOut, , , ) = aeroQuoter.quoteExactInputSingle(params);
        console.log("Aero Amount out (warm): ", amountOut);
        console.log("Aero Gas used (warm): ", gasStart - gasleft());
    }

    function test_UniQuoteWithLibrary() public {
        uint256 gasStart = gasleft();
        IUniswapV3Pool pool = IUniswapV3Pool(0xd0b53D9277642d899DF5C87A3966A349A798F224);

        IQuoterMathWrapper.QuoteParams memory params = IQuoterMathWrapper.QuoteParams({
            zeroForOne: true,
            exactInput: true,
            fee: 500,
            sqrtPriceLimitX96: 4295128740
        });

        (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed) = 
            wrapper.quote(pool, 1e18, params);

        console.log("Uni Amount0 out (cold): ", amount0);
        console.log("Uni Amount1 out (cold): ", amount1);
        console.log("Uni Gas used (cold): ", gasStart - gasleft());

        gasStart = gasleft();

        (amount0, amount1, sqrtPriceAfterX96, initializedTicksCrossed) = 
            wrapper.quote(pool, 1e18, params);
        console.log("Uni Amount0 out (warm): ", amount0);
        console.log("Uni Amount1 out (warm): ", amount1);
        console.log("Uni Gas used (warm): ", gasStart - gasleft());
    }

    function test_AeroQuoteWithLibrary() public {
        uint256 gasStart = gasleft();
        IUniswapV3Pool pool = IUniswapV3Pool(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59); // this is a Aero CL pool
        IQuoterMathWrapper.QuoteParams memory params = IQuoterMathWrapper.QuoteParams({
            zeroForOne: true,
            exactInput: true,
            fee: 500,
            sqrtPriceLimitX96: 4295128740
        });

        (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed) = 
            wrapper.quote(pool, 1e18, params);
        console.log("Aero Amount0 out (cold): ", amount0);
        console.log("Aero Amount1 out (cold): ", amount1);
        console.log("Aero Gas used (cold): ", gasStart - gasleft());

        gasStart = gasleft();

        (amount0, amount1, sqrtPriceAfterX96, initializedTicksCrossed) = 
            wrapper.quote(pool, 1e18, params);
        console.log("Aero Amount0 out (warm): ", amount0);
        console.log("Aero Amount1 out (warm): ", amount1);
        console.log("Aero Gas used (warm): ", gasStart - gasleft());
    }
}