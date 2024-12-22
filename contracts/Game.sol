// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Game is Ownable, ReentrancyGuard {
    // Structs ---------------

    struct GameConfig {
        uint256 baseQueryFee;
        uint256 queryFeeIncrement;
        uint256 maxQueryFee;
        uint256 duration;
        uint256 startTime;
        uint8 prizePoolPercentage;
        uint8 developerWalletPercentage;
    }

    struct PlayerAttempt {
        address playerAddress;
        uint256 requestId;
        uint256 fee;
        uint256 timestamp;
        bool isWinner;
        bool isRefunded;
    }

    struct PlayerData {
        uint256 requestId;
        uint256 attemptIndex;
        uint256 prizePoolShare;
        uint256 developerShare;
        address playerAddress;
        bytes inputData;
    }

    // Events -------

    event GameLaunched(uint256 timestamp, GameConfig config);
    event PlayerAttempted(uint256 requestId, address player, string prompt);
    event PlayerAttemptResult(uint256 requestId, address player, string prompt);
    event PlayerRefunded(address player, uint256 refundAmount);
    event WinnerDeclared(address player);

    // Custom Errors ------------

    error InsufficientQueryFee();
    error InsufficientQueryFeeWithSlippage();
    error GameNotStarted();
    error GameEnded();
    error EtherTransferFailed();
    error PlayerAttemptNotFound();
    error WinnerRewardConditionsNotMet();
    error WinnerAlreadyDeclared();
    error NotAPlayer();
    error GameInProgress();
    error AlreadyRefunded();
    error RefundProcessingFailed();
    error RequestIDExists();

    // State Vars -----------

    address public currentWinner;
    PlayerAttempt public winningAttempt;
    address public developerWallet;
    uint256 public initialPrizePool;
    uint256 public totalAttempts;
    uint256 public totalPlayers;
    uint256 public prizePool;
    uint8 public minSlippagePercentage;
    GameConfig public gameConfig;
    mapping(address => uint256[]) public requestIds;
    mapping(address => mapping(uint256 => PlayerAttempt)) public playerAttempts;
    mapping(address => uint256) public playerAttemptCount;

    string public constant name = "Lyra 01";
    bytes constant EMPTY_BYTES = bytes("");

    constructor(
        address _owner,
        address _developerWallet,
        GameConfig memory _config
    ) payable Ownable(_owner) {
        // Sanity Checks
        require(_developerWallet != address(0), "Invalid Developer Wallet");
        require(_config.queryFeeIncrement >= 0, "Invalid Query Fee Increment");
        require(_config.maxQueryFee > 0, "Invalid Max Query Fee");
        require(_config.duration >= 5 minutes, "Invalid Game Duration");
        require(
            _config.developerWalletPercentage >= 0 &&
                _config.developerWalletPercentage <= 100,
            "Must be between 0 and 100"
        );
        require(
            _config.prizePoolPercentage >= 0 &&
                _config.prizePoolPercentage <= 100,
            "Must be between 0 and 100"
        );
        require(
            _config.developerWalletPercentage + _config.prizePoolPercentage ==
                100,
            "Developer and Prize Pool percentages must sum to 100"
        );
        // persist

        developerWallet = _developerWallet;
        gameConfig = _config;
        initialPrizePool = msg.value;
        prizePool = msg.value;

        emit GameLaunched(block.timestamp, _config);
    }

    // * PLAY THE GAME ----------

    function play(
        uint256 requestId,
        string calldata userInput
    ) external payable nonReentrant returns (PlayerAttempt memory) {
        // Sanity Checks
        if (gameConfig.startTime > block.timestamp) revert GameNotStarted();
        if (block.timestamp > (gameConfig.startTime + gameConfig.duration))
            revert GameEnded();
        if (currentWinner != address(0)) revert WinnerAlreadyDeclared();

        if (msg.value < gameConfig.baseQueryFee) {
            revert InsufficientQueryFee();
        }

        if (playerAttempts[msg.sender][requestId].playerAddress != address(0)) {
            revert RequestIDExists();
        }

        uint256 slippageAmount = (gameConfig.baseQueryFee *
            minSlippagePercentage) / 100;
        uint256 expectedQueryFee = gameConfig.baseQueryFee + slippageAmount;

        if (msg.value < expectedQueryFee) {
            revert InsufficientQueryFeeWithSlippage();
        }

        uint256 excessQueryFee = msg.value - (gameConfig.baseQueryFee);

        if (excessQueryFee > 0) {
            bool success = _transferEther(msg.sender, excessQueryFee);
            if (!success) {
                revert EtherTransferFailed();
            }
        }

        uint256 netValue = msg.value - (excessQueryFee);
        PlayerData memory playerData;
        playerData.developerShare =
            (netValue * gameConfig.developerWalletPercentage) /
            100;
        playerData.prizePoolShare = netValue - playerData.developerShare;

        // credit dev wallet

        if (playerData.developerShare > 0) {
            bool success = _transferEther(
                developerWallet,
                playerData.developerShare
            );
            if (!success) {
                revert EtherTransferFailed();
            }
        }

        // Update prize pool
        prizePool += playerData.prizePoolShare;

        // Update query fee if applicable
        if (gameConfig.baseQueryFee < gameConfig.maxQueryFee) {
            uint256 newQueryFee = gameConfig.baseQueryFee +
                (gameConfig.baseQueryFee * gameConfig.queryFeeIncrement) /
                (10 ** 20);
            gameConfig.baseQueryFee = newQueryFee;
        }

        // register and process user prompt

        playerData.inputData = bytes(userInput);
        if (playerAttemptCount[msg.sender] == 0) {
            totalPlayers += 1;
        }

        playerAttemptCount[msg.sender] += 1;
        totalAttempts += 1;

        playerData.requestId = requestId;
        playerData.playerAddress = msg.sender;

        requestIds[playerData.playerAddress].push(requestId);

        playerAttempts[msg.sender][requestId] = PlayerAttempt({
            playerAddress: playerData.playerAddress,
            timestamp: block.timestamp,
            requestId: playerData.requestId,
            fee: playerData.prizePoolShare,
            isWinner: false,
            isRefunded: false
        });

        emit PlayerAttempted(playerData.requestId, msg.sender, userInput);
        return playerAttempts[msg.sender][requestId];
    }

    // * DECLARE WINNER ----

    function declareWinner(
        uint256 requestId,
        address winnerAddress
    ) external onlyOwner {
        if (gameConfig.startTime > block.timestamp) revert GameNotStarted();

        if (block.timestamp > (gameConfig.startTime + gameConfig.duration))
            revert GameEnded();

        PlayerAttempt storage playerAttempt = playerAttempts[winnerAddress][
            requestId
        ];

        require(
            winnerAddress == playerAttempt.playerAddress,
            " Winner address does not match player address "
        );

        if (playerAttempt.playerAddress == address(0)) {
            revert NotAPlayer();
        }

        if (currentWinner != address(0)) {
            revert WinnerAlreadyDeclared();
        }

        currentWinner = winnerAddress;
        playerAttempt.isWinner = true;
        winningAttempt = playerAttempt;

        if (prizePool == 0 || address(this).balance == 0)
            revert WinnerRewardConditionsNotMet();

        uint256 reward = (prizePool > address(this).balance)
            ? address(this).balance
            : prizePool;

        if (!_transferEther(currentWinner, reward))
            revert EtherTransferFailed();

        emit WinnerDeclared(currentWinner);
    }

    // * REFUND IN CASE OF NO WINNER AND GAME ENDED

    function getRefund() external nonReentrant {
        // Sanity checks

        if (gameConfig.startTime > block.timestamp) revert GameNotStarted();

        if ((gameConfig.startTime + gameConfig.duration) > block.timestamp) {
            revert GameInProgress();
        }

        if (playerAttemptCount[msg.sender] == 0) {
            revert NotAPlayer();
        }

        if (currentWinner != address(0)) {
            revert WinnerAlreadyDeclared();
        }

        uint256 refundDue = 0;

        for (uint256 i = 0; i < requestIds[msg.sender].length; i++) {
            PlayerAttempt storage playerAttempt = playerAttempts[msg.sender][
                requestIds[msg.sender][i]
            ];

            if (
                playerAttempt.playerAddress == msg.sender &&
                !playerAttempt.isRefunded
            ) {
                playerAttempt.isRefunded = true;

                refundDue += playerAttempt.fee;
            }
        }

        if (refundDue == 0) {
            revert AlreadyRefunded();
        }

        if (address(this).balance >= refundDue) {
            if (!_transferEther(msg.sender, refundDue))
                revert EtherTransferFailed();

            emit PlayerRefunded(msg.sender, refundDue);
        } else {
            revert RefundProcessingFailed();
        }
    }

    // Internal Functions -------------------

    function _transferEther(
        address _recipient,
        uint256 _amount
    ) internal returns (bool) {
        (bool success, ) = _recipient.call{value: _amount}("");

        return success;
    }

    // Admin funcs ------------

    function setDeveloperWallet(address _devWallet) external onlyOwner {
        require(_devWallet != address(0), "Invalid Dev Wallet");

        developerWallet = _devWallet;
    }

    function updateConfig(GameConfig memory _config) external onlyOwner {
        gameConfig = _config;
    }

    function setMinSlippgae(uint8 _slippage) external onlyOwner {
        require(
            _slippage >= 0 && _slippage <= 100,
            "Slippage must be between 0 and 100"
        );
        minSlippagePercentage = _slippage;
    }
}
