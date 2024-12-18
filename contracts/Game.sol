// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "hardhat/console.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./OAO/contracts/interfaces/IAIOracle.sol";
import "./OAO/contracts/AIOracleCallbackReceiver.sol";

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

    error InvalidDevWallet();
    error InvalidQueryFeeIncrement();
    error InvalidGameDuration();
    error InvalidMaxQueryFee();
    error AmountLessThanQueryFee();
    error AmountLessThanQueryFeePlusSlippage();
    error GameHasNotStarted();
    error GameHasEnded();
    error MustBeAPercentage();
    error MustSumToPercentage();
    error FailedToSendEthers();
    error AIRequestDoesNotExist();
    error PlayerQueryDoesNotExist();
    error WinnerRewardConditionsNotMet();
    error WinnerAlreadyExists();
    error NotAParticipant();
    error GameIsInProgress();
    error AlreadyRefunded();
    error UnableToProcessRefund();
    // State Vars -----------

    address public winner;
    PlayerQuery public winnerQuery;
    address devWallet;
    uint256 public initialPricePool;
    uint256 public pool;
    uint8 public queryFeeMinSlippage;
    GameSettings public gameSettings;
    mapping(uint256 => uint64) public callbackGasLimit;
    mapping(uint256 => AIOracleRequest) public requests;
    mapping(address => mapping(uint256 => PlayerQuery)) public playerQueries;
    mapping(address => uint256) public playerQueryCount;

    constructor(
        address _devWallet,
        address _owner,
        GameSettings memory _settings,
        IAIOracle _aiOracle
    ) payable Ownable(_owner) AIOracleCallbackReceiver(_aiOracle) {
        // Sanity Checks
        require(_devWallet != address(0), InvalidDevWallet());

        require(_settings.queryFeeIncrement >= 0, InvalidQueryFeeIncrement());

        require(_settings.maxQueryFee > 0, InvalidMaxQueryFee());

        require(_settings.gameDuration >= 5 minutes, InvalidGameDuration());

        require(
            _settings.devWalletPercentage >= 0 &&
                _settings.devWalletPercentage <= 100,
            MustBeAPercentage()
        );
        require(
            _settings.pricePoolPercentage >= 0 &&
                _settings.pricePoolPercentage <= 100,
            MustBeAPercentage()
        );

        require(
            _settings.devWalletPercentage + _settings.pricePoolPercentage ==
                100,
            MustSumToPercentage()
        );

        // persist

        devWallet = _devWallet;

        gameSettings = _settings;

        initialPricePool = msg.value;

        pool = msg.value;

        // Preset Gas limits for models

        callbackGasLimit[50] = 500_000; // Stable-Diffusion
        callbackGasLimit[11] = 5_000_000; // Llama

        emit LyraGameDeployed(block.timestamp, _settings);
    }

    // * PLAY THE GAME ----------

    function play(
        string calldata inputMessage,
        uint256 modelId
    ) external payable {
        // Sanity Checks

        require(
            gameSettings.gameStartTime >= block.timestamp,
            GameHasNotStarted()
        );

        require(
            gameSettings.gameStartTime + gameSettings.gameDuration >
                block.timestamp,
            GameHasEnded()
        );

        require(winner == address(0), WinnerAlreadyExists());

        require(msg.value >= gameSettings.queryFee, AmountLessThanQueryFee());

        uint256 slippageAmount = (gameSettings.queryFee * queryFeeMinSlippage) /
            100;

        uint256 expectedQueryFee = gameSettings.queryFee + slippageAmount;

        require(
            msg.value >= expectedQueryFee,
            AmountLessThanQueryFeePlusSlippage()
        );

        uint256 excessQueryFee = msg.value - gameSettings.queryFee;

        if (excessQueryFee > 0) {
            bool success = _sendEthers(msg.sender, excessQueryFee);
            require(success, FailedToSendEthers());
        }

        uint256 value = msg.value - excessQueryFee;

        uint256 devWalletShare = (value * gameSettings.devWalletPercentage) /
            100;

        uint256 pricePoolShare = value - devWalletShare;

        // credit dev wallet

        if (devWalletShare > 0) {
            bool success = _sendEthers(devWallet, devWalletShare);
            require(success, FailedToSendEthers());
        }

        // add to pool

        pool += pricePoolShare;

        // calculate and set new query fee

        uint256 newQueryFee = gameSettings.queryFee +
            (gameSettings.queryFee * gameSettings.queryFeeIncrement) /
            (10 ** 20);

        gameSettings.queryFee = newQueryFee;

        // register and process user prompt

        bytes memory input = bytes(inputMessage);
        bytes memory callbackData = bytes("");

        // TODO Gas estimation
        playerQueryCount[msg.sender] += 1;

        uint256 requestId = _processPrompt(
            modelId,
            input,
            callbackData,
            pricePoolShare
        );

        AIOracleRequest memory aiRequest;

        aiRequest.sender = msg.sender;
        aiRequest.modelId = modelId;

        aiRequest.input = input;

        aiRequest.queryIndex = playerQueryCount[msg.sender];

        requests[requestId] = aiRequest;

        PlayerQuery memory playerQuery;

        playerQuery.sender = msg.sender;
        playerQuery.timestamp = block.timestamp;
        playerQuery.requestId = requestId;
        playerQuery.fee = pricePoolShare;

        playerQueries[msg.sender][playerQueryCount[msg.sender]] = playerQuery;

        emit PlayerAttempt(requestId, msg.sender, modelId, inputMessage);
    }

    // * RESPONSE FROM OAO ----

    function aiOracleCallback(
        uint256 requestId,
        bytes calldata output,
        bytes calldata callbackData
    ) external override onlyAIOracleCallback {
        AIOracleRequest memory request = requests[requestId];

        require(request.sender != address(0), AIRequestDoesNotExist());

        request.output = output;

        PlayerQuery memory playerQuery = playerQueries[request.sender][
            request.queryIndex
        ];

        require(playerQuery.sender != address(0), PlayerQueryDoesNotExist());

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

                require(success, FailedToSendEthers());
            } else {
                revert WinnerRewardConditionsNotMet();
            }
        }
    }

    // * REFUND IN CASE OF NO WINNER AND GAME ENDED

    function refundPlayer() external {
        // Sanity checks
        require(playerQueryCount[msg.sender] > 0, NotAParticipant());
        require(winner == address(0), WinnerAlreadyExists());
        require(
            block.timestamp >
                (gameSettings.gameStartTime + gameSettings.gameDuration),
            GameIsInProgress()
        );

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

        require(refundDue > 0, AlreadyRefunded());

        if (address(this).balance >= refundDue) {
            bool success = _sendEthers(msg.sender, refundDue);

            require(success, FailedToSendEthers());

            emit PlayerRefunded(msg.sender, refundDue);
        } else {
            revert UnableToProcessRefund();
        }
    }

    // Internal Functions -------------------

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

    // Admin funcs ------------

    function setCallbackGasLimit(
        uint256 modelId,
        uint64 gasLimit
    ) external onlyOwner {
        callbackGasLimit[modelId] = gasLimit;
    }

    function setDevWallet(address _devWallet) external onlyOwner {
        require(_devWallet != address(0), InvalidDevWallet());

        devWallet = _devWallet;
    }

    function setMinSlippgae(uint8 _slippage) external onlyOwner {
        require(_slippage >= 0 && _slippage <= 100, MustBeAPercentage());
        queryFeeMinSlippage = _slippage;
    }
}
