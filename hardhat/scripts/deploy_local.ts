import { network } from "hardhat";
import fs from "node:fs";
async function main(){
  const { viem } = await network.connect("hardhatMainnet");
  const publicClient = await viem.getPublicClient();
  const [wallet] = await viem.getWalletClients();
  console.log("deployer", wallet.account.address);
  // read artifact for direct wallet deploy so we get tx hash
  const artifact = JSON.parse(fs.readFileSync("artifacts/contracts/RitualPredict.sol/RitualPredict.json","utf8"));
  const hash = await wallet.deployContract({
    abi: artifact.abi,
    bytecode: artifact.bytecode as `0x${string}`,
    args: [195n],
  });
  console.log("deploy txHash", hash);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log("receipt status", receipt.status, "contractAddress", receipt.contractAddress);
  console.log("block", receipt.blockNumber.toString(), "gasUsed", receipt.gasUsed.toString());
  // attach instance for market creation
  const predict = await viem.getContractAt("RitualPredict", receipt.contractAddress as `0x${string}`);
  const btcOracleUrl = "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd";
  const tx = await predict.write.createMarket([{
    question: "Will it rain in China? (mm > 10)",
    oracleUrl: "https://api.weather.example/rain?city=beijing",
    jsonPath: ".rain_mm",
    target: 10n,
    comparator: 1,
    bettingSeconds: 30n,
    resolveDelaySeconds: 30n,
    btcOracleUrl,
    btcJsonPath: ".bitcoin.usd",
    btcPriceAtCreation: 100000n,
  }]);
  console.log("createMarket tx", tx);
  const r2 = await publicClient.waitForTransactionReceipt({ hash: tx });
  console.log("createMarket block", r2.blockNumber.toString(), "status", r2.status);
  const m: any = await predict.read.getMarket([0n]);
  console.log("market btcPriceAtCreation", String(m.btcPriceAtCreation ?? m[11]));
  console.log("market closeBlock", String(m.closeBlock ?? m[6]));
  console.log("market resolveBlock", String(m.resolveBlock ?? m[7]));
  // also bet to prove payout flow
  const betTx = await predict.write.bet([0n, true], { value: 100000000000000000n });
  console.log("bet tx", betTx);
  await publicClient.waitForTransactionReceipt({ hash: betTx });
  console.log("bet ok");
}
main().catch(e=>{console.error(e); process.exit(1)});
