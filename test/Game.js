const { Web3 } = require("web3");
const { networks, accounts, wallets, gameAddress, constructorArgs } = require("../config");
const { expect } = require("chai");

const web3 = new Web3(networks.bscTestnet.url);

web3.handleRevert = true;

const errorSignatures = {
	InsufficientQueryFee: "InsufficientQueryFee()",
	InsufficientQueryFeeWithSlippage: "InsufficientQueryFeeWithSlippage()",
	GameNotStarted: "GameNotStarted()",
	GameEnded: "GameEnded()",
	EtherTransferFailed: "EtherTransferFailed()",
	PlayerAttemptNotFound: "PlayerAttemptNotFound()",
	WinnerRewardConditionsNotMet: "WinnerRewardConditionsNotMet()",
	WinnerAlreadyDeclared: "WinnerAlreadyDeclared()",
	NotAPlayer: "NotAPlayer()",
	GameInProgress: "GameInProgress()",
	AlreadyRefunded: "AlreadyRefunded()",
	RefundProcessingFailed: "RefundProcessingFailed()",
	RequestIDExists: "RequestIDExists()",
};

// Object.values(errorSignatures).forEach((v) => [console.log(v, web3.eth.abi.encodeFunctionSignature(v))]);

function getErrorName(data) {
	if (!data) return null;

	const errorSignature = data.slice(0, 10); // Get the first 4 bytes (10 hex characters)
	for (const [name, signature] of Object.entries(errorSignatures)) {
		const encodedSignature = web3.eth.abi.encodeFunctionSignature(signature);
		if (encodedSignature === errorSignature) {
			return name;
		}
	}
	return null;
}

describe("Game", () => {
	let game;

	before(async function () {
		// load wallet with accounts
		accounts.forEach((key) => {
			if (!key.startsWith("0x")) {
				key = "0x" + key;
			}

			web3.eth.accounts.wallet.add(key);
		});

		// load contract artifacts

		const gameArtifact = require("../artifacts/contracts/Game.sol/Game.json");

		game = new web3.eth.Contract(gameArtifact.abi, gameAddress);

		console.log("\n------------------ GAME CONFIG -------------");

		const gameSettings = await game.methods.gameConfig().call();

		console.table(gameSettings);
	});

	it("should have a name", async function () {
		const name = await game.methods.name().call();

		console.log("Game Name: ", name);

		expect(name).to.be.a("string");
	});

	it("can play ", async function () {
		try {
			const payableAmount = constructorArgs.gameSettings.queryFee;

			// simulate tx with gas estimation

			const requestId = Math.round(Math.random() * 10000000000);
			const msg = "Testing Lyra 1-2!";

			// console.log(requestId);

			const estimatedGas = await game.methods.play(requestId, msg).estimateGas({
				from: wallets[0],
				value: payableAmount,
			});

			console.log("Estimated Gas: ", estimatedGas);

			const tx = await game.methods.play(requestId, msg).send({
				from: wallets[0],
				value: payableAmount,
				gas: estimatedGas,
			});

			console.log("Transaction: ", tx);
		} catch (e) {
			console.log("Decoded Error: ", getErrorName(e?.cause?.data));

			console.log(e);
		}
	});
});
