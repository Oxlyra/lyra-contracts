const { Web3 } = require("web3");
const { networks, accounts, wallets, gameAddress, constructorArgs } = require("../config");
const { expect } = require("chai");

const web3 = new Web3(networks.arbitrumSepolia.url);

web3.handleRevert = true;

const errorSignatures = {
	AmountLessThanQueryFee: "AmountLessThanQueryFee()",
	AmountLessThanQueryFeePlusSlippage: "AmountLessThanQueryFeePlusSlippage()",
	GameHasNotStarted: "GameHasNotStarted()",
	GameHasEnded: "GameHasEnded()",
	FailedToSendEthers: "FailedToSendEthers()",
	AIRequestDoesNotExist: "AIRequestDoesNotExist()",
	PlayerQueryDoesNotExist: "PlayerQueryDoesNotExist()",
	WinnerRewardConditionsNotMet: "WinnerRewardConditionsNotMet()",
	WinnerAlreadyExists: "WinnerAlreadyExists()",
	NotAParticipant: "NotAParticipant()",
	GameIsInProgress: "GameIsInProgress()",
	AlreadyRefunded: "AlreadyRefunded()",
	UnableToProcessRefund: "UnableToProcessRefund()",
	UnsupportedModel: "UnsupportedModel()",
};

Object.values(errorSignatures).forEach((v) => [console.log(v, web3.eth.abi.encodeFunctionSignature(v))]);

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
	const modelId = 11;

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

		console.log("\n------------------ GAME SETTINGS -------------");

		const gameSettings = await game.methods.gameSettings().call();

		console.table(gameSettings);
	});

	// it("should have a name", async function () {
	// 	const name = await game.methods.name().call();

	// 	console.log("Game name: ", name);

	// 	expect(name).to.be.a("string");
	// });

	it("can estimate callback gas cost", async function () {
		const gas = await game.methods.getGasEstimate(modelId).call();

		const normalizedGas = +BigInt(gas).toString();

		console.log("Callback Gas Cost: ", normalizedGas);

		expect(normalizedGas).to.be.a("number");

		expect(normalizedGas).to.be.greaterThan(0);
	});

	it("can play ", async function () {
		try {
			const gas = await game.methods.getGasEstimate(modelId).call();

			const normalizedGas = +BigInt(gas).toString();

			const payableAmount = normalizedGas + constructorArgs.gameSettings.queryFee;
			const message = "Hello!";

			console.log("Payable Amount: ", payableAmount);

			// simulate tx with gas estimation

			const estimatedGas = await game.methods.play(message, modelId).estimateGas({
				from: wallets[0],
				value: payableAmount,
			});

			console.log("Estimated Gas: ", estimatedGas);

			const tx = await game.methods.play(message, modelId).send({
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
