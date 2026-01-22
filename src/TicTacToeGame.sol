// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VRFConsumerBaseV2Plus} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IVRFCoordinatorV2Plus} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";



enum GameState {
    OPEN,
    STAKED,
    VRF_PENDING,
    IN_PROGRESS,
    FINISHED,
    PAID_OUT,
    CANCELLED
}

enum CellState {
    EMPTY,
    PLAYER1,
    PLAYER2
}

struct Player {
    address addr;
    uint256 stableAmount;
    uint8 wins;
    bool withdrawn;
}

struct Board {
    CellState[3][3] cells;
    uint8 moveCount;
}

struct Match {
    GameState state;
    Player[] players;
    uint8 currentRound;
    uint256 totalStableAmount;
    uint8 starterIndex;
    address winner;
    uint256 createdAt;
    Board currentBoard;
    uint8 currentPlayerIndex;
    uint256 lastMoveTime;
    uint256 autoRefundTime;
}



interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface ITicTacToeGame {
    function handleVRFFulfillment(uint256 matchId, uint256 randomNumber) external;
    function executeGaslessWithdrawal(uint256 matchId, address recipient) external;
}



contract PriceFeedManager is Ownable {
    using SafeERC20 for IERC20;

    mapping(address => address) public priceFeeds;
    address[] public supportedTokens;
    mapping(address => bool) public isTokenSupported;

    event TokenAdded(address indexed token, address indexed priceFeed);
    event TokenRemoved(address indexed token);

    constructor() Ownable(msg.sender) {
        supportedTokens.push(address(0));
        isTokenSupported[address(0)] = true;
    }

    function addToken(address token, address priceFeed) external onlyOwner {
        require(!isTokenSupported[token], "Token already supported");
        require(priceFeed != address(0), "Invalid price feed");

        priceFeeds[token] = priceFeed;
        supportedTokens.push(token);
        isTokenSupported[token] = true;

        emit TokenAdded(token, priceFeed);
    }

    function removeToken(address token) external onlyOwner {
        require(token != address(0), "Cannot remove ETH");
        require(isTokenSupported[token], "Token not supported");

        isTokenSupported[token] = false;
        delete priceFeeds[token];

        emit TokenRemoved(token);
    }

    function getPrice(address token) public view returns (uint256) {
        require(isTokenSupported[token], "Token not supported");

        address feed = priceFeeds[token];
        require(feed != address(0), "No price feed configured");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();

        require(price > 0, "Invalid price");
        require(updatedAt > block.timestamp - 1 hours, "Stale price");

        return uint256(price);
    }

    function getPriceDecimals(address token) public view returns (uint8) {
        address feed = priceFeeds[token];
        require(feed != address(0), "No price feed configured");
        return AggregatorV3Interface(feed).decimals();
    }

    // Returns USD value in 18 decimals
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        uint256 price = getPrice(token);                 // price in priceDecimals
        uint8 priceDecimals = getPriceDecimals(token);

        uint8 tokenDecimals = token == address(0)
            ? 18
            : IERC20Metadata(token).decimals();

        // Normalize to 18-decimals USD:
        // amount (tokenDecimals) * price (priceDecimals) / 10^(tokenDecimals + priceDecimals) * 10^18
        uint256 usd18 = (amount * price * 10**18) / (10**tokenDecimals * 10**priceDecimals);
        return usd18;
    }

    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    function setEthPriceFeed(address priceFeed) external onlyOwner {
        priceFeeds[address(0)] = priceFeed;
    }
}

// ============================================================================
// SWAP MANAGER (ETH→WETH, minOut from USD18)
// ============================================================================

contract SwapManager {
    using SafeERC20 for IERC20;

    ISwapRouter public immutable swapRouter;
    IWETH public immutable weth;
    address public immutable stablecoin;
    address public immutable gameContract;
    uint24 public constant poolFee = 3000;

    PriceFeedManager public priceFeedManager;

    event TokenSwapped(address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    modifier onlyGame() {
        require(msg.sender == gameContract, "Only game contract");
        _;
    }

    constructor(
        address _swapRouter,
        address _weth,
        address _stablecoin,
        address _priceFeedManager,
        address _gameContract
    ) {
        swapRouter = ISwapRouter(_swapRouter);
        weth = IWETH(_weth);
        stablecoin = _stablecoin;
        priceFeedManager = PriceFeedManager(_priceFeedManager);
        gameContract = _gameContract;
    }

    function swapToStable(address tokenIn, uint256 amountIn)
        external
        payable
        onlyGame
        returns (uint256 amountOut)
    {
        if (tokenIn == stablecoin) {
            return amountIn;
        }

        uint256 minAmountOut = _calculateMinAmountOut(tokenIn, amountIn);

        if (tokenIn == address(0)) {
            // Wrap ETH to WETH
            weth.deposit{value: amountIn}();
            weth.approve(address(swapRouter), amountIn);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: stablecoin,
                fee: poolFee,
                recipient: gameContract,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

            amountOut = swapRouter.exactInputSingle(params);
        } else {
            IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: stablecoin,
                fee: poolFee,
                recipient: gameContract,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

            amountOut = swapRouter.exactInputSingle(params);
        }

        emit TokenSwapped(tokenIn, amountIn, amountOut);
        return amountOut;
    }

    // usdValue18 -> stableDecimals with 1% slippage
    function _calculateMinAmountOut(address tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        uint256 usdValue18 = priceFeedManager.getUsdValue(tokenIn, amountIn);
        uint8 stableDecimals = IERC20Metadata(stablecoin).decimals();

        uint256 minAmountOut = (usdValue18 * 99 * 10**stableDecimals) / (100 * 10**18);
        return minAmountOut;
    }

    receive() external payable {}
}



contract AutomatedStakePool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    address public immutable stablecoin;
    address public immutable gameContract;

    mapping(uint256 => uint256) public matchStableBalances;

    uint256 public protocolFeePercent = 2;
    uint256 public accumulatedFees;

    event StableDeposited(uint256 indexed matchId, address indexed player, uint256 amount);
    event StableWithdrawn(uint256 indexed matchId, address indexed recipient, uint256 amount);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    modifier onlyGame() {
        require(msg.sender == gameContract, "Only game contract");
        _;
    }

    constructor(address _stablecoin, address _gameContract) Ownable(msg.sender) {
        stablecoin = _stablecoin;
        gameContract = _gameContract;
    }

    function depositStable(uint256 matchId, uint256 amount) external onlyGame {
        matchStableBalances[matchId] += amount;
        emit StableDeposited(matchId, msg.sender, amount);
    }

    function withdraw(
        uint256 matchId,
        address recipient,
        uint256 amount
    ) external onlyGame nonReentrant returns (uint256 payout) {
        require(matchStableBalances[matchId] >= amount, "Insufficient balance");
        matchStableBalances[matchId] -= amount;

        uint256 fee = (amount * protocolFeePercent) / 100;
        payout = amount - fee;

        accumulatedFees += fee;

        IERC20(stablecoin).safeTransfer(recipient, payout);

        emit StableWithdrawn(matchId, recipient, payout);
        return payout;
    }

    function refund(
        uint256 matchId,
        address recipient,
        uint256 amount
    ) external onlyGame nonReentrant {
        require(matchStableBalances[matchId] >= amount, "Insufficient balance");
        matchStableBalances[matchId] -= amount;

        IERC20(stablecoin).safeTransfer(recipient, amount);

        emit StableWithdrawn(matchId, recipient, amount);
    }

    function withdrawFees() external onlyOwner nonReentrant {
        uint256 fees = accumulatedFees;
        require(fees > 0, "No fees");
        accumulatedFees = 0;

        IERC20(stablecoin).safeTransfer(owner(), fees);

        emit FeesWithdrawn(owner(), fees);
    }
}


contract VRFConsumer is VRFConsumerBaseV2Plus {
    IVRFCoordinatorV2Plus immutable COORDINATOR;

    uint256 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 200000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;

    mapping(uint256 => uint256) public requestIdToMatchId;
    mapping(uint256 => uint256) public matchIdToRandomNumber;

    address public gameContract;

    event RandomnessRequested(uint256 indexed matchId, uint256 requestId);
    event RandomnessFulfilled(uint256 indexed matchId, uint256 randomNumber);

    constructor(
        uint256 _subscriptionId,
        address _vrfCoordinator,
        bytes32 _keyHash
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        COORDINATOR = IVRFCoordinatorV2Plus(_vrfCoordinator);
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
    }

    function setGameContract(address _gameContract) external {
        require(gameContract == address(0), "Already set");
        gameContract = _gameContract;
    }

    function requestRandomWords(uint256 matchId) external returns (uint256) {
        require(msg.sender == gameContract, "Only game contract");

        uint256 requestId = COORDINATOR.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        requestIdToMatchId[requestId] = matchId;

        emit RandomnessRequested(matchId, requestId);
        return requestId;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        uint256 matchId = requestIdToMatchId[requestId];
        matchIdToRandomNumber[matchId] = randomWords[0];

        emit RandomnessFulfilled(matchId, randomWords[0]);

        ITicTacToeGame(gameContract).handleVRFFulfillment(matchId, randomWords[0]);
    }
}



contract GaslessRelayer is Ownable {
    using SafeERC20 for IERC20;

    address public immutable stablecoin;
    PriceFeedManager public priceFeedManager;

    mapping(address => uint256) public sponsoredGasPool;

    event GasSponsored(address indexed sponsor, uint256 amount);
    event GasUsed(address indexed user, uint256 gasUsed, uint256 gasCost);

    constructor(address _stablecoin, address _priceFeedManager) Ownable(msg.sender) {
        stablecoin = _stablecoin;
        priceFeedManager = PriceFeedManager(_priceFeedManager);
    }

    function sponsorGas(uint256 amount) external {
        IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), amount);
        sponsoredGasPool[msg.sender] += amount;
        emit GasSponsored(msg.sender, amount);
    }

    function executeWithdrawal(
        address gameContract,
        uint256 matchId,
        address recipient
    ) external onlyOwner returns (uint256 gasCost) {
        uint256 gasStart = gasleft();

        ITicTacToeGame(gameContract).executeGaslessWithdrawal(matchId, recipient);

        uint256 gasUsed = gasStart - gasleft() + 21000;
        gasCost = gasUsed * tx.gasprice;

        uint256 gasCostInStable = _convertEthToStable(gasCost);
        require(sponsoredGasPool[recipient] >= gasCostInStable, "Insufficient gas pool");

        sponsoredGasPool[recipient] -= gasCostInStable;

        emit GasUsed(recipient, gasUsed, gasCostInStable);
    }

    function _convertEthToStable(uint256 ethAmount) internal view returns (uint256) {
        // USD in 18 decimals
        uint256 usd18 = priceFeedManager.getUsdValue(address(0), ethAmount);
        uint8 stableDecimals = IERC20Metadata(stablecoin).decimals();

        // USD(18) -> stable(decimals)
        return (usd18 * 10**stableDecimals) / 10**18;
    }
}



contract TicTacToeGame is ITicTacToeGame, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_PLAYERS = 2;
    uint256 public constant MAX_PLAYERS = 2; // Enforce 2 players
    uint256 public constant MAX_ROUNDS = 5;
    uint256 public constant MOVE_TIMEOUT = 120;
    uint256 public constant MIN_STAKE_USD = 10 * 10**6; // e.g., USDC 6 decimals
    uint256 public constant AUTO_REFUND_DELAY = 7 days;

    AutomatedStakePool public stakePool;
    VRFConsumer public vrfConsumer;
    PriceFeedManager public priceFeedManager;
    SwapManager public swapManager;
    GaslessRelayer public gaslessRelayer;

    address public immutable stablecoin;
    address public immutable weth;

    uint256 public matchCounter;
    mapping(uint256 => Match) public matches;
    mapping(uint256 => mapping(address => bool)) public hasJoined;

    event MatchCreated(uint256 indexed matchId);
    event PlayerJoined(uint256 indexed matchId, address indexed player, uint256 stableAmount);
    event GameStarted(uint256 indexed matchId);
    event StarterSelected(uint256 indexed matchId, address indexed starter);
    event MoveMade(uint256 indexed matchId, address indexed player, uint8 x, uint8 y);
    event RoundWon(uint256 indexed matchId, uint8 round, address indexed winner);
    event RoundDraw(uint256 indexed matchId, uint8 round);
    event WinnerSelected(uint256 indexed matchId, address indexed winner, uint256 totalAmount);
    event MatchCancelled(uint256 indexed matchId);
    event PrizeWithdrawn(uint256 indexed matchId, address indexed player, uint256 amount);
    event AutoRefundExecuted(uint256 indexed matchId);
    event PlayerTimedOut(uint256 indexed matchId, address indexed player);

    constructor(
        address _vrfConsumer,
        address _priceFeedManager,
        address _gaslessRelayer,
        address _stablecoin,
        address _swapRouter,
        address _weth
    ) Ownable(msg.sender) {
        stablecoin = _stablecoin;
        weth = _weth;

        stakePool = new AutomatedStakePool(_stablecoin, address(this));
        swapManager = new SwapManager(_swapRouter, _weth, _stablecoin, _priceFeedManager, address(this));

        vrfConsumer = VRFConsumer(_vrfConsumer);
        priceFeedManager = PriceFeedManager(_priceFeedManager);
        gaslessRelayer = GaslessRelayer(_gaslessRelayer);
    }


    function createMatch() external returns (uint256) {
        matchCounter++;
        uint256 matchId = matchCounter;

        Match storage m = matches[matchId];
        m.state = GameState.OPEN;
        m.createdAt = block.timestamp;
        m.autoRefundTime = block.timestamp + AUTO_REFUND_DELAY;

        emit MatchCreated(matchId);
        return matchId;
    }

    function joinGameWithETH(uint256 matchId) external payable nonReentrant {
        _joinGame(matchId, address(0), msg.value);
    }

    function joinGameWithToken(uint256 matchId, address token, uint256 amount)
        external
        nonReentrant
    {
        require(token != address(0), "Use joinGameWithETH for ETH");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _joinGame(matchId, token, amount);
    }

    function _joinGame(uint256 matchId, address token, uint256 amount) internal {
        Match storage m = matches[matchId];

        require(m.state == GameState.OPEN, "Match not open");
        require(priceFeedManager.isTokenSupported(token), "Token not supported");
        require(!hasJoined[matchId][msg.sender], "Already joined");
        require(m.players.length < MAX_PLAYERS, "Match full");

        uint256 stableAmount;

        if (token == stablecoin) {
            stableAmount = amount;
        } else {
            if (token != address(0)) {
                IERC20(token).safeTransfer(address(swapManager), amount);
            }

            if (token == address(0)) {
                stableAmount = swapManager.swapToStable{value: amount}(token, amount);
            } else {
                stableAmount = swapManager.swapToStable(token, amount);
            }
        }

        require(stableAmount >= MIN_STAKE_USD, "Stake too low");

        IERC20(stablecoin).forceApprove(address(stakePool), stableAmount);
        stakePool.depositStable(matchId, stableAmount);

        m.players.push(Player({
            addr: msg.sender,
            stableAmount: stableAmount,
            wins: 0,
            withdrawn: false
        }));

        m.totalStableAmount += stableAmount;
        hasJoined[matchId][msg.sender] = true;

        emit PlayerJoined(matchId, msg.sender, stableAmount);

        if (m.players.length >= MIN_PLAYERS) {
            m.state = GameState.STAKED;
        }
    }

    function startGame(uint256 matchId) external {
        Match storage m = matches[matchId];

        require(m.state == GameState.STAKED, "Not ready");
        require(m.players.length >= MIN_PLAYERS, "Not enough players");

        m.state = GameState.VRF_PENDING;
        vrfConsumer.requestRandomWords(matchId);

        emit GameStarted(matchId);
    }

    function handleVRFFulfillment(uint256 matchId, uint256 randomNumber) external {
        require(msg.sender == address(vrfConsumer), "Only VRF");

        Match storage m = matches[matchId];
        require(m.state == GameState.VRF_PENDING, "Invalid state");

        m.starterIndex = uint8(randomNumber % m.players.length);
        m.state = GameState.IN_PROGRESS;
        m.currentRound = 1;

        _initializeBoard(matchId);
        m.currentPlayerIndex = m.starterIndex;
        m.lastMoveTime = block.timestamp;

        emit StarterSelected(matchId, m.players[m.starterIndex].addr);
    }

   

    function makeMove(uint256 matchId, uint8 x, uint8 y) external {
        Match storage m = matches[matchId];

        require(m.state == GameState.IN_PROGRESS, "Game not active");
        require(x < 3 && y < 3, "Invalid position");
        require(m.currentBoard.cells[x][y] == CellState.EMPTY, "Cell occupied");
        require(m.players[m.currentPlayerIndex].addr == msg.sender, "Not your turn");
        require(block.timestamp - m.lastMoveTime <= MOVE_TIMEOUT, "Move timeout");

        CellState playerCell = m.currentPlayerIndex == 0 ? CellState.PLAYER1 : CellState.PLAYER2;
        m.currentBoard.cells[x][y] = playerCell;
        m.currentBoard.moveCount++;
        m.lastMoveTime = block.timestamp;

        emit MoveMade(matchId, msg.sender, x, y);

        if (_checkWin(m.currentBoard, playerCell)) {
            m.players[m.currentPlayerIndex].wins++;
            emit RoundWon(matchId, m.currentRound, msg.sender);
            _nextRound(matchId);
            return;
        }

        if (m.currentBoard.moveCount == 9) {
            emit RoundDraw(matchId, m.currentRound);
            _nextRound(matchId);
            return;
        }

        m.currentPlayerIndex = (m.currentPlayerIndex + 1) % 2;
    }

    function claimTimeoutWin(uint256 matchId) external {
        Match storage m = matches[matchId];

        require(m.state == GameState.IN_PROGRESS, "Game not active");
        require(block.timestamp - m.lastMoveTime > MOVE_TIMEOUT, "No timeout yet");

        uint8 opponentIndex = m.currentPlayerIndex;
        uint8 winnerIndex = (m.currentPlayerIndex + 1) % 2;

        require(m.players[winnerIndex].addr == msg.sender, "Not eligible");

        m.players[winnerIndex].wins++;

        emit PlayerTimedOut(matchId, m.players[opponentIndex].addr);
        emit RoundWon(matchId, m.currentRound, msg.sender);

        _nextRound(matchId);
    }

    function _initializeBoard(uint256 matchId) internal {
        Match storage m = matches[matchId];
        for (uint8 i = 0; i < 3; i++) {
            for (uint8 j = 0; j < 3; j++) {
                m.currentBoard.cells[i][j] = CellState.EMPTY;
            }
        }
        m.currentBoard.moveCount = 0;
    }

    function _nextRound(uint256 matchId) internal {
        Match storage m = matches[matchId];

        if (m.currentRound >= MAX_ROUNDS) {
            _selectWinner(matchId);
            return;
        }

        m.currentRound++;
        _initializeBoard(matchId);
        m.currentPlayerIndex = uint8((m.starterIndex + m.currentRound - 1) % m.players.length);
        m.lastMoveTime = block.timestamp;
    }

    function _checkWin(Board storage board, CellState player) internal view returns (bool) {
        for (uint8 i = 0; i < 3; i++) {
            if (board.cells[i][0] == player && board.cells[i][1] == player && board.cells[i][2] == player) {
                return true;
            }
        }

        for (uint8 j = 0; j < 3; j++) {
            if (board.cells[0][j] == player && board.cells[1][j] == player && board.cells[2][j] == player) {
                return true;
            }
        }

        if (board.cells[0][0] == player && board.cells[1][1] == player && board.cells[2][2] == player) {
            return true;
        }

        if (board.cells[0][2] == player && board.cells[1][1] == player && board.cells[2][0] == player) {
            return true;
        }

        return false;
    }

    function _selectWinner(uint256 matchId) internal {
        Match storage m = matches[matchId];

        uint8 maxWins = 0;
        uint8 winnerIndex = 0;

        for (uint8 i = 0; i < m.players.length; i++) {
            if (m.players[i].wins > maxWins) {
                maxWins = m.players[i].wins;
                winnerIndex = i;
            }
        }

        for (uint8 i = 0; i < m.players.length; i++) {
            if (m.players[i].wins == maxWins &&
                m.players[i].stableAmount > m.players[winnerIndex].stableAmount) {
                winnerIndex = i;
            }
        }

    
        if (maxWins == 0) {
            for (uint256 i = 0; i < m.players.length; i++) {
                if (!m.players[i].withdrawn) {
                    m.players[i].withdrawn = true;
                    stakePool.refund(matchId, m.players[i].addr, m.players[i].stableAmount);
                }
            }
            m.state = GameState.CANCELLED;
            emit MatchCancelled(matchId);
            return;
        }
        

        // Default: mark cancelled; players can withdraw via withdrawMyStake
        if (maxWins == 0) {
            m.state = GameState.CANCELLED;
            emit MatchCancelled(matchId);
            return;
        }

        m.winner = m.players[winnerIndex].addr;
        m.state = GameState.FINISHED;

        emit WinnerSelected(matchId, m.winner, m.totalStableAmount);
    }


    function withdrawPrize(uint256 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(m.state == GameState.FINISHED, "Game not finished");
        require(m.winner == msg.sender, "Not winner");

        for (uint256 i = 0; i < m.players.length; i++) {
            if (!m.players[i].withdrawn) {
                Player storage player = m.players[i];
                player.withdrawn = true;

                stakePool.withdraw(matchId, m.winner, player.stableAmount);

                emit PrizeWithdrawn(matchId, player.addr, player.stableAmount);
            }
        }

        m.state = GameState.PAID_OUT;
    }

    function withdrawMyStake(uint256 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(
            m.state == GameState.FINISHED || m.state == GameState.CANCELLED,
            "Game not finished"
        );

        uint256 playerIndex = type(uint256).max;
        for (uint256 i = 0; i < m.players.length; i++) {
            if (m.players[i].addr == msg.sender) {
                playerIndex = i;
                break;
            }
        }

        require(playerIndex != type(uint256).max, "Not a player");
        Player storage player = m.players[playerIndex];
        require(!player.withdrawn, "Already withdrawn");

        player.withdrawn = true;

        if (m.state == GameState.CANCELLED) {
            stakePool.refund(matchId, msg.sender, player.stableAmount);
        } else if (msg.sender == m.winner) {
            stakePool.withdraw(matchId, msg.sender, player.stableAmount);
        }
        

        emit PrizeWithdrawn(matchId, msg.sender, player.stableAmount);
    }


    function executeGaslessWithdrawal(uint256 matchId, address recipient) external {
        require(msg.sender == address(gaslessRelayer), "Only relayer");

        Match storage m = matches[matchId];
        require(
            m.state == GameState.FINISHED || m.state == GameState.CANCELLED,
            "Game not finished"
        );

        uint256 playerIndex = type(uint256).max;
        for (uint256 i = 0; i < m.players.length; i++) {
            if (m.players[i].addr == recipient) {
                playerIndex = i;
                break;
            }
        }

        require(playerIndex != type(uint256).max, "Not a player");
        Player storage player = m.players[playerIndex];
        require(!player.withdrawn, "Already withdrawn");

        player.withdrawn = true;

        if (m.state == GameState.CANCELLED) {
            stakePool.refund(matchId, recipient, player.stableAmount);
        } else {
            stakePool.withdraw(matchId, recipient, player.stableAmount);
        }

        emit PrizeWithdrawn(matchId, recipient, player.stableAmount);
    }

    function autoRefundExpired(uint256 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(block.timestamp >= m.autoRefundTime, "Refund not ready");
        require(
            m.state != GameState.PAID_OUT && m.state != GameState.CANCELLED,
            "Already finalized"
        );

        for (uint256 i = 0; i < m.players.length; i++) {
            if (!m.players[i].withdrawn) {
                Player storage player = m.players[i];
                player.withdrawn = true;
                stakePool.refund(matchId, player.addr, player.stableAmount);
            }
        }

        m.state = GameState.CANCELLED;
        emit AutoRefundExecuted(matchId);
    }

  

    function getMatch(uint256 matchId) external view returns (
        GameState state,
        address[] memory playerAddrs,
        uint256[] memory stableAmounts,
        uint8[] memory wins,
        uint8 currentRound,
        address winner
    ) {
        Match storage m = matches[matchId];

        playerAddrs = new address[](m.players.length);
        stableAmounts = new uint256[](m.players.length);
        wins = new uint8[](m.players.length);

        for (uint256 i = 0; i < m.players.length; i++) {
            playerAddrs[i] = m.players[i].addr;
            stableAmounts[i] = m.players[i].stableAmount;
            wins[i] = m.players[i].wins;
        }

        return (m.state, playerAddrs, stableAmounts, wins, m.currentRound, m.winner);
    }

    function getBoard(uint256 matchId) external view returns (CellState[3][3] memory) {
        return matches[matchId].currentBoard.cells;
    }

    function getCurrentPlayer(uint256 matchId) external view returns (address) {
        Match storage m = matches[matchId];
        if (m.state != GameState.IN_PROGRESS) {
            return address(0);
        }
        return m.players[m.currentPlayerIndex].addr;
    }

    function getTimeRemaining(uint256 matchId) external view returns (uint256) {
        Match storage m = matches[matchId];
        if (m.state != GameState.IN_PROGRESS) {
            return 0;
        }
        uint256 elapsed = block.timestamp - m.lastMoveTime;
        if (elapsed >= MOVE_TIMEOUT) {
            return 0;
        }
        return MOVE_TIMEOUT - elapsed;
    }

    receive() external payable {}
}
