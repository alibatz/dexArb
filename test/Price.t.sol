// SPDX-License-Identifier: UNLICENSED
// Unit tests for the 64.64 fixed-point price calculations across the 3-pool triangle.
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IQuoter } from "../src/upgrades/IQuoter.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IQuoterV2 as IAeroQuoter } from "@aerodrome-finance/slipstream/contracts/periphery/interfaces/IQuoterV2.sol";
import { ICLPool as IAeroPool } from "@aerodrome-finance/slipstream/contracts/core/interfaces/ICLPool.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ABDKMath64x64 as math } from "abdk-libraries-solidity/ABDKMath64x64.sol";

contract PriceTest is Test {
    IUniswapV3Pool internal toVirtual;
    IUniswapV3Pool internal toUSDC;
    IUniswapV3Pool internal toWETH;

    function setUp() public {
        toVirtual = IUniswapV3Pool(0x3f0296BF652e19bca772EC3dF08b32732F93014A);
        toUSDC = IUniswapV3Pool(0x529d2863a1521d0b57db028168fdE2E97120017C);
        toWETH = IUniswapV3Pool(0xb4CB800910B228ED3d0834cF79D697127BBB00e5);
    }

    // Helper to get sqrtPriceX96 via low-level call (works with different slot0 signatures)
    function getSqrtPriceX96(address pool) internal view returns (uint160 sqrtPriceX96) {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        require(success, "slot0 call failed");
        assembly {
            sqrtPriceX96 := mload(add(data, 32))
        }
    }

    function test_calculatePrice() public view {
        address currentToken = 0x4200000000000000000000000000000000000006; // WETH

        // Start with effectivePrice = 1 (in 64.64 fixed point)
        int128 effectivePrice = math.fromUInt(1);
        
        // Pool 1: toVirtual
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toVirtual));
            address token0 = toVirtual.token0();
            address token1 = toVirtual.token1();
            
            // price = (sqrtPriceX96 / 2^96)^2 = sqrtPriceX96^2 / 2^192
            // This gives token1/token0 (how many token1 per token0)
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            if (currentToken == token0) {
                // We have token0, multiply by price to get token1 equivalent
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                // We have token1, divide by price to get token0 equivalent
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
        }
        
        // Pool 2: toUSDC
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toUSDC));
            address token0 = toUSDC.token0();
            address token1 = toUSDC.token1();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
        }
        
        // Pool 3: toWETH
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toWETH));
            address token0 = toWETH.token0();
            address token1 = toWETH.token1();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
        }
        
        // Convert to uint for logging (multiply by 1e18 for decimal representation)
        uint256 priceScaled = math.mulu(effectivePrice, 1e18);
        console.log("Effective price (scaled by 1e18):", priceScaled);
    }


    function test_calculatePriceWithFees() public view {
        address currentToken = 0x4200000000000000000000000000000000000006; // WETH

        // Start with effectivePrice = 1 (in 64.64 fixed point)
        int128 effectivePrice = math.fromUInt(1);
        
        // Pool 1: toVirtual
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toVirtual));
            address token0 = toVirtual.token0();
            address token1 = toVirtual.token1();
            uint24 fee = toVirtual.fee();
            
            // price = (sqrtPriceX96 / 2^96)^2
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            // Fee factor: (1 - fee/1e6)
            int128 feeFactor = math.divu(uint256(1e6 - fee), 1e6);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
            // Apply fee after swap
            effectivePrice = math.mul(effectivePrice, feeFactor);
        }
        
        // Pool 2: toUSDC
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toUSDC));
            address token0 = toUSDC.token0();
            address token1 = toUSDC.token1();
            uint24 fee = toUSDC.fee();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            int128 feeFactor = math.divu(uint256(1e6 - fee), 1e6);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
            effectivePrice = math.mul(effectivePrice, feeFactor);
        }
        
        // Pool 3: toWETH
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toWETH));
            address token0 = toWETH.token0();
            address token1 = toWETH.token1();
            uint24 fee = toWETH.fee();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            int128 feeFactor = math.divu(uint256(1e6 - fee), 1e6);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
            effectivePrice = math.mul(effectivePrice, feeFactor);
        }
        
        // Convert to uint for logging (multiply by 1e18 for decimal representation)
        uint256 priceScaled = math.mulu(effectivePrice, 1e18);
        console.log("Effective price with fees (scaled by 1e18):", priceScaled);
    }

    function test_calculatePriceReverse() public view {
        address currentToken = 0x4200000000000000000000000000000000000006; // WETH

        // Start with effectivePrice = 1 (in 64.64 fixed point)
        int128 effectivePrice = math.fromUInt(1);
        
        // Route: WETH -> USDC -> Virtual -> WETH
        
        // Pool 1: toWETH (WETH -> USDC)
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toWETH));
            address token0 = toWETH.token0();
            address token1 = toWETH.token1();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
        }
        
        // Pool 2: toUSDC (USDC -> Virtual)
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toUSDC));
            address token0 = toUSDC.token0();
            address token1 = toUSDC.token1();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
        }
        
        // Pool 3: toVirtual (Virtual -> WETH)
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toVirtual));
            address token0 = toVirtual.token0();
            address token1 = toVirtual.token1();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
        }
        
        // Convert to uint for logging (multiply by 1e18 for decimal representation)
        uint256 priceScaled = math.mulu(effectivePrice, 1e18);
        console.log("Effective price reverse (scaled by 1e18):", priceScaled);
    }

    function test_calculatePriceWithFeesReverse() public view {
        address currentToken = 0x4200000000000000000000000000000000000006; // WETH

        // Start with effectivePrice = 1 (in 64.64 fixed point)
        int128 effectivePrice = math.fromUInt(1);
        
        // Route: WETH -> USDC -> Virtual -> WETH
        
        // Pool 1: toWETH (WETH -> USDC)
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toWETH));
            address token0 = toWETH.token0();
            address token1 = toWETH.token1();
            uint24 fee = toWETH.fee();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            int128 feeFactor = math.divu(uint256(1e6 - fee), 1e6);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
            effectivePrice = math.mul(effectivePrice, feeFactor);
        }
        
        // Pool 2: toUSDC (USDC -> Virtual)
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toUSDC));
            address token0 = toUSDC.token0();
            address token1 = toUSDC.token1();
            uint24 fee = toUSDC.fee();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            int128 feeFactor = math.divu(uint256(1e6 - fee), 1e6);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
            effectivePrice = math.mul(effectivePrice, feeFactor);
        }
        
        // Pool 3: toVirtual (Virtual -> WETH)
        {
            uint160 sqrtPriceX96 = getSqrtPriceX96(address(toVirtual));
            address token0 = toVirtual.token0();
            address token1 = toVirtual.token1();
            uint24 fee = toVirtual.fee();
            
            int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
            int128 price = math.mul(sqrtPrice, sqrtPrice);
            
            int128 feeFactor = math.divu(uint256(1e6 - fee), 1e6);
            
            if (currentToken == token0) {
                effectivePrice = math.mul(effectivePrice, price);
                currentToken = token1;
            } else {
                effectivePrice = math.div(effectivePrice, price);
                currentToken = token0;
            }
            effectivePrice = math.mul(effectivePrice, feeFactor);
        }
        
        // Convert to uint for logging (multiply by 1e18 for decimal representation)
        uint256 priceScaled = math.mulu(effectivePrice, 1e18);
        console.log("Effective price with fees reverse (scaled by 1e18):", priceScaled);
    }
}