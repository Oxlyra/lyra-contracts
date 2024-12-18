const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");
const { constructorArgs } = require("../config");

const DEV_WALLET = constructorArgs.devWallet;
const OWNER_ADDRESS = constructorArgs.owner;
const AI_ORACLE_ADDRESS = constructorArgs.aiOracleAddress;
const SETTINGS = [
	constructorArgs.gameSettings.queryFee,
	constructorArgs.gameSettings.queryFeeIncrement,
	constructorArgs.gameSettings.maxQueryFee,
	constructorArgs.gameSettings.gameDuration,
	constructorArgs.gameSettings.gameStartTime,
	constructorArgs.gameSettings.pricePoolPercentage,
	constructorArgs.gameSettings.devWalletPercentage,
];

const DEPLOYMENT_ARGS = [DEV_WALLET, OWNER_ADDRESS, SETTINGS, AI_ORACLE_ADDRESS];

module.exports = buildModule("Game", (m) => {
	const game = m.contract("Game", DEPLOYMENT_ARGS);

	return { game };
});
