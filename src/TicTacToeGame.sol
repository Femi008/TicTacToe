
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
        uint8 lastRoundStarterIndex; // ADD THIS FIELD

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


    function setGameContract(address _gameContract) external onlyOwner {
        require(gameContract == address(0), "Already set");
        require(_gameContract != address(0), "Invalid address");
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

        // this state variable will hold the address of pricefeedmanager
        PriceFeedManager public priceFeedManager;

        //mapping ofaddress to amount of sponsored gas
        mapping(address => uint256) public sponsoredGasPool;


        // gas sponsored event takes in indexed sponsor and amount
        event GasSponsored(address indexed sponsor, uint256 amount);

        // gas used takes in indexed user and gas used and gas cost
        event GasUsed(address indexed user, uint256 gasUsed, uint256 gasCost);

        // Proceds batch withdrawals event takes in total successful and failed
        event BatchProcessed(uint256 total, uint256 successful, uint256 failed);

        // constrcutor initailize the stablecoin and pricfeedmanager address
        constructor(address _stablecoin, address _priceFeedManager) Ownable(msg.sender) {
            stablecoin = _stablecoin;
            priceFeedManager = PriceFeedManager(_priceFeedManager);
        }

        // sponsored gas takes in amount, the visibility is external

        function sponsorGas(uint256 amount) external {

            // safe transfer is used here
            IERC20(stablecoin).safeTransferFrom(msg.sender, address(this), amount);

            // amount is added to the mapping of sponsoredgas pool with msg.sender as the key
            sponsoredGasPool[msg.sender] += amount;

            // emit the event 
            emit GasSponsored(msg.sender, amount);
        }

        /// execute takes in game contract addrress, the matchId , the reciever address 
        // visibility is external 
        // can be called only by owner

        function executeWithdrawal(
            address gameContract,
            uint256 matchId,
            address recipient
        ) external onlyOwner {

            // this is a  solidity op-code helper that caputures amount of gas left at the point of 
            // execution
            // amount of gas left before the withdrawal function is called

            uint256 initialGas = gasleft();

            // from the game contract interface then use the execeute gasless withdrawal function
            ITicTacToeGame(gameContract).executeGaslessWithdrawal(matchId, recipient);

        // +21000  is the intrinsic base cost fo any etherum transaction
        // +9700 adds buffers for the cost of calldata and extra opcodes

        // gasLeft is how manny gas is left after the withdrawal fucntion is executed 

            uint256 gasUsed = initialGas - gasleft() + 21000 + 9700; 

        // tx.gasprice is a global variable that return price of gas in wei
        // for transacion being executed

        uint256 gasPrice = tx.gasprice;
        require(gasPrice > 0, "Invalid gas price");
        uint256 totalGasCostInEth = gasUsed * gasPrice;

        // here we convert the eth gas cost to stabel coin value 
            uint256 totalGasCostInStable = _convertEthToStable(totalGasCostInEth);

        // here the mapping of sponsored gas pool with recipient as the key must be 
        // greater than or equals to total gas cost

            require(
                sponsoredGasPool[recipient] >= totalGasCostInStable,
                "Insufficient sponsored gas"
            );

            // deduct the stable cost from the sponsored gas pool

            sponsoredGasPool[recipient] -= totalGasCostInStable;


            // here we emit the gas used event
            emit GasUsed(recipient, gasUsed, totalGasCostInStable);
        }


        // this is for batch withdrawals

        // it takes in game contract
        // list if ids 
        // list of recipients addresses
        // only owner could call it

        function executeBatchWithdrawals(
        address gameContract,
        uint256[] calldata matchIds,
        address[] calldata recipients
    ) external onlyOwner {

        // it is required to check if their count matches

        require(matchIds.length == recipients.length, "Mismatched arrays");

        // numvber of succesful withdrawals 
        uint256 successful = 0;

        // number of failed withdrawals
        uint256 failed = 0;

        // loop through the requested match ids
        for (uint256 i = 0; i < matchIds.length; i++) {
            // check if its address (0) then it fails and increment failed
            if (recipients[i] == address(0)) {
                failed++;
                // then move to the net request
                continue;
            }

            // try make us call external fucntions safely
            // if it succed it runs inside the try
            // it it fails it runs in the catch
            // this is current contract instance
            

            // so only add the ones that are successful
            // also increment the succesful withrawals
            // if catch then increase the failed too

            try this.executeWithdrawal(gameContract, matchIds[i], recipients[i]) {
                successful++;
            } catch {
                failed++;
            }
        }
        // emit event batch processed
        emit BatchProcessed(matchIds.length, successful, failed);
    }

        function _convertEthToStable(uint256 ethAmount) internal view returns (uint256) {
            // get usd value in 18 decimals 
            // from the state variable pricefeedmanager call getusdvalue 
            // and pass in the arguments 
            uint256 usd18 = priceFeedManager.getUsdValue(address(0), ethAmount);

            // using metdata of erc20 get the decimal of the address stablecoin
            uint8 stableDecimals = IERC20Metadata(stablecoin).decimals();

            // then normalize the stable deimals 
            return (usd18 * 10**stableDecimals) / 10**18;
        }
    }


    /// the contract for the tic tac toe game
    // the contract will inherit IticTactoe, reentrancyguard and ownable

    contract TicTacToeGame is ITicTacToeGame, ReentrancyGuard, Ownable {

        uint8 constant NO_WINNER = type(uint8).max;


        // using safe erc-20 to handle the error that dont return boolean

        using SafeERC20 for IERC20;

        uint256 public constant MIN_PLAYERS = 2;
        uint256 public constant MAX_PLAYERS = 2; // Enforce 2 players
        uint256 public constant MAX_ROUNDS = 5;
        uint256 public constant MOVE_TIMEOUT = 120; // 2 * 60 secs
        uint256 public constant MIN_STAKE_USD = 1 * 10**6; // e.g., USDC 6 decimals i.e $1
        uint256 public constant AUTO_REFUND_DELAY = 1 days; // 24 hrs is enough for refund

        //  this variable will hold the address of the AutomatedStakPool
        AutomatedStakePool public stakePool;

        // this variable will hold the address of the VRFCOnsumer
        VRFConsumer public vrfConsumer;

        // this variable will hold the address of the PriceFeedManager
        PriceFeedManager public priceFeedManager;

        // this variable will hold the address of the swapManager
        SwapManager public swapManager;

        // this variable will hold the address of the gaslessRelayer
        GaslessRelayer public gaslessRelayer;

        // this is the immutable address of the stablecoin
        address public immutable stablecoin;

        // this is the immutable address of the weth
        address public immutable weth;

        // match counter to generate unique match IDs
        uint256 public matchCounter;

        // mapping of Ids to Matches 
        mapping(uint256 => Match) public matches;

        // mapping of matchId (to a mapping of player address to boolean)
        mapping(uint256 => mapping(address => bool)) public hasJoined;

        // this should be able to track maych created 
        event MatchCreated(uint256 indexed matchId);

        // player that joined the game should have Id that is indexed
        // an indexed address and amount of stable deposited 

        event PlayerJoined(uint256 indexed matchId, address indexed player, uint256 stableAmount);

        // this will trcak the time the game started
        event GameStarted(uint256 indexed matchId);

        // this will track the first starter 
        event StarterSelected(uint256 indexed matchId, address indexed starter);

        // this will track the move made by player on the board

        event MoveMade(uint256 indexed matchId, address indexed player, uint8 x, uint8 y);

        // this will track the round won note we have 5 of them
        event RoundWon(uint256 indexed matchId, uint8 round, address indexed winner);

        // this will track the number of draws in each round
        event RoundDraw(uint256 indexed matchId, uint8 round);

        // this will track the winer selected 
        event WinnerSelected(uint256 indexed matchId, address indexed winner, uint256 totalAmount);

        // this will track the number of cancellation of match
        event MatchCancelled(uint256 indexed matchId);

        // this will track the prize withdrawn by the player
        event PrizeWithdrawn(uint256 indexed matchId, address indexed player, uint256 amount);

        // this will track the auto refunds
        event AutoRefundExecuted(uint256 indexed matchId);

        // this will track the timeout for each player
        event PlayerTimedOut(uint256 indexed matchId, address indexed player);

        // this will track the stake refunded
        event StakeRefunded(uint256 indexed matchId, address indexed player, uint256 amount);

    // this is the constructor for the tic tac toe game
    // pass in the address of the 5 of the them

    constructor(
        address _vrfConsumer,
        address _priceFeedManager,
        address _gaslessRelayer,
        address _stablecoin,
        address _swapRouter,
        address _weth
    ) Ownable(msg.sender) {
        // ✅ Validate all external addresses
        require(_vrfConsumer != address(0), "Invalid VRFConsumer address");
        require(_priceFeedManager != address(0), "Invalid PriceFeedManager address");
        require(_gaslessRelayer != address(0), "Invalid GaslessRelayer address");
        require(_stablecoin != address(0), "Invalid Stablecoin address");
        require(_swapRouter != address(0), "Invalid SwapRouter address");
        require(_weth != address(0), "Invalid WETH address");

        // ✅ Save stablecoin and wrapped ETH addresses
        stablecoin = _stablecoin;
        weth = _weth;

        // ✅ Deploy fresh AutomatedStakePool contract with this contract as owner
        stakePool = new AutomatedStakePool(_stablecoin, address(this));

        // ✅ Deploy SwapManager with relevant dependencies
        swapManager = new SwapManager(
            _swapRouter,
            _weth,
            _stablecoin,
            _priceFeedManager,
            address(this)
        );

        // ✅ Initialize external contract references
        vrfConsumer = VRFConsumer(_vrfConsumer);
        priceFeedManager = PriceFeedManager(_priceFeedManager);
        gaslessRelayer = GaslessRelayer(_gaslessRelayer);
    }


        // function ttracks how many matches have been created

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

        // this is to join the game with ETH i.e native ETH

        // there is re-enetrancy guard attached and payable to recieve ETH
        function joinGameWithETH(uint256 matchId) external payable nonReentrant {

            // this is a private fucntion that recieves 
            // matchId, native eth address and its value worth in wei
            _joinGame(matchId, address(0), msg.value);
        }

        // this is to join the game with ERC20 tokens
        // re-entrancy is attached and its has external visibility

        function joinGameWithToken(uint256 matchId, address token, uint256 amount)
            external
            nonReentrant
        {
            // it is required to check if the token is valid and not address(0)
            // i.e 0x000000

            require(token != address(0), "Use joinGameWithETH for ETH");

            // use safe token transfer from to handle the error that doesnt
            // return boolean 
            // safe transfer from will take in the token address, msg.sender address and amount
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

            // this is the private function that will handle the joining of the game
            // takes in matchId, erc20 token address and amount
            _joinGame(matchId, token, amount);
        }


        // this will handle the joinning of the game

        function _joinGame(uint256 matchId, address token, uint256 amount) internal {
        Match storage m = matches[matchId];

        require(m.state == GameState.OPEN, "Match not open");
        require(amount > 0, "Amount must be greater than 0"); // ADD THIS
        require(priceFeedManager.isTokenSupported(token), "Token not supported");
        require(!hasJoined[matchId][msg.sender], "Already joined");
        require(m.players.length < MAX_PLAYERS, "Match full");

        // stable amount
            uint256 stableAmount;
            // if the token is stablecoin then no need to swap
            if (token == stablecoin) {
                stableAmount = amount;
            } else {
                // if it is not invalid then
                if (token != address(0)) {
                    // use safetransfer to move the token to swapmanager
                    IERC20(token).safeTransfer(address(swapManager), amount);
                }

                // if it is the native eth address then
                if (token == address(0)) {
                    
                    // this will call swap to stable and pass in the value
                    // (token, amount) is the usaual arguments passed
                    // {value: amount} is the value in wei
                    stableAmount = swapManager.swapToStable{value: amount}(token, amount);
                } else {
                    stableAmount = swapManager.swapToStable(token, amount);
                }
            }

            // if the stable amount is less than $1 then revert
            require(stableAmount >= MIN_STAKE_USD, "Stake too low");


        // firstly set allowance to 0 then force approve the stake pool to spend the stable amount
            IERC20(stablecoin).forceApprove(address(stakePool), stableAmount);

            // dont forget the stakepool is the new contract deployed for autostakepool and we call 
            // deposit the player stake into a pool
            stakePool.depositStable(matchId, stableAmount);


            // since the m is set to be Match
            // then add new match to the Player array
            // jsut updating one field 

            // m is a refrence to matches[matchId]
            // let m add a new player to the players array

            m.players.push(Player({
                addr: msg.sender,
                stableAmount: stableAmount,
                wins: 0,
                withdrawn: false
            }));

            // update the total stable amount in the match
            m.totalStableAmount += stableAmount;
            
            // checks if player has joined
            hasJoined[matchId][msg.sender] = true;

            // emit the player joined event
            emit PlayerJoined(matchId, msg.sender, stableAmount);

        // check the minimum player to start the game 
        // must be greater than or equals to min players
            if (m.players.length >= MIN_PLAYERS) {

                // set he game state from Open to Staked
                m.state = GameState.STAKED;
            }
        }

        // start game visibility is external

    function startGame(uint256 matchId) external {
        Match storage m = matches[matchId];
        
        // Missing: Check if match was actually created
        require(m.createdAt > 0, "Match does not exist");
        require(m.state == GameState.STAKED, "Not ready");
        // ...

            // this state means its waiting for vrf response 
            // from the onchain co-ordinator

            m.state = GameState.VRF_PENDING;

            // from chainLink then request random word[1] in this case
            vrfConsumer.requestRandomWords(matchId);

            // then track with gate game started event
            emit GameStarted(matchId);
        }

        
        // this function is use to pass the call back
        // visibility is external 
        // takes in matchId and random number
        
    function handleVRFFulfillment(uint256 matchId, uint256 randomNumber) external {
        require(msg.sender == address(vrfConsumer), "Only VRF");

        Match storage m = matches[matchId];
        require(m.state == GameState.VRF_PENDING, "Invalid state");

        m.starterIndex = uint8(randomNumber % m.players.length);
        m.state = GameState.IN_PROGRESS;
        m.currentRound = 1;

        _initializeBoard(matchId);

        m.currentPlayerIndex = m.starterIndex;
        m.lastRoundStarterIndex = m.starterIndex; // INITIALIZE THIS
        m.lastMoveTime = block.timestamp;

        emit StarterSelected(matchId, m.players[m.starterIndex].addr);
    }

    
    // function to make a move on the board
    // visibility is external
        // where x and y are co-ordinates on the board
        
        function makeMove(uint256 matchId, uint8 x, uint8 y) external {
        Match storage m = matches[matchId];

        require(m.state == GameState.IN_PROGRESS, "Game not active");
        require(x < 3 && y < 3, "Invalid position");
        require(m.currentBoard.cells[x][y] == CellState.EMPTY, "Cell occupied");
        require(m.players[m.currentPlayerIndex].addr == msg.sender, "Not your turn");

        // Check timeout only if not the first move
        if (m.currentBoard.moveCount > 0) {
            require(block.timestamp - m.lastMoveTime <= MOVE_TIMEOUT, "Move timeout");
        }

        CellState playerCell = m.currentPlayerIndex == 0 ? CellState.PLAYER1 : CellState.PLAYER2;
        m.currentBoard.cells[x][y] = playerCell;
        m.currentBoard.moveCount++;
        m.lastMoveTime = block.timestamp;

        emit MoveMade(matchId, msg.sender, x, y);

        if (_checkWin(m.currentBoard, playerCell)) {
            m.players[m.currentPlayerIndex].wins++;
            emit RoundWon(matchId, m.currentRound, msg.sender);
            _nextRound(matchId, m.currentPlayerIndex);
            return;
        }

        if (m.currentBoard.moveCount == 9) {
            emit RoundDraw(matchId, m.currentRound);
            _nextRound(matchId, NO_WINNER); // Indicate draw
            return;
    }

        m.currentPlayerIndex = (m.currentPlayerIndex + 1) % 2;
    }
        // if opponet hits the time out you will automatically win

        function claimTimeoutWin(uint256 matchId) external {
        Match storage m = matches[matchId];

        // set the state open
        require(m.state == GameState.IN_PROGRESS, "Game not active");

        // make sure that player length is 2 
        require(m.players.length == 2, "Invalid match config");

        // block.timestamp is a global variabale 
        // lastmoveTime is the last recorded move time stored in Match Struct
        // move-time is the duration of the game

        // Only check timeout after first move
        require(m.currentBoard.moveCount > 0, "No moves made yet");
        require(block.timestamp - m.lastMoveTime > MOVE_TIMEOUT, "No timeout yet");

        // m.currentIndexPlayer is the next player
    // it alternate if Player(0) plays then index is 1

        uint8 opponentIndex = m.currentPlayerIndex;

        // store the player that made the winning move
    // 0 + 1 % 2 - 1
    // 1 + 1 % 2 - 0

    // the initial player index
        uint8 winnerIndex = (m.currentPlayerIndex + 1) % 2;
        

        // required that only winners can send 
        require(m.players[winnerIndex].addr == msg.sender, "Not eligible");

        // Prevent double claiming
        m.lastMoveTime = block.timestamp;

        // Update wins

        m.players[winnerIndex].wins++;

        // Emit events

        // pass in the matchId and opponet address
        emit PlayerTimedOut(matchId, m.players[opponentIndex].addr);

        // emit using the matchId, the current round and the senders address
        emit RoundWon(matchId, m.currentRound, msg.sender);

        // Advance round with the winner
        _nextRound(matchId, winnerIndex);
    }



    // this help us reset the board after a match
        function _initializeBoard(uint256 matchId) internal {

            // m is a pointer to onchain storage 
            Match storage m = matches[matchId];

            // loop over the 9 positions / cells 
            for (uint8 i = 0; i < 3; i++) {
                for (uint8 j = 0; j < 3; j++) {

                    // set each cell to empty
                    m.currentBoard.cells[i][j] = CellState.EMPTY;
                }
            }

            // set the move count to (0)
            m.currentBoard.moveCount = 0;
        }

        // this is a function that advance the game to next round 
        // or ends the game when the round is completed 



    function _nextRound(uint256 matchId, uint8 lastWinnerIndex) internal {
        Match storage m = matches[matchId];

        // End match if max rounds reached
        if (m.currentRound >= MAX_ROUNDS) {
            _selectWinner(matchId);
            return;
        }

        // Advance round
        m.currentRound++;

        // Reset board
        _initializeBoard(matchId);

        uint8 starter;

        if (lastWinnerIndex == NO_WINNER) {
            // Previous round was a draw → switch starter
            starter = uint8((m.lastRoundStarterIndex + 1) % m.players.length);
        } else if (m.currentRound == 2) {
            // Special case: first advancement from round 1
            if (lastWinnerIndex == m.starterIndex) {
                starter = uint8((m.starterIndex + 1) % m.players.length);
            } else {
                starter = lastWinnerIndex;
            }
        } else {
            // Rounds 3+ follow usual winner/alternate logic
            if (lastWinnerIndex == m.lastRoundStarterIndex) {
                // Winner already started last round → switch
                starter = uint8((m.lastRoundStarterIndex + 1) % m.players.length);
            } else {
                // Winner did not start → winner starts
                starter = lastWinnerIndex;
            }
        }

        // Update state
        m.currentPlayerIndex = starter;
        m.lastRoundStarterIndex = starter;
        m.lastMoveTime = block.timestamp;
    }




        function _checkWin(Board storage board, CellState player) internal view returns (bool) {
            // this is for the horizontal row
            for (uint8 i = 0; i < 3; i++) {
                if (board.cells[i][0] == player && board.cells[i][1] == player && board.cells[i][2] == player) {
                    return true;
                }
            }

            // for the vertical row 
            for (uint8 j = 0; j < 3; j++) {
                if (board.cells[0][j] == player && board.cells[1][j] == player && board.cells[2][j] == player) {
                    return true;
                }
            }

            // for diagonal top left to bottom right
            if (board.cells[0][0] == player && board.cells[1][1] == player && board.cells[2][2] == player) {
                return true;
            }

            // diagonal top right to top buttom
            if (board.cells[0][2] == player && board.cells[1][1] == player && board.cells[2][0] == player) {
                return true;
            }

            return false;
        }

    /// selects winner func

    function _selectWinner(uint256 matchId) internal {
        Match storage m = matches[matchId];

        // tracks the highest number of wins
        uint8 maxWins = 0;

        // keeps stores player-index with most win
        uint256 winnerIndex = 0;

        // Find max wins

        // loop through the players 
        for (uint256 i = 0; i < m.players.length; i++) {

            // if any player wins is greater than maxwin
            if (m.players[i].wins > maxWins) {

                // then set the player to maxwins
                maxWins = m.players[i].wins;

                // winner index now holds the refrence to the player with most wins
                winnerIndex = i;
            }
        }

        // Tie-breaker: higher stableAmount

        // loop through all the players
        uint256 playerCount = m.players.length;
        for (uint256 i = 0; i < playerCount; i++) {
            // Saves gas on each iteration
            if (

                // if multiple players has same wins number then use the stable amount
                // as a tie-breaker
                m.players[i].wins == maxWins &&
                m.players[i].stableAmount > m.players[winnerIndex].stableAmount
            ) {

                // now winnerindex holds the refrence to the player that won
                winnerIndex = i;
            }
        }

        // if no player won match will be cancelled 
        // all players get refunded their stables 
        if (maxWins == 0) {
            m.state = GameState.CANCELLED;

            uint256 playerCount = m.players.length;
            for (uint256 i = 0; i < playerCount; i++) {
                // Saves gas on each iteration
                if (!m.players[i].withdrawn) {
                    m.players[i].withdrawn = true;
                    stakePool.refund(
                        matchId,
                        m.players[i].addr,
                        m.players[i].stableAmount
                    );
                }
            }

            // emit match cancelled
            emit MatchCancelled(matchId);
            return;
        }

        // Winner exists, set the winners address
        m.winner = m.players[winnerIndex].addr;

        // set the game state to finished
        m.state = GameState.FINISHED;

        // emit the winnerSelected using matchId, winners address and amount
        emit WinnerSelected(matchId, m.winner, m.totalStableAmount);
    }


    function withdrawPrize(uint256 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(m.state == GameState.FINISHED, "Game not finished");
        require(msg.sender == m.winner, "Not winner");

        uint256 totalPrize;
        for (uint256 i = 0; i < m.players.length; i++) {
            Player storage player = m.players[i];
            if (!player.withdrawn) {
                player.withdrawn = true;
                totalPrize += player.stableAmount;
            }
        }

        require(totalPrize > 0, "Nothing to withdraw");

        // Update state BEFORE external call
        m.state = GameState.PAID_OUT; // ⚠️ This happens even if withdrawal fails

        stakePool.withdraw(matchId, m.winner, totalPrize);

        emit PrizeWithdrawn(matchId, m.winner, totalPrize);
    }


        // with draws the stable stake

    
    
    function withdrawMyStake(uint256 matchId) external nonReentrant {
        Match storage m = matches[matchId];


        // required that game is finished or camcelled
        require(
            m.state == GameState.FINISHED || m.state == GameState.CANCELLED,
            "Game not finished"
        );

        // Find player index
        uint256 playerIndex = type(uint256).max;

        // loop through the player lenghth and set p
        for (uint256 i = 0; i < m.players.length; i++) {

            // check if the stored address is the same as the senders address
            if (m.players[i].addr == msg.sender) {

                // saves the position of the player in that array
                playerIndex = i;

                // stop the position if the player is found
                break;
            }
        }

        // check again if caller is one of the player of the match
        require(playerIndex != type(uint256).max, "Not a player");


        // creates a reference to the player inside the Match Struct
        Player storage player = m.players[playerIndex];

        // required that player has not withdrawn
        require(!player.withdrawn, "Already withdrawn");

        // if the game state is cancelled
        if (m.state == GameState.CANCELLED) {
            // Everyone gets a refund
            player.withdrawn = true;
            stakePool.refund(matchId, msg.sender, player.stableAmount);

            emit StakeRefunded(matchId, msg.sender, player.stableAmount);
            return;
        }

        // Game finished → only winner can withdraw
        require(msg.sender == m.winner, "Only winner can withdraw");

        player.withdrawn = true;
        stakePool.withdraw(matchId, msg.sender, player.stableAmount);

        emit PrizeWithdrawn(matchId, msg.sender, player.stableAmount);
    }



    function executeGaslessWithdrawal(
        uint256 matchId,
        address recipient
    ) external nonReentrant {
        Match storage m = matches[matchId];

        // Access control - only relayer can call this
        require(msg.sender == address(gaslessRelayer), "Only relayer");

        require(
            m.state == GameState.FINISHED || m.state == GameState.CANCELLED,
            "Game not finished"
        );

        // Find player
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

        // For finished games, only winner can withdraw
        if (m.state == GameState.FINISHED) {
            require(recipient == m.winner, "Only winner");
        }

        player.withdrawn = true;
        uint256 amount = player.stableAmount;

        if (m.state == GameState.CANCELLED) {
            stakePool.refund(matchId, recipient, amount);
            emit StakeRefunded(matchId, recipient, amount);
        } else {
            stakePool.withdraw(matchId, recipient, amount);
            emit PrizeWithdrawn(matchId, recipient, amount);
        }
    }

    function autoRefundExpired(uint256 matchId) external nonReentrant {
        Match storage m = matches[matchId];

        require(block.timestamp >= m.autoRefundTime, "Refund not ready");
        require(
            m.state != GameState.PAID_OUT && m.state != GameState.CANCELLED,
            "Already finalized"
        );
        
        // Refund all players
        for (uint256 i = 0; i < m.players.length; i++) {
            if (!m.players[i].withdrawn) {
                Player storage player = m.players[i];
                player.withdrawn = true;
                stakePool.refund(matchId, player.addr, player.stableAmount);
                emit StakeRefunded(matchId, player.addr, player.stableAmount); // ADD EVENT
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

            uint256 playerCount = m.players.length;
            for (uint256 i = 0; i < playerCount; i++) {
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