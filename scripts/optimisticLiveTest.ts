import { ethers } from "hardhat";
import { getSub } from "../test/helpers";

const fe = (n:number) => ethers.parseUnits(n.toFixed(5), 18)

async function main() {
  const signer = new ethers.Wallet(process.env.PRIVATEKEY!, new ethers.JsonRpcProvider("https://rpc.ankr.com/optimism"))
  const contract = await ethers.deployContract("OptimisticSubs", 
    [8*24*60*60, "0x85c6Cd5fC71AF35e6941d7b53564AC0A68E09f5C", signer.address, 1694919024]);

  await contract.waitForDeployment();

  console.log(
    `deployed to ${contract.target}`
  );

  const token = new ethers.Contract("0xda10009cbd5d07dd0cecc66161fc93d7c9000da1", [
    "function approve(address spender, uint256 amount) external returns (bool)",
  ], signer)
  await (await token.approve(contract.target, fe(1))).wait()
  await contract.subscribe(signer.address, fe(0.1), 2)
  const sub = await getSub(contract.subscribe(signer.address, fe(0.15), 2), "0x4eea731ae1fda3da326d839452cf98ef0b814e2e0c09bc8122100e44c4f0649b")

  await contract.unsubscribe(sub.subId)
  console.log("unsubcribed")
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});