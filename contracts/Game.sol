// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./OAO/contracts/interfaces/IAIOracle.sol";
import "./OAO/contracts/AIOracleCallbackReceiver.sol";
import "./SystemPrompt.sol";

contract Game is Ownable, AIOracleCallbackReceiver {
    using Strings for uint8;
    // Structs ---------------

    struct GameSettings {
        uint256 queryFee;
        uint256 queryFeeIncrement;
        uint256 maxQueryFee;
        uint256 gameDuration;
        uint256 gameStartTime;
        uint8 pricePoolPercentage;
        uint8 devWalletPercentage;
    }

    struct PlayerQuery {
        address sender;
        uint256 requestId;
        uint256 fee;
        uint256 timestamp;
        uint8 score;
        bool won;
        bool failed;
        bool refunded;
    }

    struct AIOracleRequest {
        address sender;
        uint256 modelId;
        bytes input;
        bytes output;
        uint256 queryIndex;
    }

    struct PlayerRequestData {
        uint256 requestId;
        uint256 queryIndex;
        uint256 pricePoolShare;
        uint256 devWalletShare;
        address sender;
        bytes input;
    }

    // Events -------

    event LyraGameDeployed(uint256 timestamp, GameSettings settings);

    event PlayerAttempt(
        uint256 requestId,
        address player,
        uint256 modelId,
        string prompt
    );

    event PlayerAttemptResult(
        uint256 requestId,
        address player,
        uint256 modelId,
        string prompt,
        uint8 score,
        bool won
    );

    event PlayerRefunded(address player, uint256 refundDue);

    event WinnerAnnouncement(address player);

    // Custom Errors ------------

    error AmountLessThanQueryFee();
    error AmountLessThanQueryFeePlusSlippage();
    error GameHasNotStarted();
    error GameHasEnded();
    error FailedToSendEthers();
    error AIRequestDoesNotExist();
    error PlayerQueryDoesNotExist();
    error WinnerRewardConditionsNotMet();
    error WinnerAlreadyExists();
    error NotAParticipant();
    error GameIsInProgress();
    error AlreadyRefunded();
    error UnableToProcessRefund();
    error UnsupportedModel();

    // State Vars -----------

    address public winner;
    PlayerQuery public winnerQuery;
    address devWallet;
    uint256 public initialPricePool;
    uint256 public totalAttempts;
    uint256 public totalPlayers;
    uint256 public pool;
    uint8 public queryFeeMinSlippage;
    GameSettings public gameSettings;
    mapping(uint256 => uint64) public callbackGasLimit;
    mapping(uint256 => AIOracleRequest) public requests;
    mapping(address => mapping(uint256 => PlayerQuery)) public playerQueries;
    mapping(address => uint256) public playerQueryCount;

    string public constant name = "LyraVerse 01";

    bytes constant EMPTY_BYTES = bytes("");

    constructor(
        address _devWallet,
        address _owner,
        GameSettings memory _settings,
        IAIOracle _aiOracle
    ) payable Ownable(_owner) AIOracleCallbackReceiver(_aiOracle) {
        // Sanity Checks
        require(_devWallet != address(0), "Invalid Dev Wallet");

        require(
            _settings.queryFeeIncrement >= 0,
            "Invalid Query Fee Increment"
        );

        require(_settings.maxQueryFee > 0, "Invalid Max Query Fee");

        require(_settings.gameDuration >= 5 minutes, "Invalid Game Duration");

        require(
            _settings.devWalletPercentage >= 0 &&
                _settings.devWalletPercentage <= 100,
            "Must be between 0 and 100"
        );
        require(
            _settings.pricePoolPercentage >= 0 &&
                _settings.pricePoolPercentage <= 100,
            "Must be between 0 and 100"
        );

        require(
            _settings.devWalletPercentage + _settings.pricePoolPercentage ==
                100,
            "DevWalletPercentage and pricePoolPercentage must sum to 100"
        );

        // persist

        devWallet = _devWallet;

        gameSettings = _settings;

        initialPricePool = msg.value;

        pool = msg.value;

        // Preset Gas limits for models

        callbackGasLimit[11] = 5_000_000; // Llama

        emit LyraGameDeployed(block.timestamp, _settings);
    }

    // * PLAY THE GAME ----------

    function play(
        string calldata inputMessage,
        uint256 modelId
    ) external payable {
        // Sanity Checks

        if (callbackGasLimit[modelId] == 0) {
            revert UnsupportedModel();
        }

        if (gameSettings.gameStartTime > block.timestamp) {
            revert GameHasNotStarted();
        }

        if (
            block.timestamp >
            (gameSettings.gameStartTime + gameSettings.gameDuration)
        ) {
            revert GameHasEnded();
        }

        if (winner != address(0)) {
            revert WinnerAlreadyExists();
        }

        // * Gas estimation for OAO callback

        uint256 oaoCallbackGasFee = _estimateCallbackFee(modelId);

        if (msg.value < gameSettings.queryFee + oaoCallbackGasFee) {
            revert AmountLessThanQueryFee();
        }

        uint256 slippageAmount = (gameSettings.queryFee * queryFeeMinSlippage) /
            100;

        uint256 expectedQueryFee = gameSettings.queryFee + slippageAmount;

        if (msg.value < expectedQueryFee + oaoCallbackGasFee) {
            revert AmountLessThanQueryFeePlusSlippage();
        }

        uint256 excessQueryFee = msg.value -
            (gameSettings.queryFee + oaoCallbackGasFee);

        if (excessQueryFee > 0) {
            bool success = _sendEthers(msg.sender, excessQueryFee);

            if (!success) {
                revert FailedToSendEthers();
            }
        }

        uint256 value = msg.value - (excessQueryFee + oaoCallbackGasFee);

        PlayerRequestData memory playerData;
        playerData.devWalletShare =
            (value * gameSettings.devWalletPercentage) /
            100;

        playerData.pricePoolShare = value - playerData.devWalletShare;

        // credit dev wallet

        if (playerData.devWalletShare > 0) {
            bool success = _sendEthers(devWallet, playerData.devWalletShare);

            if (!success) {
                revert FailedToSendEthers();
            }
        }

        // add to pool

        pool += playerData.pricePoolShare;

        // calculate and set new query fee

        if (gameSettings.queryFee < gameSettings.maxQueryFee) {
            uint256 newQueryFee = gameSettings.queryFee +
                (gameSettings.queryFee * gameSettings.queryFeeIncrement) /
                (10 ** 20);

            gameSettings.queryFee = newQueryFee;
        }

        // register and process user prompt

        playerData.input = bytes(inputMessage);

        if (playerQueryCount[msg.sender] == 0) {
            totalPlayers += 1;
        }

        playerQueryCount[msg.sender] += 1;

        totalAttempts += 1;

        playerData.requestId = _processPrompt(
            modelId,
            _getPromptWithUserMessage(playerData.input),
            EMPTY_BYTES,
            oaoCallbackGasFee
        );

        playerData.queryIndex = playerQueryCount[msg.sender];
        playerData.sender = msg.sender;

        requests[playerData.requestId] = AIOracleRequest({
            sender: playerData.sender,
            modelId: modelId,
            input: playerData.input,
            output: EMPTY_BYTES,
            queryIndex: playerData.queryIndex
        });

        playerQueries[msg.sender][playerData.queryIndex] = PlayerQuery({
            sender: playerData.sender,
            timestamp: block.timestamp,
            requestId: playerData.requestId,
            fee: playerData.pricePoolShare,
            won: false,
            failed: false,
            refunded: false,
            score: 0
        });

        emit PlayerAttempt(
            playerData.requestId,
            msg.sender,
            modelId,
            inputMessage
        );
    }

    // * RESPONSE FROM OAO ----

    function aiOracleCallback(
        uint256 requestId,
        bytes calldata output,
        bytes calldata callbackData
    ) external override onlyAIOracleCallback {
        AIOracleRequest memory request = requests[requestId];

        if (request.sender == address(0)) {
            revert AIRequestDoesNotExist();
        }

        request.output = output;

        requests[requestId] = request;

        PlayerQuery memory playerQuery = playerQueries[request.sender][
            request.queryIndex
        ];

        if (playerQuery.sender == address(0)) {
            revert PlayerQueryDoesNotExist();
        }

        uint8 playerScore = _decodeScore(output);

        if (playerScore == 200) {
            playerQuery.failed = true;
        }

        playerQuery.score = playerScore;

        bool playerWon = (playerScore == 100);

        playerQuery.won = playerWon;

        // * final update to playerQuery here, no further updates allowed

        playerQueries[request.sender][request.queryIndex] = playerQuery;

        emit PlayerAttemptResult(
            requestId,
            request.sender,
            request.modelId,
            string(request.input),
            playerScore,
            playerWon
        );

        // Handle When Player Wins

        if (playerWon) {
            winner = request.sender;

            winnerQuery = playerQuery;

            emit WinnerAnnouncement(request.sender);

            // disburse fund to winner

            if (pool > 0 && address(this).balance > 0) {
                uint256 reward = pool;

                if (pool > address(this).balance) {
                    reward = address(this).balance;
                }

                bool success = _sendEthers(winner, reward);

                if (!success) {
                    revert FailedToSendEthers();
                }
            } else {
                revert WinnerRewardConditionsNotMet();
            }
        }
    }

    // * REFUND IN CASE OF NO WINNER AND GAME ENDED

    function refundPlayer() external {
        // Sanity checks

        if (playerQueryCount[msg.sender] == 0) {
            revert NotAParticipant();
        }

        if (winner != address(0)) {
            revert WinnerAlreadyExists();
        }

        if (
            (gameSettings.gameStartTime + gameSettings.gameDuration) >
            block.timestamp
        ) {
            revert GameIsInProgress();
        }

        uint256 refundDue = 0;

        for (uint256 i = 1; i <= playerQueryCount[msg.sender]; i++) {
            if (
                playerQueries[msg.sender][i].sender == msg.sender &&
                !playerQueries[msg.sender][i].refunded
            ) {
                playerQueries[msg.sender][i].refunded = true;

                refundDue += playerQueries[msg.sender][i].fee;
            }
        }

        if (refundDue == 0) {
            revert AlreadyRefunded();
        }

        if (address(this).balance >= refundDue) {
            bool success = _sendEthers(msg.sender, refundDue);

            if (!success) {
                revert FailedToSendEthers();
            }

            emit PlayerRefunded(msg.sender, refundDue);
        } else {
            revert UnableToProcessRefund();
        }
    }

    // *FETCH SYSTEM PROMPT
    function getPrompt() external pure returns (string memory) {
        return SystemPrompt.PROMPT;
    }

    // *FETCH GAS ESTIMATE FOR OAO MODEL CALLBACK

    function getGasEstimate(uint256 modelId) external view returns (uint256) {
        return _estimateCallbackFee(modelId);
    }

    // Internal Functions -------------------

    function _getPromptWithUserMessage(
        bytes memory userAttempt
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                bytes(SystemPrompt.PROMPT),
                "User's Attempt:\n'",
                userAttempt,
                "'\n"
            );
    }

    function _sendEthers(
        address _recipient,
        uint256 _amount
    ) internal returns (bool) {
        (bool success, ) = _recipient.call{value: _amount}("");

        return success;
    }

    function _processPrompt(
        uint256 modelId,
        bytes memory input,
        bytes memory callbackData,
        uint256 gasValue
    ) internal returns (uint256) {
        address callbackAddress = address(this);

        uint256 requestId = aiOracle.requestCallback{value: gasValue}(
            modelId,
            input,
            callbackAddress,
            callbackGasLimit[modelId],
            callbackData
        );

        return requestId;
    }

    function _decodeScore(bytes memory score) internal pure returns (uint8) {
        for (uint8 i = 0; i <= 100; i++) {
            if (keccak256(score) == keccak256(bytes(i.toString()))) {
                return i;
            }
        }

        return 200;
    }

    function _estimateCallbackFee(
        uint256 modelId
    ) internal view returns (uint256) {
        return aiOracle.estimateFee(modelId, callbackGasLimit[modelId]);
    }

    // Admin funcs ------------

    function setCallbackGasLimit(
        uint256 modelId,
        uint64 gasLimit
    ) external onlyOwner {
        callbackGasLimit[modelId] = gasLimit;
    }

    function setDevWallet(address _devWallet) external onlyOwner {
        require(_devWallet != address(0), "Invalid Dev Wallet");

        devWallet = _devWallet;
    }

    function setMinSlippgae(uint8 _slippage) external onlyOwner {
        require(
            _slippage >= 0 && _slippage <= 100,
            "Slippage must be between 0 and 100"
        );
        queryFeeMinSlippage = _slippage;
    }
}
