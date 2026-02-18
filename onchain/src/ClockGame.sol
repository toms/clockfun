// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*************************************************************

 /$$$$$$$$ /$$$$$$  /$$$$$$  /$$   /$$ /$$$$$$$$ /$$$$$$$ 
|__  $$__/|_  $$_/ /$$__  $$| $$  /$$/| $$_____/| $$__  $$
   | $$     | $$  | $$  \__/| $$ /$$/ | $$      | $$  \ $$
   | $$     | $$  | $$      | $$$$$/  | $$$$$   | $$$$$$$/
   | $$     | $$  | $$      | $$  $$  | $$__/   | $$__  $$
   | $$     | $$  | $$    $$| $$\  $$ | $$      | $$  \ $$
   | $$    /$$$$$$|  $$$$$$/| $$ \  $$| $$$$$$$$| $$  | $$
   |__/   |______/ \______/ |__/  \__/|________/|__/  |__/

                _________________________
              ,'        ______            `.
            ,'       _.'______`._           `.
            :       .'.-'  12 `-.`.           \
            |      /,' 11  .   1 `.\           :
            ;     // 10    |     2 \\          |
          ,'     ::        |        ::         |
        ,'       || 9   ---O      3 ||         |
      /          ::                 ;;         |
      :           \\ 8           4 //          |
      |            \`. 7       5 ,'/           |
      |             '.`-.__6__.-'.'            |
      :               `-.____.-'`              ;
      \                                      /
        `.       "When will it end?"        ,'
          `.______________________________,'
              ,-.
              `-'
                O
                  o
                  .     ____________
                  ,('`)./____________`-.-,|
                |'-----\\--------------| |
                |_______^______________|,|
                |                      |                   

                        made with love
                          by t0m.eth

*************************************************************/


import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { VRFConsumerBaseV2Plus } from "@chainlink/contracts/src/v0.8/dev/vrf/VRFConsumerBaseV2Plus.sol";
import { VRFV2PlusClient } from "@chainlink/contracts/src/v0.8/dev/vrf/libraries/VRFV2PlusClient.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import { IClockGame } from "./IClockGame.sol";
import { IClockGameMechanics } from "./IClockGameMechanics.sol";

contract ClockGame is IClockGame, VRFConsumerBaseV2Plus, ReentrancyGuard, AccessControl {
  // access control roles
  bytes32 public constant GAME_OPERATOR_ROLE = keccak256("GAME_OPERATOR_ROLE");
  bytes32 public constant VRF_OPERATOR_ROLE = keccak256("VRF_OPERATOR_ROLE");  
  bytes32 public constant VRF_CLAIMER_ROLE = keccak256("VRF_CLAIMER_ROLE");
  bytes32 public constant AUTHORIZATION_ADMIN_ROLE = keccak256("AUTHORIZATION_ADMIN_ROLE");
  bytes32 public constant EMERGENCY_MIGRATOR_ROLE = keccak256("EMERGENCY_MIGRATOR_ROLE");

  // fee
  uint256 public constant COUNTDOWN_POOL_FEE_BPS = 4_000; // 4%
  uint256 public constant JACKPOT_POOL_FEE_BPS = 5_000; // 5%
  uint256 public constant CREATOR_FEE_BPS = 1_000; // 1%

  // countdown parameters
  uint256 public constant MAX_RECENT_BUYERS = 50;
  uint256 public constant PRECISION_DENOMINATOR = 10_000_000;
  uint256 public constant REWARD_SCALAR = 10_000_000;

  // chainlink vrf configuration
  ClockVrfConfig public vrfConfig;
  uint32 public constant VRF_NUM_WORDS = 1;
  uint256 public constant VRF_LOCK_TIMEOUT = 1 minutes;

  struct PendingBuy {
    address buyer;
    uint256 buyAmount; // total swap amount (swap + tax + vrf fee)
    uint256 roundId;
    bool fulfilled;
  }

  struct Buyers {
    uint256 unfulfilledVrfCount;
    uint256 lastUnfulfilledVrfTimestamp;
  }

  struct Round {
    uint64 id;
    uint256 startTimestamp;
    uint256 endTimestamp;
    uint256 countdownPoolBalance;
    uint8 rbHead;
    uint8 rbCount;
    address[MAX_RECENT_BUYERS] recentBuyers;
    bool ended;
  }

  enum DonatePool { Countdown, Jackpot, Creator }

  mapping(uint256 => Round) public rounds; // roundId => Round
  mapping(uint256 => PendingBuy) public pendingBuys; // requestId => PendingBuy
  mapping(address => Buyers) public buyers; // buyerAddress => Buyers
  mapping(address => uint256) public playerBalances; // claimable balances
  mapping(address => bool) public authorizedCallers; // addresses that can call handleBuy
  
  uint256 public currentRoundId;
  uint256 public buyerNonce;
  uint256 public buySequence;
  bool public gameStarted;

  PoolKey public clockPool;
  ERC20 public clockToken;

  address public creator;
  address public pendingCreator;

  uint256 public creatorFeeBalance;
  uint256 public jackpotPoolBalance;

  uint256 public vrfFeeAmount = 0.000001 ether;
  uint256 public vrfFeeBalance; // accumulated VRF fees in WETH

  address public gameMechanics;

  event BuyInitiated(
    uint256 indexed buySequence,
    uint256 vrfRequestId,
    uint256 roundId,
    address buyerAddress,
    uint256 buyAmount,
    uint256 tokenAmount,
    uint256 taxAmount,
    uint256 creatorFeeDelta,
    uint256 countdownPoolDelta,
    uint256 jackpotPoolDelta,
    uint256 newEndTimestamp,
    uint256 optionalBuyerNonce,
    bool isRoundEnded
  );
  event VRFResultProcessed(
    uint256 indexed vrfRequestId,
    uint256 roundId,
    address buyerAddress,
    uint256 timeDelta,
    uint256 newEndTimestamp,
    uint256 jackpotAmountWon,
    uint256 activityNonce,
    uint256 extensionChancePpm,
    uint256 jackpotChancePPM
  );
  event RoundEnded(
    uint256 indexed roundId,
    uint256 startTimestamp,
    uint256 endTimestamp,
    uint256 countdownPoolBalance,
    uint256 jackpotPoolBalance
  );
  event PlayerBalanceClaimed(address indexed player, uint256 amount);
  event Donation(address indexed donor, DonatePool pool, uint256 amount, uint256 roundId);
  event CreatorFeesClaimed(address indexed creator, uint256 amount);
  event CreatorTransferred(address indexed previousCreator, address indexed newCreator);
  event CreatorTransferProposed(address indexed currentCreator, address indexed proposedCreator);
  event CreatorTransferCancelled(address indexed currentCreator, address indexed cancelledCreator);
  event AuthorizedCallerUpdated(address indexed caller, bool authorized);
  event VrfFeesWithdrawn(address indexed owner, uint256 amount);
  event GameStarted(uint256 timestamp);
  event GameMechanicsUpdated(address indexed previousMechanics, address indexed newMechanics);
  event VRFFeeAmountUpdated(uint256 oldAmount, uint256 newAmount);
  event EmergencyPoolMigration(address indexed migrator, uint256 countdownPoolBalance, uint256 jackpotPoolBalance, uint256 creatorFeeBalance, uint256 vrfFeeBalance);
  event VRFConfigUpdated(uint256 vrfSubscriptionId, bytes32 vrfKeyHash, uint32 vrfCallbackGasLimit, uint16 vrfRequestConfirmations);

  modifier onlyAuthorizedCaller() {
    require(authorizedCallers[msg.sender], "Caller not authorized");
    _;
  }

  modifier roundTimerExpired(uint256 roundId) {
    require(block.timestamp >= rounds[roundId].endTimestamp && rounds[roundId].endTimestamp != 0, "Round has not ended");
    _;
  }

  modifier onlyCreator() {
    require(msg.sender == creator, "Caller is not creator");
    _;
  }

  modifier requiresGameMechanics() {
    require(gameMechanics != address(0), "Game mechanics not set");
    _;
  }

  constructor(
    PoolKey memory _clockPool,
    ERC20 _clockToken,
    address _vrfCoordinator,
    uint256 _vrfSubscriptionId,
    bytes32 _vrfKeyHash,
    uint32 _vrfCallbackGasLimit,
    uint16 _vrfRequestConfirmations,
    address _creator,
    address _bondingCurve,
    address _clockHook,
    address _gameMechanics
  ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
    clockPool = _clockPool;
    clockToken = _clockToken;
    vrfConfig = ClockVrfConfig({
      vrfSubscriptionId: _vrfSubscriptionId,
      vrfKeyHash: _vrfKeyHash,
      vrfCallbackGasLimit: _vrfCallbackGasLimit,
      vrfRequestConfirmations: _vrfRequestConfirmations
    });
    gameMechanics = _gameMechanics;
    require(_creator != address(0), "Creator cannot be zero");
    require(_gameMechanics != address(0), "Game mechanics cannot be zero");
    
    rounds[currentRoundId].id = uint64(currentRoundId);
    creator = _creator;
    
    // Set authorized callers for handleBuy
    if (_bondingCurve != address(0)) {
      authorizedCallers[_bondingCurve] = true;
      emit AuthorizedCallerUpdated(_bondingCurve, true);
    }
    if (_clockHook != address(0)) {
      authorizedCallers[_clockHook] = true;
      emit AuthorizedCallerUpdated(_clockHook, true);
    }

    address deployer = msg.sender;

    _grantRole(DEFAULT_ADMIN_ROLE, deployer);
    _grantRole(GAME_OPERATOR_ROLE, deployer);
    _grantRole(VRF_OPERATOR_ROLE, deployer);
    _grantRole(VRF_CLAIMER_ROLE, deployer);
    _grantRole(AUTHORIZATION_ADMIN_ROLE, deployer);
    _grantRole(EMERGENCY_MIGRATOR_ROLE, deployer);
  }

  // Accept ETH from WETH unwrapping
  receive() external payable {}

  // called only once by the bonding curve to start the game
  function startGame() external onlyAuthorizedCaller {
    require(!gameStarted, "Game already started");
    gameStarted = true;
    rounds[currentRoundId].startTimestamp = block.timestamp;
    rounds[currentRoundId].endTimestamp = block.timestamp + _getRoundLength();
    emit GameStarted(block.timestamp);
  }

  function _getRoundLength() internal view requiresGameMechanics returns (uint256) {
    return IClockGameMechanics(gameMechanics).getRoundLength();
  }

  function calculateExtensionProbabilityPPM(uint256 buyAmount, uint256 poolBalance) public view requiresGameMechanics returns (uint256) {
    return IClockGameMechanics(gameMechanics).calculateExtensionProbabilityPPM(buyAmount, poolBalance);
  }
  
  function calculateTimeDelta() internal view requiresGameMechanics returns (uint256) {
    return IClockGameMechanics(gameMechanics).calculateTimeDelta(rounds[currentRoundId].endTimestamp, block.timestamp);
  }

  function getJackpotOddsPPM(uint256 buyWei, uint256 poolBalanceWei) public view requiresGameMechanics returns (uint256) {
    return IClockGameMechanics(gameMechanics).getJackpotOddsPPM(buyWei, poolBalanceWei);
  }

  function _recordBuyer(address buyer) internal {
    rounds[currentRoundId].recentBuyers[rounds[currentRoundId].rbHead] = buyer;
    unchecked {
      rounds[currentRoundId].rbHead = uint8((rounds[currentRoundId].rbHead + 1) % MAX_RECENT_BUYERS);
      if (rounds[currentRoundId].rbCount < MAX_RECENT_BUYERS) {
        rounds[currentRoundId].rbCount++;
      }
    }
  }

  function recentBuyers(uint256 roundId) external view returns (address[] memory out) {
    uint256 n = rounds[roundId].rbCount;
    out = new address[](n);
    uint256 idx = rounds[roundId].rbHead;
    for (uint256 i = 0; i < n; i++) {
      idx = idx == 0 ? MAX_RECENT_BUYERS - 1 : idx - 1;
      out[i] = rounds[roundId].recentBuyers[idx];
    }
  }

  function _distributeFee(uint256 taxAmount) internal returns (uint256 creatorFeeDelta, uint256 countdownPoolDeltaApplied, uint256 jackpotPoolDeltaApplied) {
    uint256 creatorFee = (taxAmount * CREATOR_FEE_BPS) / 10_000;
    uint256 countdownPoolFee = (taxAmount * COUNTDOWN_POOL_FEE_BPS) / 10_000;
    uint256 jackpotPoolFee = taxAmount - (creatorFee + countdownPoolFee);

    uint256 jackpotCap = IClockGameMechanics(gameMechanics).getJackpotCap();

    // prevent jackpot pool from exceeding cap
    uint256 allowedJackpotPoolFee = jackpotPoolBalance >= jackpotCap 
        ? 0 
        : jackpotCap - jackpotPoolBalance;
    if (jackpotPoolFee > allowedJackpotPoolFee) {
      countdownPoolFee += jackpotPoolFee - allowedJackpotPoolFee;
      jackpotPoolFee = allowedJackpotPoolFee;
    }

    rounds[currentRoundId].countdownPoolBalance += countdownPoolFee;
    jackpotPoolBalance += jackpotPoolFee;
    creatorFeeBalance += creatorFee;

    return (creatorFee, countdownPoolFee, jackpotPoolFee);
  }

  function getVRFFee() public view returns (uint256) {
    return vrfFeeAmount;
  }

  function setVRFFeeAmount(uint256 newVRFFeeAmount) external onlyRole(VRF_OPERATOR_ROLE) {
    require(newVRFFeeAmount <= 0.1 ether, "VRF fee too high");
    uint256 oldAmount = vrfFeeAmount;
    vrfFeeAmount = newVRFFeeAmount;
    emit VRFFeeAmountUpdated(oldAmount, newVRFFeeAmount);
  }

  function setVrfConfig(ClockVrfConfig calldata _vrfConfig) external onlyRole(VRF_OPERATOR_ROLE) {
    require(_vrfConfig.vrfSubscriptionId != 0, "Subscription ID cannot be zero");
    require(_vrfConfig.vrfKeyHash != bytes32(0), "Key hash cannot be zero");
    require(_vrfConfig.vrfCallbackGasLimit > 0, "Callback gas limit must be positive");
    require(_vrfConfig.vrfRequestConfirmations > 0, "Request confirmations must be positive");
    vrfConfig = _vrfConfig;
    emit VRFConfigUpdated(_vrfConfig.vrfSubscriptionId, _vrfConfig.vrfKeyHash, _vrfConfig.vrfCallbackGasLimit, _vrfConfig.vrfRequestConfirmations);
  }

  function getVrfConfig() external view returns (ClockVrfConfig memory) {
    return vrfConfig;
  }

  function _requestVrf() private returns (uint256 requestId) {
    requestId = s_vrfCoordinator.requestRandomWords(
      VRFV2PlusClient.RandomWordsRequest({
        keyHash: vrfConfig.vrfKeyHash,
        subId: vrfConfig.vrfSubscriptionId,
        requestConfirmations: vrfConfig.vrfRequestConfirmations,
        callbackGasLimit: vrfConfig.vrfCallbackGasLimit,
        numWords: VRF_NUM_WORDS,
        extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
      })
    );
  }

  function _incrementBuyerNonce() internal {
    unchecked { buyerNonce++; }
  }

  function _clearStaleVrfLock(address buyerAddress) internal {
    if (buyers[buyerAddress].unfulfilledVrfCount > 0) {
      uint256 timeSinceLastVrf = block.timestamp - buyers[buyerAddress].lastUnfulfilledVrfTimestamp;
      if (timeSinceLastVrf >= VRF_LOCK_TIMEOUT) {
        buyers[buyerAddress].unfulfilledVrfCount = 0;
      }
    }
  }

  // manually clear out expired VRF locks
  function clearStaleVrfLock(address buyerAddress) external {
    _clearStaleVrfLock(buyerAddress);
  }

  function handleBuy(address buyerAddress, uint256 buyAmount, uint256 tokenAmount, uint256 taxAmount, uint256 vrfFee) external payable onlyAuthorizedCaller {
    unchecked { buySequence++; }
    uint256 currentBuySequence = buySequence;
    uint256 requestId = 0;
    // Track VRF fees for later conversion to LINK
    vrfFeeBalance += vrfFee;
    (uint256 creatorFeeDelta, uint256 countdownPoolDelta, uint256 jackpotPoolDelta) = _distributeFee(taxAmount);
    // if round ended, don't request vrf
    bool roundEnded = block.timestamp >= rounds[currentRoundId].endTimestamp;
    if (roundEnded) {
      _incrementBuyerNonce();
      emit BuyInitiated(
        currentBuySequence,
        requestId,
        currentRoundId,
        buyerAddress,
        buyAmount,
        tokenAmount,
        taxAmount,
        creatorFeeDelta,
        countdownPoolDelta,
        jackpotPoolDelta,
        rounds[currentRoundId].endTimestamp,
        buyerNonce,
        true
      );
      return;
    }
    requestId = _requestVrf();
    pendingBuys[requestId] = PendingBuy({
      buyer: buyerAddress,
      buyAmount: buyAmount,
      roundId: currentRoundId,
      fulfilled: false
    });
    _clearStaleVrfLock(buyerAddress);
    buyers[buyerAddress].unfulfilledVrfCount++;
    buyers[buyerAddress].lastUnfulfilledVrfTimestamp = block.timestamp;
    emit BuyInitiated(
      currentBuySequence,
      requestId,
      currentRoundId,
      buyerAddress,
      buyAmount,
      tokenAmount,
      taxAmount,
      creatorFeeDelta,
      countdownPoolDelta,
      jackpotPoolDelta,
      rounds[currentRoundId].endTimestamp,
      0,
      false
    );
  }

  // handle non-buy swap tax, no game participation
  function handleSwap(uint256 taxAmount) external onlyAuthorizedCaller {
    _distributeFee(taxAmount);
  }

  // check if there are any pending vrf requests for the sender or if
  // the last unfulfilled vrf request was less than VRF_LOCK_TIMEOUT ago
  function isLocked(address buyerAddress) external view returns (bool) {
    bool hasUnfulfilledVrf = buyers[buyerAddress].unfulfilledVrfCount > 0;
    uint256 timeSinceLastUnfulfilledVrf = block.timestamp - buyers[buyerAddress].lastUnfulfilledVrfTimestamp;
    return hasUnfulfilledVrf && timeSinceLastUnfulfilledVrf < VRF_LOCK_TIMEOUT;
  }

  function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
    PendingBuy storage pendingBuy = pendingBuys[requestId];
    
    require(pendingBuy.buyer != address(0), "Invalid request ID");
    require(!pendingBuy.fulfilled, "Request already fulfilled");
    
    pendingBuy.fulfilled = true;
    if (buyers[pendingBuy.buyer].unfulfilledVrfCount > 0) {
      buyers[pendingBuy.buyer].unfulfilledVrfCount--;
    }

    uint256 randomWord = randomWords[0];
    _incrementBuyerNonce();

    bool roundEnded = !(block.timestamp < rounds[pendingBuy.roundId].endTimestamp && pendingBuy.roundId == currentRoundId);
    if (roundEnded) {
      emit VRFResultProcessed(requestId, pendingBuy.roundId, pendingBuy.buyer, 0, rounds[pendingBuy.roundId].endTimestamp, 0, buyerNonce, 0, 0);
      return;
    }
    uint256 extensionProbabilityPPM = calculateExtensionProbabilityPPM(pendingBuy.buyAmount, rounds[pendingBuy.roundId].countdownPoolBalance);
    bool shouldExtendTime = randomWord % PRECISION_DENOMINATOR < extensionProbabilityPPM;
    
    uint256 timeIncrease = 0;
    if (shouldExtendTime) {
      timeIncrease = calculateTimeDelta();
      rounds[currentRoundId].endTimestamp += timeIncrease;
      _recordBuyer(pendingBuy.buyer);
    }
    uint256 jackpotRandom = (randomWord / 2) % PRECISION_DENOMINATOR;
    uint256 jackpotAmountWon = 0;
    uint256 jackpotChancePPM = getJackpotOddsPPM(pendingBuy.buyAmount, jackpotPoolBalance);
    if (jackpotRandom < jackpotChancePPM && jackpotPoolBalance > 0) {
      jackpotAmountWon = jackpotPoolBalance;
      playerBalances[pendingBuy.buyer] += jackpotAmountWon;
      jackpotPoolBalance = 0;
      IClockGameMechanics(gameMechanics).randomizeJackpotAlpha(randomWord);
    }
    
    emit VRFResultProcessed(
      requestId,
      pendingBuy.roundId,
      pendingBuy.buyer,
      timeIncrease,
      rounds[pendingBuy.roundId].endTimestamp,
      jackpotAmountWon,
      buyerNonce,
      extensionProbabilityPPM,
      jackpotChancePPM
    );
  }

  /**
   * Rank distribution of the countdown pool (50 most recent extenders)
   * 1st    : 50.00%
   * 2-5    : 5.00% each
   * 6-10   : 2.00%
   * 11-25  : 1.00%
   * 26-50  : 0.20%
   */
  function rewardPpm(uint256 rank) internal pure returns (uint256) {
    // rank = 1 means most recent, rank = 2 means second most recent, etc.
    if (rank == 1) return 5_000_000;
    if (rank <= 5) return 500_000;
    if (rank <= 10) return 200_000;
    if (rank <= 25) return 100_000;
    if (rank <= 50) return 20_000;
    return 0;
  }

  // return the rank of the player at index `idx` in the recent buyers circular buffer
  // returns 0 if index is out of bounds (no rank)
  function rankFromIndex(uint256 idx, uint256 roundId) internal view returns (uint256) {
    uint256 head = rounds[roundId].rbHead;
    uint256 N = rounds[roundId].rbCount;
    if (N == 0 || idx >= N) {
      return 0;
    }
    unchecked {
      uint256 distanceFromHead = (head + MAX_RECENT_BUYERS - idx - 1) % MAX_RECENT_BUYERS;
      uint256 rank = distanceFromHead + 1;
      return rank <= N ? rank : 0;
    }
  }

  function distributeRoundRewards() internal {
    uint256 totalDistributed = 0;
    Round storage round = rounds[currentRoundId];
    for (uint256 i = 0; i < round.rbCount; i++) {
      address player = round.recentBuyers[i];
      uint256 rank = rankFromIndex(i, currentRoundId);
      if (rank == 0) continue;
      uint256 playerRewardPpm = rewardPpm(rank);
      uint256 reward = (round.countdownPoolBalance * playerRewardPpm) / REWARD_SCALAR;
      playerBalances[player] += reward;
      totalDistributed += reward;
    }
    uint256 remaining = round.countdownPoolBalance - totalDistributed;
    if (remaining > 0) {
      creatorFeeBalance += remaining;
    }
  }

  function startNewRound() internal {
    currentRoundId++;
    rounds[currentRoundId].id = uint64(currentRoundId);
    rounds[currentRoundId].startTimestamp = block.timestamp;
    rounds[currentRoundId].endTimestamp = block.timestamp + _getRoundLength();
  }

  function closeRound() internal {
    Round storage round = rounds[currentRoundId];
    round.ended = true;
    emit RoundEnded(currentRoundId, round.startTimestamp, round.endTimestamp, round.countdownPoolBalance, jackpotPoolBalance);
  }

  function endRound() external roundTimerExpired(currentRoundId) {
    distributeRoundRewards();
    closeRound();
    startNewRound();
  }

  function donate(DonatePool pool) external payable nonReentrant {
    require(msg.value > 0, "Amount must be > 0");

    address currency0 = Currency.unwrap(clockPool.currency0);
    address currency1 = Currency.unwrap(clockPool.currency1);
    address wethAddress = currency0 == address(clockToken) ? currency1 : currency0;

    IWETH9(wethAddress).deposit{value: msg.value}();

    uint256 jackpotCap = IClockGameMechanics(gameMechanics).getJackpotCap();

    if (pool == DonatePool.Countdown) {
      rounds[currentRoundId].countdownPoolBalance += msg.value;
    } else if (pool == DonatePool.Jackpot) {
      if (jackpotPoolBalance + msg.value > jackpotCap) {
        revert("Jackpot pool at cap");
      } else {
        jackpotPoolBalance += msg.value;
      }
    } else if (pool == DonatePool.Creator) {
      creatorFeeBalance += msg.value;
    } else {
      revert("Invalid pool");
    }
    emit Donation(msg.sender, pool, msg.value, currentRoundId);
  }

  function claimPlayerBalance(address player) external nonReentrant {
    uint256 amount = playerBalances[player];
    require(amount > 0, "No balance to claim");

    playerBalances[player] = 0;

    address currency0 = Currency.unwrap(clockPool.currency0);
    address currency1 = Currency.unwrap(clockPool.currency1);
    address wethAddress = currency0 == address(clockToken) ? currency1 : currency0;

    uint256 wethBal = ERC20(wethAddress).balanceOf(address(this));
    require(wethBal >= amount, "Insufficient WETH liquidity");

    IWETH9(wethAddress).withdraw(amount);
    (bool success, ) = payable(player).call{value: amount}("");
    require(success, "ETH transfer failed");

    emit PlayerBalanceClaimed(player, amount);
  }

  function claimCreatorFees() external nonReentrant onlyCreator {
    uint256 amount = creatorFeeBalance;
    require(amount > 0, "No creator fees");
    creatorFeeBalance = 0;

    address currency0 = Currency.unwrap(clockPool.currency0);
    address currency1 = Currency.unwrap(clockPool.currency1);
    address wethAddress = currency0 == address(clockToken) ? currency1 : currency0;

    uint256 wethBal = ERC20(wethAddress).balanceOf(address(this));
    require(wethBal >= amount, "Insufficient WETH liquidity");

    IWETH9(wethAddress).withdraw(amount);
    (bool success, ) = payable(creator).call{value: amount}("");
    require(success, "ETH transfer failed");

    emit CreatorFeesClaimed(creator, amount);
  }

  // two-step creator transfer
  function transferCreator(address newCreator) external onlyCreator {
    require(newCreator != address(0), "New creator is zero address");
    require(newCreator != creator, "Already creator");
    pendingCreator = newCreator;
    emit CreatorTransferProposed(creator, newCreator);
  }

  function acceptCreatorTransfer() external {
    address newCreator = pendingCreator;
    require(newCreator != address(0), "No pending creator");
    require(msg.sender == newCreator, "Not pending creator");
    address previous = creator;
    creator = newCreator;
    pendingCreator = address(0);
    emit CreatorTransferred(previous, newCreator);
  }

  function cancelCreatorTransfer() external onlyCreator {
    address cancelled = pendingCreator;
    require(cancelled != address(0), "No pending creator");
    pendingCreator = address(0);
    emit CreatorTransferCancelled(creator, cancelled);
  }

  function setGameMechanics(address newMechanics) external onlyRole(GAME_OPERATOR_ROLE) {
    require(newMechanics != address(0), "Game mechanics cannot be zero");
    address previousMechanics = gameMechanics;
    gameMechanics = newMechanics;
    emit GameMechanicsUpdated(previousMechanics, newMechanics);
  }

  // set authorized callers for handleBuy/handleSwap
  function setAuthorizedCaller(address caller, bool authorized) external onlyRole(AUTHORIZATION_ADMIN_ROLE) {
    require(caller != address(0), "Invalid caller address");
    authorizedCallers[caller] = authorized;
    emit AuthorizedCallerUpdated(caller, authorized);
  }

  function withdrawVrfFees() external nonReentrant onlyRole(VRF_CLAIMER_ROLE) {
    uint256 amount = vrfFeeBalance;
    require(amount > 0, "No VRF fees to withdraw");
    vrfFeeBalance = 0;

    address currency0 = Currency.unwrap(clockPool.currency0);
    address currency1 = Currency.unwrap(clockPool.currency1);
    address wethAddress = currency0 == address(clockToken) ? currency1 : currency0;

    uint256 wethBal = ERC20(wethAddress).balanceOf(address(this));
    require(wethBal >= amount, "Insufficient WETH liquidity");

    IWETH9(wethAddress).withdraw(amount);
    (bool success, ) = payable(msg.sender).call{value: amount}("");
    require(success, "ETH transfer failed");

    emit VrfFeesWithdrawn(msg.sender, amount);
  }

  function emergencyPoolMigration() external onlyRole(EMERGENCY_MIGRATOR_ROLE) {
    address currency0 = Currency.unwrap(clockPool.currency0);
    address currency1 = Currency.unwrap(clockPool.currency1);
    address wethAddress = currency0 == address(clockToken) ? currency1 : currency0;

    uint256 countdownPoolBalance = rounds[currentRoundId].countdownPoolBalance;
    uint256 totalMigrationAmount = countdownPoolBalance + jackpotPoolBalance + creatorFeeBalance + vrfFeeBalance;
    
    IWETH9(wethAddress).withdraw(totalMigrationAmount);
    (bool success, ) = payable(msg.sender).call{value: totalMigrationAmount}("");
    require(success, "ETH transfer failed");

    rounds[currentRoundId].countdownPoolBalance = 0;
    jackpotPoolBalance = 0;
    creatorFeeBalance = 0;
    vrfFeeBalance = 0;

    emit EmergencyPoolMigration(msg.sender, countdownPoolBalance, jackpotPoolBalance, creatorFeeBalance, vrfFeeBalance);
  }
}
