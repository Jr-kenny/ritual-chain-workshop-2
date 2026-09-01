import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";

describe("RitualPredict - BTC-adjusted rain market", async function () {
  const { viem } = await network.connect();
  
  it("creates rain market with BTC oracle and bets", async () => {
    const predict = await viem.deployContract("RitualPredict", [200n]);
    const creationBtc = 100000n; // 100k
    await predict.write.createMarket([{
      question: "Will it rain in China? (mm > 10)",
      oracleUrl: "https://api.weather.example/rain?city=beijing",
      jsonPath: ".rain_mm",
      target: 10n,
      comparator: 1, // GTE
      bettingSeconds: 30n,
      resolveDelaySeconds: 30n,
      btcOracleUrl: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
      btcJsonPath: ".bitcoin.usd",
      btcPriceAtCreation: creationBtc,
    }]);
    const m = await predict.read.getMarket([0n]);
    assert.equal(m.question, "Will it rain in China? (mm > 10)");
    assert.equal(m.btcPriceAtCreation, creationBtc);
    
    await predict.write.bet([0n, true], { value: 100n });
    const m2 = await predict.read.getMarket([0n]);
    assert.equal(m2.totalYes, 100n);
  });

  it("BTC-adjusted payout: 100 stake -> 200 base -> 160 when BTC 100k->80k", async () => {
    const predict = await viem.deployContract("RitualPredict", [200n]);
    await predict.write.createMarket([{
      question: "Will it rain in China?",
      oracleUrl: "https://oracle.example/rain",
      jsonPath: ".value",
      target: 10n,
      comparator: 1,
      bettingSeconds: 30n,
      resolveDelaySeconds: 15n,
      btcOracleUrl: "https://api.coingecko.com/api/v3/simple/price",
      btcJsonPath: ".bitcoin.usd",
      btcPriceAtCreation: 100000n,
    }]);
    await predict.write.bet([0n, true], { value: 100n });
    const clients = await viem.getWalletClients();
    const bob = clients[1] ?? clients[0];
    const predictAsBob = await viem.getContractAt("RitualPredict", predict.address, { client: { wallet: bob } } as any);
    try { await predictAsBob.write.bet([0n, false], { value: 100n }); } catch { await predict.write.bet([0n, false], { value: 100n }); }

    await predict.write.__setMockObserved([0n, 15n]);
    await predict.write.__setMockBtcPrice([0n, 80000n]);

    const pub = await viem.getPublicClient();
    const mBefore = await predict.read.getMarket([0n]);
    const toMine = Number(mBefore.resolveBlock - await pub.getBlockNumber() + 1n);
    for (let i=0;i<toMine;i++) await pub.request({ method: "hardhat_mine", params: ["0x1"] } as any);

    await predict.write.onScheduledResolve([0n, 0n]);
    const m = await predict.read.getMarket([0n]);
    assert.equal(m.state, 3); // Resolved
    assert.equal(m.btcPriceAtResolve, 80000n);
  });

  it("without BTC oracle, payout is unadjusted", async () => {
    const predict = await viem.deployContract("RitualPredict", [200n]);
    await predict.write.createMarket([{
      question: "Q?",
      oracleUrl: "https://o.example",
      jsonPath: ".v",
      target: 5n,
      comparator: 1,
      bettingSeconds: 30n,
      resolveDelaySeconds: 15n,
      btcOracleUrl: "",
      btcJsonPath: "",
      btcPriceAtCreation: 0n,
    }]);
    await predict.write.bet([0n, true], { value: 100n });
    await predict.write.bet([0n, false], { value: 100n });
    await predict.write.__setMockObserved([0n, 10n]);
    const pub = await viem.getPublicClient();
    const mBefore = await predict.read.getMarket([0n]);
    const toMine = Number(mBefore.resolveBlock - await pub.getBlockNumber() + 1n);
    for (let i=0;i<toMine;i++) await pub.request({ method: "hardhat_mine", params: ["0x1"] } as any);
    await predict.write.onScheduledResolve([0n, 0n]);
    const m = await predict.read.getMarket([0n]);
    assert.equal(m.state, 3);
  });
});
