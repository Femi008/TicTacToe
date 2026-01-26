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


// game state
enum GameState {
    OPEN,
    STAKED,
    VRF_PENDING,
    IN_PROGRESS,
    FINISHED,
    PAID_OUT,
    CANCELLED
}

// the board is occupied by player1 or player2 or empty
// enum is a set of named constants
enum CellState {
    EMPTY,
    PLAYER1,
    PLAYER2
}

// struct is a way to group related items into one composite function
struct Player {
    address addr;
    uint256 stableAmount;
    uint8 wins;
    bool withdrawn;
}

// movecount tracks the movement of the 3x3 board 
struct Board {
    CellState[3][3] cells;
    uint8 moveCount;
}

// tracks everything about the match
struct Match {
    GameState state; // enum tracking the game state
    Player[] players; // struct of players
    uint8 currentRound; // which round is the game at the time
    uint256 totalStableAmount; // total amount of stables deposited
    uint8 starterIndex; // player that starts the game
    address winner; // player tracks both round and game winners
    uint256 createdAt; // time
    Board currentBoard; // keeps track of the current positiosn
    uint8 currentPlayerIndex; // maps the position to player0 or player1 or empty
    uint256 lastMoveTime; // records time the last move was made 
    uint256 autoRefundTime; // dealine for refund
}


// this is the interface for Ierc20 but additional functio decimals is added
interface IERC20Metadata is IERC20 {
    function decimals() external view returns (uint8);
}


// this is uniswap Router v3 interface
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

    // here we are passing the struct into the fucntion
    // call data is telling us the function will be passed in from external call
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

// payable mark a funtion able to recieve ETH
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// interface defines eternal contracts without implementation
interface ITicTacToeGame {
    // this is the callback fucnction that delivers the random number back to the contract
    function handleVRFFulfillment(uint256 matchId, uint256 randomNumber) external;
    // allows players to withdraw wins without paying for gas fees themselves
    function executeGaslessWithdrawal(uint256 matchId, address recipient) external;
}


// This is the PriceManager controls the price feeds and its inherit ownable
contract PriceFeedManager is Ownable {
    // extending the traditional erc-20 functions with SafeErc-20
    using SafeERC20 for IERC20;
    
    // mapping of token address to chainLink address
    mapping(address => address) public priceFeeds;
    // a list or array of supported tokens 
    address[] public supportedTokens;
    // a mapping of supported token address to boolean either true or false
    mapping(address => bool) public isTokenSupported;
    
    // log events so external dapps can picks it up
    event TokenAdded(address indexed token, address indexed priceFeed);
    event TokenRemoved(address indexed token);

    // Ownable inherited is used here and te deployer address is passed into here
    constructor() Ownable(msg.sender) {
        // since Native Eth is not supported then we push Address(0) 
        supportedTokens.push(address(0));
        // this is to check if native eth is now part of the supported token address
        isTokenSupported[address(0)] = true;
    }

    // when we are about to add tokens we need the token address and the price feed address
    // only owner could add token to prevent malicious token added to the supported list

    function addToken(address token, address priceFeed) external onlyOwner {
        // it is required to check if the token is suportted where token is the key
        require(!isTokenSupported[token], "Token already supported");
        // it is required to check if token is not invalid 
        require(priceFeed != address(0), "Invalid price feed");
    
        // here we specify the key to the mapping pricefeeds
        priceFeeds[token] = priceFeed;
        // here we push the supported er20 token
        supportedTokens.push(token);
        // we double check if its added or not
        isTokenSupported[token] = true;
        // we emit the token added for external dapps and front end
        emit TokenAdded(token, priceFeed);
    }

// when we are about to discard token we only need the address and also restricted from everyone
    function removeToken(address token) external onlyOwner {
        // its is importan to check if its is native ETH, because we cant remove it
        require(token != address(0), "Cannot remove ETH");
        // here we check if supported token list exist using the key "token"
        require(isTokenSupported[token], "Token not supported");
    // here we set the confirmed supported token to be false 
        isTokenSupported[token] = false;
        // we then set the pricefeed to default
        delete priceFeeds[token];
    // we emit the removal of the token
        emit TokenRemoved(token);
    }

// use for fetching the price of each tokens, it is public and could be accessed by anyone
    function getPrice(address token) public view returns (uint256) {
        // it is required to check if the token mapping exist
        require(isTokenSupported[token], "Token not supported");
    // then set price feed mapping to be variable feed with type address
        address feed = priceFeeds[token];
        // if feed is invalid then stop execution immediately
        require(feed != address(0), "No price feed configured");

    // using a wrapper function, wrap the feed by aggregatorInterface 
    // and set the variable name to be priceFeed
        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        // from priceFeed get latetsRound Data and return price and updatedtime
        (, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();

    // check if price > 0 
    // check if updatedtime > last 1 hr blockstamp
        require(price > 0, "Invalid price");
        require(updatedAt > block.timestamp - 1 hours, "Stale price");

        return uint256(price);
    }

    // get the decimals for native eth / erc20- tokens
    // takes in address and its a view 
    function getPriceDecimals(address token) public view returns (uint8) {
        // feed  is a local variable
        address feed = priceFeeds[token];

        require(feed != address(0), "No price feed configured");
        // return the decimals of the feed inputed into aggregatorV3
        // cast the address into chainlink interface
        return AggregatorV3Interface(feed).decimals();
    }

    // Returns USD value in 18 decimals
    // getusdvalue takes in token address and amount its public 
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        uint256 price = getPrice(token);      // price in priceDecimals
        //pass in the token address into get decimals function
        uint8 priceDecimals = getPriceDecimals(token);

    // if the token is native ETH return 18 decimals 
        uint8 tokenDecimals = token == address(0)
        // tentary opreator used here
        // else
        // call the ecr-20 decimals functions
            ? 18
            : IERC20Metadata(token).decimals();

        // here we scale to common
        // Normalize to 18-decimals USD:
        // amount (tokenDecimals) * price (priceDecimals) / 10^(tokenDecimals + priceDecimals) * 10^18
        uint256 usd18 = (amount * price * 10**18) / (10**tokenDecimals * 10**priceDecimals);
        return usd18;
    }

    // this is a getter function that returns list of address that are temporary
    function getSupportedTokens() external view returns (address[] memory) {
        return supportedTokens;
    }

    // this is a setter function that sets the price-feed of ETH

    function setEthPriceFeed(address priceFeed) external onlyOwner {
        // set the pricefeed as a mapping with address zero as the key
        priceFeeds[address(0)] = priceFeed;
    }
}


// contract for swap managers

contract SwapManager {
    using SafeERC20 for IERC20;

    // interface for uniswap router
    // interface IswapRouter will hold the daddress of a contract that implements the interface
    ISwapRouter public immutable swapRouter;
    // interface for wrapped ETHer 
    // this variable will hold the address of a contract that implement the WETH interface
    IWETH public immutable weth;
    // address for the stablecoin
    address public immutable stablecoin;
    // address for the game contract
    address public immutable gameContract;
    // this is the UNiswap fee and its tiered this is 0,3%
    uint24 public constant poolFee = 3000;

    // the priceManager varaiable will hold the address of PriceFeedmanager
    PriceFeedManager public priceFeedManager;

    // this invent will take in the token its amount and amount to be swapped out
    event TokenSwapped(address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    // modifiers are reusable piece of logic that can be attached to fucntions
    // it runs before the function body executes
    // it checks if the msg.sender equals to gamecontract
    // _; is a place holder if its passes the rest of the body exceutes
    modifier onlyGame() {
        require(msg.sender == gameContract, "Only game contract");
        _;
    }

    // initialize the state varaibles
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

    // swap to stable function will tak in the address of the token and amount 
    // marked payable to recieve ETH/ wETH
    // only game only this contract have acces to this.

    function swapToStable(address tokenIn, uint256 amountIn)
        external
        payable
        onlyGame
        returns (uint256 amountOut)
    {

        // check if tokenIn is a stable or not to avoid wasting gas fees 
        if (tokenIn == stablecoin) {
            // return the amount 
            return amountIn;
        }
        // here we calculate the minimum amout that should be acceptable otherwise revert
        uint256 minAmountOut = _calculateMinAmountOut(tokenIn, amountIn);

        // here is tokenIn is native ETH then
        if (tokenIn == address(0)) {
            // from weth call the deposit and pass the amount
            // and swap the weth to eth

            weth.deposit{value: amountIn}();
            
            // call the weth erc20 approve function and allow the contract to spend amount in
            weth.approve(address(swapRouter), amountIn);

            // IswapRouter.ExactInputSingleParams is the uniswap V3 router interface
            // memeory we are storing it tempo storage

            // params is the local variable it will hold all the importants inputs

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(weth),
                tokenOut: stablecoin,
                fee: poolFee,
                recipient: gameContract,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

        // swapRouter is a state variable that holds the address of the router
        // pass in the params
            amountOut = swapRouter.exactInputSingle(params);
        } else {
            // if is not native ETH then use the metadata for erc20 for it

            // using safeApprove force it to accept the router address and amountIn
            // while taking in the token address

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

    // using 1% slippage buffer
    // this is also a private function
    function _calculateMinAmountOut(address tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        // from contract PricFeedManager getusdValue and pass in token address and amount
        // 
        uint256 usdValue18 = priceFeedManager.getUsdValue(tokenIn, amountIn);

        // get the decimals of the stable token from Ierc-20 metadata
        uint8 stableDecimals = IERC20Metadata(stablecoin).decimals();


        // calculate the mininumOut 
        // normalizing the decimal placements
        uint256 minAmountOut = (usdValue18 * 99 * 10**stableDecimals) / (100 * 10**18);
        return minAmountOut;
    }

    // this is a special fall back function 
    // it allows the contract to receive ETH directly
    receive() external payable {}
}


// automating the stake pool
contract AutomatedStakePool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // address of the stablecoin is immutable
    address public immutable stablecoin;

    // address of the contract is imutable too
    address public immutable gameContract;

    // mapping of matchId to Stale Balances
    mapping(uint256 => uint256) public matchStableBalances;

    // protocol fee is 2%
    uint256 public protocolFeePercent = 2;

    // total fee accumulated so far
    uint256 public accumulatedFees;

    // events that handles

    // stable deposited 
    // stable withdrawn
    // fees withdrawn
    event StableDeposited(uint256 indexed matchId, address indexed player, uint256 amount);
    event StableWithdrawn(uint256 indexed matchId, address indexed recipient, uint256 amount);
    event FeesWithdrawn(address indexed recipient, uint256 amount);

    // modifier are reusable piece of logic that can be attached to fucntions
    // they can run before the fucntion body run

    modifier onlyGame() {
        require(msg.sender == gameContract, "Only game contract");
        _;
    }

    // the constructor takes in stablecoin address and game contract address
    // it will inherit ownable and deployers address is passed in

    constructor(address _stablecoin, address _gameContract) Ownable(msg.sender) {
        stablecoin = _stablecoin;
        gameContract = _gameContract;
    }

    // is used to deposit stables into the game
    // it takes in the matchId and amount of stables deposited
    // onlygame modifier is attached making sure only the game contract can call it

    function depositStable(uint256 matchId, uint256 amount) external onlyGame {

        // this will update the mapping of the balance by adding the deposited stables
        matchStableBalances[matchId] += amount;

        // and this will emit for external dapp
        emit StableDeposited(matchId, msg.sender, amount);
    }

    // function to withdraw 

// to withdraw we need the Matchid input, recipient and amount
// has a modifier attached to
// has re-entrancy guard 
    function withdraw(
        uint256 matchId,
        address recipient,
        uint256 amount
    ) external onlyGame nonReentrant returns (uint256 payout) {
        // it is required to check if the mapping of matchststablesbalance 
        // with matchid as key is greater than amount or equals to the amount

        require(matchStableBalances[matchId] >= amount, "Insufficient balance");

        // deduct the match winnings from the matchBalances
        matchStableBalances[matchId] -= amount;

        // calculate the protocol fees 
        uint256 fee = (amount * protocolFeePercent) / 100;

        // payout for the winner
        payout = amount - fee;


        // total accumulated fees 
        accumulatedFees += fee;

        // then use safe transfer to handle the payout
        IERC20(stablecoin).safeTransfer(recipient, payout);

        // broadcasts the withdrawal on chain
        emit StableWithdrawn(matchId, recipient, payout);

        // returns the winners payout
        return payout;
    }

// fucntion handling refund

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

// only owner could withdraw fees 
// uses re-entracy guard
    function withdrawFees() external onlyOwner nonReentrant {
        // fees is the total accumulated fees
        uint256 fees = accumulatedFees;
        // fees must be greater than 0
        require(fees > 0, "No fees");

        // withdraw all at once that why it could be set to 0
        accumulatedFees = 0;

        // then using safe transfer to handle the error
        IERC20(stablecoin).safeTransfer(owner(), fees);

        emit FeesWithdrawn(owner(), fees);
    }
}

// the vrf consumer contract 

contract VRFConsumer is VRFConsumerBaseV2Plus {
    // co-ordinator will hold the functions of IVRFCoordinatorV2PLus
    IVRFCoordinatorV2Plus immutable COORDINATOR;

    //
     
    uint256 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 200000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;


    // mapping of requestId to MatchId
    mapping(uint256 => uint256) public requestIdToMatchId;

    // mapping of MatchId to RandomNumber
    mapping(uint256 => uint256) public matchIdToRandomNumber;

    // state varaible called gamecontracts
    address public gameContract;

    // triggred when we request randomness
    event RandomnessRequested(uint256 indexed matchId, uint256 requestId);

    // triggred when we fufil randomness
    event RandomnessFulfilled(uint256 indexed matchId, uint256 randomNumber);

    constructor(
        // takes in this
        uint256 _subscriptionId,
        address _vrfCoordinator,
        bytes32 _keyHash
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        // pass them out 
        COORDINATOR = IVRFCoordinatorV2Plus(_vrfCoordinator);
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
    }


// pass in the game contract address
    function setGameContract(address _gameContract) external {
        // its is required to check if the game contract is address(0) or not
        require(gameContract == address(0), "Already set");

        // hence pass the holds the deployed contract address
        gameContract = _gameContract;
    }

// fucntion to request random words 
    function requestRandomWords(uint256 matchId) external returns (uint256) {

        // required that the senders address is the game contract
        require(msg.sender == gameContract, "Only game contract");

// from the immutable state varaibale pick the requestRandomwords
        uint256 requestId = COORDINATOR.requestRandomWords(
            // VRFV2PLus help us format request and reponses

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

        // set the mapping with requestId as key to be matchId
        requestIdToMatchId[requestId] = matchId;

        // emeit the event
        emit RandomnessRequested(matchId, requestId);
        return requestId;
    }


    // this is the function for fufilRandom words
    // 
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        // this is a mapping of requestId to MatchId with requestid as the key
        uint256 matchId = requestIdToMatchId[requestId];

        // create a variable matchId of type unit256

        // the first random number returned will be stored in the mapping
        matchIdToRandomNumber[matchId] = randomWords[0];

        // emit allows us to track this matchid and first random word

        emit RandomnessFulfilled(matchId, randomWords[0]);

        // this call into the game contract and pass in the matchId and first random words
        ITicTacToeGame(gameContract).handleVRFFulfillment(matchId, randomWords[0]);
    }
}

// this is gasless Relayer it inherit ownble
contract GaslessRelayer is Ownable {
    // extending the capabilities of erc20 with safe-erc20
    using SafeERC20 for IERC20;

    // stablecoin address is immutable
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