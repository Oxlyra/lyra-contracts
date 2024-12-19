require("@nomicfoundation/hardhat-toolbox");

const { signerAddress, signerKey, networks, etherscan } = require("./config");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
	solidity: {
		version: "0.8.21",

		settings: {
			optimizer: {
				enabled: true,
				runs: 1000,
			},

			evmVersion: "paris",
		},

		viaIR: true,
	},

	etherscan,
	networks,
};
