const { ethers } = require("hardhat");

async function main() {
  // Replace with deployed contract addresses
  const gaslessRelayerAddress = "0xYourGaslessRelayerAddress";
  const gameContractAddress = "0xYourGameContractAddress";

  // Example: 500 requests
  const matchIds = Array.from({ length: 500 }, (_, i) => i + 1);
  const recipients = matchIds.map(i => {
    // Replace with actual recipient addresses
    return "0x1111111111111111111111111111111111111111";
  });

  // Get signer (must be contract owner)
  const [owner] = await ethers.getSigners();

  // Attach to GaslessRelayer contract
  const GaslessRelayer = await ethers.getContractFactory("GaslessRelayer");
  const relayer = GaslessRelayer.attach(gaslessRelayerAddress);

  // Batch size (adjust based on gas limits)
  const batchSize = 50;

  for (let i = 0; i < matchIds.length; i += batchSize) {
    const batchMatchIds = matchIds.slice(i, i + batchSize);
    const batchRecipients = recipients.slice(i, i + batchSize);

    console.log(`Processing batch ${i / batchSize + 1} with ${batchMatchIds.length} requests...`);

    try {
      const tx = await relayer.connect(owner).executeBatchWithdrawals(
        gameContractAddress,
        batchMatchIds,
        batchRecipients
      );

      console.log("Transaction submitted:", tx.hash);
      const receipt = await tx.wait();
      console.log("Batch executed in block:", receipt.blockNumber);
    } catch (error) {
      console.error("Batch failed:", error);
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
