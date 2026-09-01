# Deployment — RitualPredict (local EDR, chain down)

> Ritual Chain testnet is currently down per workshop README — local Hardhat EDR counts for verification (`With the chain down, local work counts: compiling, running it against a local Hardhat node, writing tests, extending the contract, or building a frontend.`)

## Hardhat local deploy (reproducible)

```bash
# in hardhat/
npx hardhat compile
npx hardhat run scripts/deploy_local.ts --network hardhatMainnet
```

`scripts/deploy_local.ts` deploys via `wallet.deployContract` from the compiled artifact so the tx hash is captured (hardhat-viem helper hides it), creates the China-rain market with BTC oracle, and places a bet.

## Result — 2026-09-01 local EDR

- **Network:** `hardhatMainnet` (EDR simulated, chainType l1) — local
- **Deployer (Hardhat default):** `0xf39Fd6e51aad88F6f4ce6ab8827279cfffb92266`
- **Contract:** `RitualPredict`
- **Address:** `0x5FbDB2315678afecb367f032d93F642f64180aa3`
- **Deployment tx hash:** `0x5ac932d7c3e9a808ec9a88ad13e4137b7eb62226d9dff8131af97debce6a3937`
- **Block:** `1` — `gasUsed 3091537` — status `success`
- **Bytecode verified:** `artifacts/contracts/RitualPredict.sol/RitualPredict.json` (solc 0.8.28, optimizer 200)

### Market created in same run (proves BTC extension)

- **createMarket tx:** `0xbbc436a8babf97de7803a67cc1dbde14f37d0187113f27ac51cad8e9519e1af5` — block 2, success
- **Question:** `Will it rain in China? (mm > 10)` — oracle `https://api.weather.example/rain?city=beijing` jq `.rain_mm` target 10 GTE
- **BTC oracle:** `https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd` jq `.bitcoin.usd` — `btcPriceAtCreation: 100000` stored
- **Market:** `closeBlock 155` `resolveBlock 308` (30s + 30s via `_secondsToBlocks`)
- **Bet tx:** `0x686097d7476f3ad66e593018048f3d06c75cbc3693214e59b84ce213a2c53421` — 0.1 RITUAL on YES

Same address is deterministic (first deploy from `0xf39…` nonce 0). Redeploy on Ritual Chain 1979 when up uses identical bytecode — only RPC changes.

## Verification

```bash
npx hardhat test --network hardhatMainnet
# 3 passing: creates rain market + bets, BTC-adjusted 100→200→160 when BTC 100k→80k, unadjusted without oracle
```

Fork: `Jr-kenny/ritual-chain-workshop-2` (public, fork lineage `cozfuttu/ritual-chain-workshop-2`, default name kept) — 5 commits, `web/index.html` harbor-at-dusk panel reuses bluepot tokens.

