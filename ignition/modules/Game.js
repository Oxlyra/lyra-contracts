const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const { constructorArgs } = require("../../config");

const DEV_WALLET = constructorArgs.devWallet;
const OWNER_ADDRESS = constructorArgs.owner;
const SETTINGS = [
	constructorArgs.gameSettings.queryFee,
	constructorArgs.gameSettings.queryFeeIncrement,
	constructorArgs.gameSettings.maxQueryFee,
	constructorArgs.gameSettings.gameDuration,
	constructorArgs.gameSettings.gameStartTime,
	constructorArgs.gameSettings.pricePoolPercentage,
	constructorArgs.gameSettings.devWalletPercentage,
];

const DEPLOYMENT_ARGS = [OWNER_ADDRESS, DEV_WALLET, SETTINGS];

module.exports = buildModule("Game", (m) => {
	const game = m.contract("Game", DEPLOYMENT_ARGS);

	return { game };
});
