// SPDX-License-Identifier: UNLICENSED
// Main on-chain arbitrage executor. Hardcodes a triangle of pools (WETH → Virtual → USDC → WETH
// on Uniswap V3 / Aerodrome CL). run() iterates triangles, picks the best pool at each leg via
// buildPath(), and checks both directions. findOptimalSizeMemory() uses a golden section search
// (20 iterations) over [0, 5 ETH] to maximize profit. If profitable, initiates a flash swap on
// the first pool; the route completes in uniswapV3SwapCallback() → runRoute(), with profit swept
// to OWNER at the end.

pragma solidity ^0.8.26;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {ABDKMath64x64 as math} from "./ABDKMath/ABDKMath64x64.sol";
import {IQuoter} from "./upgrades/IQuoter.sol";
//import {PeripheryPayments} from "@uniswap/v3-periphery/contracts/base/PeripheryPayments.sol";

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

contract Searcher is IUniswapV3SwapCallback {
    event OptimalInputFound(uint256 inputAmount, uint256 expectedProfit);

    address payable internal immutable OWNER = payable(msg.sender);
    IERC20 internal immutable WETH; // All trades will start and end with WETH

    IQuoterMathWrapper internal immutable quoterWrapper;

    address[][][] triangles;

    struct SwapCallbackData {
        address tokenReceived;
        address tokenToSend;
        bool flashSwap; // Is this the first step
        address[] path; // The rest of the path if flashSwap is true, to call runRoute()
    }

    constructor(address _WETH, address _quoterWrapper) {
        WETH = IERC20(_WETH);
        quoterWrapper = IQuoterMathWrapper(_quoterWrapper);

        // Initialize triangles in constructor
        address[2][3] memory t;
        t[0] = [0x3f0296BF652e19bca772EC3dF08b32732F93014A, 0x9c087Eb773291e50CF6c6a90ef0F4500e349B903]; // WETH -> Virtual
        t[1] = [0x529d2863a1521d0b57db028168fdE2E97120017C, 0x0000000000000000000000000000000000000000]; // Virtual -> USDC
        t[2] = [0xb4CB800910B228ED3d0834cF79D697127BBB00e5, 0xdbc6998296caA1652A810dc8D3BaF4A8294330f1]; // USDC -> WETH
        triangles.push(t);
    }

    // Helper to get sqrtPriceX96 via low-level call (works with different slot0 signatures)
    function getSqrtPriceX96(address pool) internal view returns (uint160 sqrtPriceX96) {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        require(success, "slot0 call failed");
        assembly {
            sqrtPriceX96 := mload(add(data, 32))
        }
    }

    // Helper to get pool fee via low-level call
    function getPoolFee(address pool) internal view returns (uint24 fee) {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("fee()"));
        require(success, "fee call failed");
        assembly {
            fee := mload(add(data, 32))
        }
    }

    // Calculate price for a pool, accounting for fees and token direction
    // Returns price as 64.64 fixed point: how much of the other token you get per unit of currentToken
    function getPoolPrice(address pool, address currentToken, bool applyFee)
        internal
        view
        returns (int128 price, address nextToken)
    {
        uint160 sqrtPriceX96 = getSqrtPriceX96(pool);
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        // sqrtPrice = sqrtPriceX96 / 2^96
        // price (token1/token0) = sqrtPrice^2
        int128 sqrtPrice = math.divu(uint256(sqrtPriceX96), uint256(2 ** 96));
        int128 rawPrice = math.mul(sqrtPrice, sqrtPrice);

        if (currentToken == token0) {
            // We have token0, price gives us token1 per token0
            price = rawPrice;
            nextToken = token1;
        } else {
            // We have token1, invert price to get token0 per token1
            price = math.div(math.fromUInt(1), rawPrice);
            nextToken = token0;
        }

        if (applyFee) {
            uint24 fee = getPoolFee(pool);
            int128 feeFactor = math.divu(uint256(1e6 - fee), 1e6);
            price = math.mul(price, feeFactor);
        }
    }

    // Builds a path through a triangle, choosing the best pool at each step
    // Returns the path, fees array, and total effective price
    function buildPath(uint256 triangleIndex, bool forward)
        internal
        view
        returns (address[] memory path, uint24[] memory fees, int128 totalPrice)
    {
        address[][] storage triangle = triangles[triangleIndex];
        path = new address[](3);
        fees = new uint24[](3);
        totalPrice = math.fromUInt(1);

        address currentToken = address(WETH);

        // Iterate through 3 steps
        for (uint256 step = 0; step < 3; step++) {
            uint256 stepIndex = forward ? step : (2 - step);
            address[] storage poolPair = triangle[stepIndex];

            address bestPool;
            int128 bestPrice = 0;
            address bestNextToken;
            uint24 bestFee;

            // Check both pools (index 0 = Uniswap, index 1 = Aerodrome)
            for (uint256 p = 0; p < 2; p++) {
                address pool = poolPair[p];
                if (pool == address(0)) continue;

                // Check if this pool contains our current token
                address token0 = IUniswapV3Pool(pool).token0();
                address token1 = IUniswapV3Pool(pool).token1();
                if (currentToken != token0 && currentToken != token1) continue;

                (int128 price, address nextToken) = getPoolPrice(pool, currentToken, true);

                // Choose the pool with the better (higher) price
                if (bestPool == address(0) || price > bestPrice) {
                    bestPool = pool;
                    bestPrice = price;
                    bestNextToken = nextToken;
                    bestFee = getPoolFee(pool);
                }
            }

            require(bestPool != address(0), "No valid pool found for step");

            path[step] = bestPool;
            fees[step] = bestFee;
            totalPrice = math.mul(totalPrice, bestPrice);
            currentToken = bestNextToken;
        }
    }

    // After we get the optimal sizing, make a WETH exact input flash swap with that size and pass
    // the rest of the path to the callback
    function run() public {
        require(msg.sender == OWNER, "Only owner can run");
        int128 ONE = math.fromUInt(1);

        for (uint256 t = 0; t < triangles.length; t++) {
            // Try forward direction first
            (address[] memory path, uint24[] memory fees, int128 totalPrice) = buildPath(t, true);

            bool profitable = totalPrice > ONE;
            bool forward = true;

            // If forward isn't profitable, try reverse
            if (!profitable) {
                (path, fees, totalPrice) = buildPath(t, false);
                profitable = totalPrice > ONE;
                forward = false;
            }

            if (profitable) {
                // Find optimal size
                (uint256 optimalInput, uint256 expectedProfit) = findOptimalSizeMemory(path, fees);
                emit OptimalInputFound(optimalInput, expectedProfit);

                if (optimalInput > 0 && expectedProfit > 0) {
                    // Execute flash swap on first pool
                    address firstPool = path[0];
                    address token0 = IUniswapV3Pool(firstPool).token0();
                    address token1 = IUniswapV3Pool(firstPool).token1();
                    address wethAddr = address(WETH);

                    bool zeroForOne = (wethAddr == token0);
                    address tokenReceived = zeroForOne ? token1 : token0;

                    // Build remaining path (everything after first pool)
                    address[] memory remainingPath = new address[](path.length - 1);
                    for (uint256 i = 1; i < path.length; i++) {
                        remainingPath[i - 1] = path[i];
                    }

                    // Uniswap V3 sqrt price limits
                    uint160 MIN_SQRT_RATIO = 4295128739;
                    uint160 MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

                    IUniswapV3Pool(firstPool)
                        .swap(
                            address(this),
                            zeroForOne,
                            int256(optimalInput),
                            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
                            abi.encode(
                                SwapCallbackData({
                                    tokenReceived: tokenReceived,
                                    tokenToSend: wethAddr,
                                    flashSwap: true,
                                    path: remainingPath
                                })
                            )
                        );
                }
            }
        }
    }

    // Performs a golden section search (15 iterations) to find a close-to-optimal trade size
    // Uses the quoterWrapper to simulate outputs through the entire path
    // Uses ABDKMath64x64 for safe fixed-point arithmetic
    function findOptimalSizeMemory(address[] memory _path, uint24[] memory _fees)
        internal
        view
        returns (uint256 input, uint256 profit)
    {
        // Golden ratio inverse: 1/phi ≈ 0.618033988749895
        // In 64.64 fixed point format: 0.618... * 2^64 ≈ 11400714819323198485
        int128 INV_PHI = 11400714819323198485;
        int128 ONE_MINUS_INV_PHI = math.sub(math.fromUInt(1), INV_PHI);

        // Bounds: [0, 1 WETH]
        uint256 a = 0;
        uint256 b = 5 ether;

        // Calculate interior points using ABDKMath64x64
        // c = a + (1 - 1/phi) * (b - a)
        // d = a + (1/phi) * (b - a)
        uint256 c = a + math.mulu(ONE_MINUS_INV_PHI, b - a);
        uint256 d = a + math.mulu(INV_PHI, b - a);

        // Calculate profits at c and d
        // Profit at a (0 WETH input) is 0 by definition
        int256 profitC = _calculatePathProfitMemory(_path, _fees, c);
        int256 profitD = _calculatePathProfitMemory(_path, _fees, d);

        // Perform 20 iterations of golden section search
        for (uint8 i = 0; i < 20; i++) {
            if (profitC < profitD) {
                // Maximum is in [c, b], so move a up to c
                a = c;
                c = d;
                profitC = profitD;
                d = a + math.mulu(INV_PHI, b - a);
                profitD = _calculatePathProfitMemory(_path, _fees, d);
            } else {
                // Maximum is in [a, d], so move b down to d
                b = d;
                d = c;
                profitD = profitC;
                c = a + math.mulu(ONE_MINUS_INV_PHI, b - a);
                profitC = _calculatePathProfitMemory(_path, _fees, c);
            }
        }

        // Return the lower bound of the final interval
        input = a;
        if (a == 0) {
            profit = 0;
        } else {
            int256 profitA = _calculatePathProfitMemory(_path, _fees, a);
            profit = profitA > 0 ? uint256(profitA) : 0;
        }
    }

    // Calculates profit for a given WETH input through the entire path
    // Path starts and ends with WETH, contains pool addresses
    function _calculatePathProfitMemory(address[] memory _path, uint24[] memory _fees, uint256 _input)
        internal
        view
        returns (int256)
    {
        if (_input == 0) return 0;

        address WETH_ADDR = address(WETH);
        uint256 currentAmount = _input;
        address currentToken = WETH_ADDR;

        // Uniswap V3 sqrt price limits
        uint160 MIN_SQRT_RATIO = 4295128739;
        uint160 MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

        for (uint256 i = 0; i < _path.length; i++) {
            IUniswapV3Pool pool = IUniswapV3Pool(_path[i]);
            address token0 = pool.token0();
            address token1 = pool.token1();

            bool zeroForOne = (currentToken == token0);

            IQuoterMathWrapper.QuoteParams memory params = IQuoterMathWrapper.QuoteParams({
                zeroForOne: zeroForOne,
                exactInput: true,
                fee: _fees[i],
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
            });

            (int256 amount0, int256 amount1,,) = quoterWrapper.quote(pool, int256(currentAmount), params);

            // For exact input:
            // If zeroForOne: amount0 > 0 (input), amount1 < 0 (output)
            // If oneForZero: amount1 > 0 (input), amount0 < 0 (output)
            if (zeroForOne) {
                currentAmount = uint256(-amount1);
                currentToken = token1;
            } else {
                currentAmount = uint256(-amount0);
                currentToken = token0;
            }
        }

        // Profit = final output - initial input (both in WETH)
        return int256(currentAmount) - int256(_input);
    }

    // Runs the route given. Assume that there is already a balance of tokenToSell, we will call a flash swap
    // for this balance in run().
    // Path: array of UniswapV3 pool addresses. It is actually not the entire path, we "skipped"
    // the first swap with a flash swap, getting the first output as tokenToSell.
    // Size: balance of first token to spend
    function runRoute(address[] memory _path, address _tokenToSell, uint256 _size) internal {
        // Uniswap V3 sqrt price limits
        uint160 MIN_SQRT_RATIO = 4295128739;
        uint160 MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

        for (uint8 i; i < _path.length; i++) {
            // token0 and token1 are public variables on the pool.
            IUniswapV3Pool pool = IUniswapV3Pool(_path[i]);

            address token0 = pool.token0();
            if (token0 == _tokenToSell) {
                address tokenReceived = pool.token1();
                address tokenSent = token0;
                // Zero for one

                (, int256 newSize) = pool.swap(
                    address(this), //recepient
                    true, // zeroForOne
                    int256(_size), // amountSpecified, exact input
                    MIN_SQRT_RATIO + 1, // price limit, cannot go below this
                    abi.encode(
                        SwapCallbackData({
                            tokenReceived: tokenReceived,
                            tokenToSend: tokenSent,
                            flashSwap: false,
                            path: new address[](0)
                        })
                    )
                );
                _tokenToSell = tokenReceived;
                _size = uint256(-newSize);
            } else {
                address tokenReceived = token0;
                address tokenSent = pool.token1();
                // One for zero
                (int256 newSize,) = pool.swap(
                    address(this), //recepient
                    false, // zeroForOne
                    int256(_size), // amountSpecified, exact input
                    MAX_SQRT_RATIO - 1, // price limit, cannot go above this
                    abi.encode(
                        SwapCallbackData({
                            tokenReceived: tokenReceived,
                            tokenToSend: tokenSent,
                            flashSwap: false,
                            path: new address[](0)
                        })
                    )
                );
                _tokenToSell = tokenReceived;
                _size = uint256(-newSize);
            }
        }
    }

    // Amounts: negative means it was sent to this contract, positive means it must be sent to the pool.
    // Data: send just the token owed's address. We have the pool addr (msg.sender)
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Verify the callback using the poolkey and then pay the token owed.
        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));
        // TODO: Pay the token owed to the pool
        int256 amountOwed;
        int256 firstBalance;

        if (amount0Delta > 0) {
            amountOwed = amount0Delta;
            firstBalance = amount1Delta;
        } else {
            amountOwed = amount1Delta;
            firstBalance = amount0Delta;
        }

        if (decoded.flashSwap) {
            // route must end in tokenToSend
            // firstBalance is negative (tokens received), so negate it
            runRoute(decoded.path, decoded.tokenReceived, uint256(-firstBalance));
        }

        IERC20(decoded.tokenToSend).transfer(msg.sender, uint256(amountOwed));

        if (decoded.flashSwap) {
            // transfer leftover profit to owner
            uint256 balance = IERC20(decoded.tokenToSend).balanceOf(address(this));
            IERC20(decoded.tokenToSend).transfer(OWNER, balance);
        }
    }

    receive() external payable {}

    function withdraw() public {
        (bool success,) = OWNER.call{value: address(this).balance}("");
        require(success, "Withdrawal failed");
    }
}
