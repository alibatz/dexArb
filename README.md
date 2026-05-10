# dexArb

On-chain triangular arbitrage bot targeting Base mainnet, implemented entirely in Solidity and run via Foundry. Trades start and end in WETH, routing through a triangle of pools across Uniswap V3 and Aerodrome CL.

## How it works

### 1. Opportunity detection — `buildPath()`

`Searcher.buildPath()` evaluates a triangle of token pairs (e.g. WETH → Virtual → USDC → WETH). At each leg it picks the best available pool from a pair of candidates (one Uniswap V3, one Aerodrome CL) by comparing their effective exchange rates after fees, using 64.64 fixed-point arithmetic (`ABDKMath64x64`). It multiplies the per-leg rates into a single composite price for the whole triangle. If that composite exceeds 1.0 — meaning you end up with more WETH than you started with — the direction is profitable. Both forward and reverse directions are checked.

### 2. Optimal sizing — `findOptimalSizeMemory()`

Profit is not linear in trade size: too small and fees dominate, too large and price impact erodes the edge. `findOptimalSizeMemory()` finds the sweet spot using **golden section search** over the interval `[0, 5 ETH]`, running 20 iterations to converge on a near-optimal input amount. Each candidate size is evaluated by `_calculatePathProfitMemory()`, which calls `QuoterMathWrapper.quote()` at each hop to simulate the exact output — accounting for tick-level price impact and fees — and returns `output - input` as the profit.

### 3. Execution — flash swap + `runRoute()`

Once a profitable size is found, `run()` initiates a **flash swap** on the first pool: the pool sends the output tokens to the contract without requiring upfront payment. The `uniswapV3SwapCallback()` receives those tokens and calls `runRoute()`, which walks the remaining legs of the path, each time swapping the received tokens for the next token in the triangle. After the final swap, the callback repays the first pool in WETH and sweeps any remaining profit to the owner.

```
run()
 └─ pool[0].swap()          ← flash swap, no upfront capital needed
      └─ uniswapV3SwapCallback()
           ├─ runRoute()    ← executes legs 1..N
           ├─ repay pool[0] in WETH
           └─ sweep profit → OWNER
```

## Pool quoter — `QuoterMath.sol`

`QuoterMath` is a local re-implementation of the Uniswap V3 swap simulation loop that runs as a `view` call, avoiding the gas overhead of external quoter contracts. It is adapted from `lib/view-quoter-v3` to also quote **Aerodrome CL** pools, which differ from Uniswap V3 in two places:

- `slot0()` returns 6 values instead of 7.
- `ticks()` returns 10 values instead of 8.

The adaptation uses low-level `staticcall` for both functions and reads only the fields it needs (`sqrtPriceX96`, `tick`, `tickSpacing`, `liquidityNet`) by index from the raw ABI-encoded response, making the library compatible with both pool types without separate interfaces.

`QuoterMathWrapper` is a thin `^0.7.6` contract that exposes `QuoterMath` over an interface, bridging the Solidity version boundary between the math library (`^0.7.6`) and the main searcher (`^0.8.26`).

## Project layout

```
src/
  Searcher.sol          — main arbitrage contract
  QuoterMath.sol        — adapted view quoter (Uniswap V3 + Aerodrome CL)
  QuoterMathWrapper.sol — version-bridge wrapper for QuoterMath
test/
  Arb.t.sol             — end-to-end arbitrage tests (Base mainnet fork)
  Price.t.sol           — price calculation tests
  QuoterT.t.sol         — quoter accuracy tests
  Searcher.t.sol        — searcher unit tests
lib/
  v3-core               — Uniswap V3 core math (SwapMath, TickMath, …)
  v3-periphery          — Uniswap V3 periphery (Path, PoolAddress)
  view-quoter-v3        — upstream reference quoter (basis for QuoterMath)
  slipstream            — Aerodrome CL pool interfaces
  abdk-libraries-solidity — 64.64 fixed-point arithmetic
  openzeppelin-contracts  — IERC20
  forge-std             — Foundry test utilities
```

## Setup

```bash
# 1. Copy and fill in your RPC URL
cp .env.example .env
# BASE_RPC_URL=https://...

# 2. Install dependencies
forge install

# 3. Build
forge build

# 4. Run tests (forks Base mainnet)
forge test -vvv
```

Tests require a live Base mainnet RPC endpoint. The `foundry.toml` maps `BASE_RPC_URL` to the `base` RPC alias used in fork tests.
