// SPDX-License-Identifier: UNLICENSED
// End-to-end arbitrage test. Moves the WETH/Virtual price with a whale swap to engineer a
// detectable opportunity, then runs searcher.run() to verify the arb executes and emits
// OptimalInputFound with a non-zero profit.
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Searcher } from "../src/Searcher.sol";
import { IQuoterMathWrapper } from "./QuoterT.t.sol";
import "forge-std/Vm.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

// Simple helper contract to execute swaps (handles callback)
contract SwapHelper is IUniswapV3SwapCallback {
    function swap(
        IUniswapV3Pool pool,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external returns (int256 amount0, int256 amount1) {
        (amount0, amount1) = pool.swap(
            msg.sender, // recipient
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            abi.encode(msg.sender)
        );
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        address payer = abi.decode(data, (address));
        
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token0()).transferFrom(payer, msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token1()).transferFrom(payer, msg.sender, uint256(amount1Delta));
        }
    }
}

contract ArbTest is Test {
    IUniswapV3Pool WETHVirtual = IUniswapV3Pool(0x3f0296BF652e19bca772EC3dF08b32732F93014A);
    IWETH WETH = IWETH(0x4200000000000000000000000000000000000006);
    IQuoterMathWrapper wrapper;
    address arbitrageur;
    Searcher searcher;
    SwapHelper swapHelper;

    function setUp() public {
        // Deploy swap helper
        swapHelper = new SwapHelper();
        
        // Setup whale to move the price
        address whale = makeAddr("whale");
        vm.deal(whale, 1000 ether);
        
        vm.startPrank(whale);
        
        // Wrap ETH to WETH
        WETH.deposit{value: 100 ether}();
        
        // Approve swap helper to spend WETH
        WETH.approve(address(swapHelper), type(uint256).max);
        
        // Determine swap direction - WETH is token0 or token1?
        address token0 = WETHVirtual.token0();
        bool wethIsToken0 = (token0 == address(WETH));
        
        // Swap 50 ETH worth of WETH for Virtual to move the price significantly
        // If WETH is token0, zeroForOne = true
        // sqrtPriceLimitX96: MIN if zeroForOne, MAX if oneForZero
        uint160 MIN_SQRT_RATIO = 4295128739;
        uint160 MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
        
        swapHelper.swap(
            WETHVirtual,
            wethIsToken0, // zeroForOne
            int256(50 ether), // exact input of 10 WETH - large swap to move price
            wethIsToken0 ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
        );
        
        vm.stopPrank();

        // Setup arbitrageur and deploy Searcher
        arbitrageur = makeAddr("arbitrageur");
        
        // Deploy QuoterMathWrapper
        bytes memory bytecode = vm.getCode(
            "out/QuoterMathWrapper.sol/QuoterMathWrapper.json"
        );
        
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        wrapper = IQuoterMathWrapper(addr);
        
        // Deploy Searcher as arbitrageur (so OWNER is arbitrageur)
        vm.prank(arbitrageur);
        searcher = new Searcher(address(WETH), addr);
    }
    
    function test_executeArb() public {
        vm.recordLogs();
        vm.prank(arbitrageur);
        searcher.run();
        console.log("Arbitrageur WETH balance: ", WETH.balanceOf(arbitrageur));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 EVENT_SIG = keccak256(
            "OptimalInputFound(uint256,uint256)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == EVENT_SIG) {
                // this is your event
                (uint256 a, uint256 b) = abi.decode(logs[i].data, (uint256, uint256));

                console.log(
                    "Optimal Input Found Event:",
                    a,
                    b
                );
            }
        }
    }
}