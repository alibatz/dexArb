// Thin contract wrapper around QuoterMath so it can be called via interface from Searcher.
// Bridges the ^0.7.6 (QuoterMath) / ^0.8.26 (Searcher) Solidity version boundary.
pragma solidity ^0.7.6;
pragma abicoder v2;

import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {QuoterMath} from "./QuoterMath.sol";

contract QuoterMathWrapper {
    function quote(IUniswapV3Pool pool, int256 amount, QuoterMath.QuoteParams memory params)
        external
        view
        returns (int256 amount0, int256 amount1, uint160 sqrtPriceAfterX96, uint32 initializedTicksCrossed)
    {
        return QuoterMath.quote(pool, amount, params);
    }
}
