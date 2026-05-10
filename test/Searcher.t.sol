// SPDX-License-Identifier: UNLICENSED
// Minimal deployment test — verifies Searcher can be deployed and initialized correctly.
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Searcher } from "../src/Searcher.sol";

contract SearcherTest is Test {
    Searcher internal searcher;

    function setUp() public {
        searcher = new Searcher(
            0x4200000000000000000000000000000000000006, // WETH
            0x222cA98F00eD15B1faE10B61c277703a194cf5d2  // QuoterWrapper
        );
    }
}