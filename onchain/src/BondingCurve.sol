// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { UD60x18, ud, unwrap } from "@prb/math/src/UD60x18.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { IWETH9 } from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { IClockGame } from "./IClockGame.sol";
import { IClockHook } from "./IClockHook.sol";

/**
 * $TICKER bonding curve
 * by t0m.eth
 */
contract BondingCurve is AccessControl, ReentrancyGuard {
  bytes32 public constant MIGRATION_OPERATOR_ROLE = keccak256("MIGRATION_OPERATOR_ROLE");

  ERC20 public immutable clockToken;
  IClockGame public immutable clockGame;
  IClockHook public immutable clockHook;

  struct MigrationConfig {
    address weth;
    address poolManager;
    address positionManager;
    address permit2;
    PoolKey poolKey;
    int24 tickLower;
    int24 tickUpper;
  }

  modifier notGraduated() {
    require(!graduated, "Curve graduated");
    _;
  }

  modifier tradingIsEnabled() {
    require(tradingEnabled, "Trading not enabled");
    _;
  }

  // curve parameters
  uint256 public immutable V0; // V0: virtual ETH (wei)
  uint256 public immutable T0; // T0: slope factor (token units, 18 decimals)

  // tax
  uint256 public constant INIT_TAX_BPS = 9_900;
  uint256 public constant FINAL_TAX_BPS = 1_000;
  uint256 public taxStartTimestamp;

  // pool state
  uint256 public ethRaised; // excludes tax + vrf fees
  uint256 public tokensSold;
  uint256 public initialTokenAllocation;
  bool public tradingEnabled;

  // graduation
  bool public graduated;
  bool public poolMigrated;
  uint256 public graduationTimestamp;
  uint256 public graduationEthTarget;

  MigrationConfig public migrationConfig;
  bool public migrationConfigSet;
  address public lpRecipient;

  // zeroForOne: true = ETH -> TOKEN (buy), false = TOKEN -> ETH (sell)
  // amount0: ETH, amount1: TOKEN
  event BondingCurveSwap(
    address indexed actor,
    bool zeroForOne,
    uint256 amount0,
    uint256 amount1,
    uint256 taxAmount,
    uint256 vrfFee,
    uint256 newEthRaised,
    uint256 postSpotEthPerToken1e18
  );
  event Graduated(uint256 ethRaised, uint256 tokensSold, uint256 timestamp);
  event TradingEnabled(uint256 timestamp);

  constructor(
    address _token,
    address _clockGame,
    address _clockHook,
    uint256 _V0,
    uint256 _T0,
    uint256 _graduationEthTarget,
    uint256 _initialTokenAllocation,
    address _owner
  ) {
    require(_token != address(0) && _clockGame != address(0), "Invalid address");
    require(_clockHook != address(0), "Invalid hook address");
    require(_V0 > 0 && _T0 > 0 && _initialTokenAllocation > 0, "Invalid params");
    require(_graduationEthTarget > 0, "Invalid graduation target");
    require(_owner != address(0), "Invalid owner");
    clockToken = ERC20(_token);
    clockGame = IClockGame(_clockGame);
    clockHook = IClockHook(_clockHook);
    V0 = _V0;
    T0 = _T0;
    graduationEthTarget = _graduationEthTarget;
    initialTokenAllocation = _initialTokenAllocation;
    lpRecipient = _owner;

    _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    _grantRole(MIGRATION_OPERATOR_ROLE, _owner);
  }

  receive() external payable {}

  // enable trading on the bonding curve, starts the tax countdown and the game timer
  function enableTrading() external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(!tradingEnabled, "Trading already enabled");
    tradingEnabled = true;
    taxStartTimestamp = block.timestamp;
    clockHook.setTaxStartTimestamp(block.timestamp);
    clockGame.startGame();
    emit TradingEnabled(block.timestamp);
  }

  function isGraduated() external view returns (bool) {
    return graduated;
  }

  function _currentTaxBps() internal view returns (uint256) {
    if (taxStartTimestamp == 0) return INIT_TAX_BPS;
    uint256 elapsedMinutes = (block.timestamp - taxStartTimestamp) / 60;
    uint256 reduction = elapsedMinutes * 100;
    uint256 decreased = INIT_TAX_BPS > reduction ? INIT_TAX_BPS - reduction : 0;
    return decreased < FINAL_TAX_BPS ? FINAL_TAX_BPS : decreased;
  }

  // sold(x) = T0 * ln(1 + x / V0)
  function _soldFunction(uint256 xWei) internal view returns (uint256 soldTokens) {
    if (xWei == 0) return 0;
    UD60x18 x = ud(xWei);
    UD60x18 v0 = ud(V0);
    UD60x18 ratio = x.div(v0);
    UD60x18 onePlus = ud(1e18).add(ratio);
    UD60x18 lnVal = onePlus.ln();
    soldTokens = (T0 * unwrap(lnVal)) / 1e18;
  }

  // invert sold(x) = T0 * ln(1 + x/V0) -> x = V0 * (exp(S/T0) - 1)
  function _xFromSold(uint256 soldTokens) internal view returns (uint256 xWei) {
    if (soldTokens == 0) return 0;
    UD60x18 S = ud(soldTokens);
    UD60x18 t0 = ud(T0);
    UD60x18 ratio = S.div(t0);
    UD60x18 e = ratio.exp();
    UD60x18 diff = e.sub(ud(1e18));
    UD60x18 v0 = ud(V0);
    xWei = unwrap(v0.mul(diff));
  }

  function getTokensOutForEth(uint256 ethInWei) external view returns (uint256 tokensOut, uint256 taxAmount, uint256 vrfFee, uint256 netEth) {
    if (graduated || ethInWei == 0) {
      return (0, 0, 0, 0);
    }
    uint256 taxBps = _currentTaxBps();
    vrfFee = clockGame.getVRFFee();
    taxAmount = (ethInWei * taxBps) / 10_000;
    uint256 totalFee = taxAmount + vrfFee;
    if (ethInWei <= totalFee) {
      return (0, taxAmount, vrfFee, 0);
    }
    netEth = ethInWei - totalFee;
    uint256 newSold = _soldFunction(ethRaised + netEth);
    uint256 prevSold = _soldFunction(ethRaised);
    tokensOut = newSold - prevSold;
  }

  function getEthOutForTokens(uint256 tokenIn) external view returns (uint256 ethOut, uint256 taxAmount, uint256 netEth) {
    require(tokenIn > 0, "Zero tokenIn");
    require(tokenIn <= tokensSold, "Exceeds sold supply");
    uint256 prevX = ethRaised;
    uint256 newSold = tokensSold - tokenIn;
    uint256 newX = _xFromSold(newSold);
    require(prevX > newX, "No ETH available");
    ethOut = prevX - newX;
    uint256 taxBps = _currentTaxBps();
    taxAmount = (ethOut * taxBps) / 10_000;
    netEth = ethOut - taxAmount;
  }

  function getCurrentPrice1e18() public view returns (uint256) {
    uint256 numer = V0 + ethRaised;
    return (numer * 1e18) / T0;
  }

  function getVirtualReserves() external view returns (uint256 virtualEthWei, uint256 virtualTokens) {
    virtualEthWei = V0 + ethRaised;
    virtualTokens = T0;
  }

  function buy(uint256 minTokensOut, uint256 deadline) external payable nonReentrant notGraduated tradingIsEnabled {
    require(block.timestamp <= deadline, "Transaction expired");
    require(msg.value > 0, "No ETH sent");

    uint256 taxBps = _currentTaxBps();
    uint256 vrfFee = clockGame.getVRFFee();
    uint256 taxAmount = (msg.value * taxBps) / 10_000;
    uint256 totalFee = taxAmount + vrfFee;
    require(msg.value > totalFee, "Insufficient amount for fees");

    uint256 netEth = msg.value - totalFee;

    uint256 newSold = _soldFunction(ethRaised + netEth);
    uint256 prevSold = _soldFunction(ethRaised);
    uint256 tokensOut = newSold - prevSold;
    require(tokensOut >= minTokensOut, "Slippage: OUT_TOO_LOW");

    ethRaised += netEth;
    tokensSold += tokensOut;

    require(migrationConfig.weth != address(0), "WETH not configured");
    if (totalFee > 0) {
      IWETH9(migrationConfig.weth).deposit{ value: totalFee }();
      require(ERC20(migrationConfig.weth).transfer(address(clockGame), totalFee), "WETH fee transfer failed");
    }
    clockGame.handleBuy(msg.sender, msg.value, tokensOut, taxAmount, vrfFee);

    uint256 inventory = clockToken.balanceOf(address(this));
    require(inventory >= tokensOut, "Insufficient token inventory");
    require(clockToken.transfer(msg.sender, tokensOut), "Token transfer failed");

    emit BondingCurveSwap(msg.sender, true, netEth, tokensOut, taxAmount, vrfFee, ethRaised, getCurrentPrice1e18());

    if (ethRaised >= graduationEthTarget) {
      graduated = true;
      graduationTimestamp = block.timestamp;
      emit Graduated(ethRaised, tokensSold, graduationTimestamp);
    }
  }

  function sell(uint256 tokenIn, uint256 minEthOut, uint256 deadline) external nonReentrant notGraduated tradingIsEnabled {
    require(block.timestamp <= deadline, "Transaction expired");
    require(tokenIn > 0, "Zero tokenIn");
    require(tokenIn <= tokensSold, "Exceeds sold supply");

    uint256 balanceBefore = clockToken.balanceOf(address(this));
    require(clockToken.transferFrom(msg.sender, address(this), tokenIn), "Token transferFrom failed");
    uint256 actualTokenIn = clockToken.balanceOf(address(this)) - balanceBefore;
    require(actualTokenIn == tokenIn, "transfer fee tokens not supported");

    uint256 prevX = ethRaised;
    uint256 newSold = tokensSold - tokenIn;
    uint256 newX = _xFromSold(newSold);
    require(prevX > newX, "No ETH available");

    uint256 ethOut = prevX - newX;
    uint256 taxBps = _currentTaxBps();
    uint256 taxAmount = (ethOut * taxBps) / 10_000;
    uint256 netEthToUser = ethOut - taxAmount;
    require(netEthToUser >= minEthOut, "Slippage: OUT_TOO_LOW");

    tokensSold = newSold;
    ethRaised = newX;

    if (taxAmount > 0) {
      require(migrationConfig.weth != address(0), "WETH not configured");
      IWETH9(migrationConfig.weth).deposit{ value: taxAmount }();
      require(ERC20(migrationConfig.weth).transfer(address(clockGame), taxAmount), "WETH tax transfer failed");
      clockGame.handleSwap(taxAmount);
    }
    (bool ok2, ) = payable(msg.sender).call{ value: netEthToUser }("");
    require(ok2, "ETH transfer failed");

    emit BondingCurveSwap(msg.sender, false, ethOut, tokenIn, taxAmount, 0, ethRaised, getCurrentPrice1e18());
  }

  function setMigrationConfig(MigrationConfig calldata config) external onlyRole(MIGRATION_OPERATOR_ROLE) {
    require(!poolMigrated, "Already migrated");
    require(config.weth != address(0) && config.positionManager != address(0) && config.permit2 != address(0), "Invalid address");
    migrationConfig = config;
    migrationConfigSet = true;
  }

  function setLpRecipient(address _lpRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(!poolMigrated, "Already migrated");
    require(_lpRecipient != address(0), "Invalid address");
    lpRecipient = _lpRecipient;
  }

  // get the canonical reserves (used for bonding curve migration)
  function getCanonicalReserves() public view returns (uint256 tokenReserves, uint256 ethReserves) {
    tokenReserves = initialTokenAllocation - tokensSold;
    ethReserves = ethRaised;
  }

  // Sweep any dust after migration
  function sweepDust() external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(poolMigrated, "Cannot sweep before migration");
    uint256 tokenBal = clockToken.balanceOf(address(this));
    uint256 wethBal = IWETH9(migrationConfig.weth).balanceOf(address(this));
    uint256 ethBal = address(this).balance;
    if (tokenBal > 0) {
      require(clockToken.transfer(msg.sender, tokenBal), "Token sweep failed");
    }
    if (wethBal > 0) {
      require(IWETH9(migrationConfig.weth).transfer(msg.sender, wethBal), "WETH sweep failed");
    }
    if (ethBal > 0) {
      (bool success, ) = payable(msg.sender).call{value: ethBal}("");
      require(success, "ETH sweep failed");
    }
  }

  function _calculateSqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
    require(amount0 > 0 && amount1 > 0, "Zero reserves");
    UD60x18 price = ud(amount1 * 1e18 / amount0);
    UD60x18 sqrtPrice = price.sqrt();
    uint256 sqrtPriceX96 = (unwrap(sqrtPrice) * (1 << 96)) / 1e18;
    require(sqrtPriceX96 <= type(uint160).max, "sqrtPriceX96 overflow");
    return uint160(sqrtPriceX96);
  }

  // migrate the entire remaining reserves into the Uniswap V4 position
  function migrateReservesToPool(uint256 deadline) external nonReentrant {
    require(block.timestamp <= deadline, "Migration expired");
    require(graduated, "Not graduated");
    require(!poolMigrated, "Already migrated");
    require(migrationConfigSet, "Config not set");
    if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
      require(block.timestamp >= graduationTimestamp + 10 minutes, "Admin window not passed");
    }

    (uint256 tokenReserves, uint256 ethReserves) = getCanonicalReserves();
    require(tokenReserves > 0 && ethReserves > 0, "Insufficient reserves");

    IWETH9(migrationConfig.weth).deposit{ value: ethReserves }();

    require(clockToken.approve(migrationConfig.permit2, tokenReserves), "Approve token to Permit2 failed");
    require(IWETH9(migrationConfig.weth).approve(migrationConfig.permit2, ethReserves), "Approve WETH to Permit2 failed");

    uint48 expiration = uint48(block.timestamp + 3600);
    IPermit2(migrationConfig.permit2).approve(address(clockToken), migrationConfig.positionManager, uint160(tokenReserves), expiration);
    IPermit2(migrationConfig.permit2).approve(migrationConfig.weth, migrationConfig.positionManager, uint160(ethReserves), expiration);

    bool tokenIsCurrency0 = migrationConfig.poolKey.currency0 == Currency.wrap(address(clockToken));
    uint256 amount0 = tokenIsCurrency0 ? tokenReserves : ethReserves;
    uint256 amount1 = tokenIsCurrency0 ? ethReserves : tokenReserves;
    uint160 sqrtPriceX96 = _calculateSqrtPriceX96(amount0, amount1);

    uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(migrationConfig.tickLower);
    uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(migrationConfig.tickUpper);
    
    uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0, amount1);
    require(liquidity > 0, "Zero liquidity");

    uint128 amount0Max = amount0 > type(uint128).max ? type(uint128).max : uint128(amount0);
    uint128 amount1Max = amount1 > type(uint128).max ? type(uint128).max : uint128(amount1);

    bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
    bytes memory mintParams = abi.encode(
      migrationConfig.poolKey,
      migrationConfig.tickLower,
      migrationConfig.tickUpper,
      uint256(liquidity),
      amount0Max,
      amount1Max,
      lpRecipient,
      bytes("")
    );
    bytes memory settleParams = abi.encode(migrationConfig.poolKey.currency0, migrationConfig.poolKey.currency1);
    bytes[] memory params = new bytes[](2);
    params[0] = mintParams;
    params[1] = settleParams;
    bytes memory unlockData = abi.encode(actions, params);

    PoolKey memory poolKey = PoolKey({
      currency0: migrationConfig.poolKey.currency0,
      currency1: migrationConfig.poolKey.currency1,
      fee: migrationConfig.poolKey.fee,
      tickSpacing: migrationConfig.poolKey.tickSpacing,
      hooks: IHooks(migrationConfig.poolKey.hooks)
    });
    IPoolManager(migrationConfig.poolManager).initialize(poolKey, sqrtPriceX96);

    IPositionManager(migrationConfig.positionManager).modifyLiquidities(unlockData, deadline);
    poolMigrated = true;
  }

  // if there's a bug in migration, owner can manually claim then migrate the reserves ~10 min after graduation
  function emergencyMigration() external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(graduated, "Not graduated");
    require(!poolMigrated, "Already migrated");
    require(migrationConfigSet, "Config not set");
    require(block.timestamp >= graduationTimestamp + 10 minutes, "Not enough time since graduation");
    (uint256 tokenReserves, uint256 ethReserves) = getCanonicalReserves();
    require(clockToken.transfer(msg.sender, tokenReserves), "Token transfer failed");
    IWETH9(migrationConfig.weth).deposit{ value: ethReserves }();
    require(ERC20(migrationConfig.weth).transfer(msg.sender, ethReserves), "WETH transfer failed");
    poolMigrated = true;
  }

  function getDebugStats()
    external
    view
    returns (
      uint256 v0,
      uint256 t0,
      uint256 _ethRaised,
      uint256 _tokensSold,
      uint256 virtualEthWei,
      uint256 virtualTokens,
      uint256 currentTaxBps,
      bool _graduated,
      uint256 _graduationEthTarget,
      uint256 _graduationTimestamp,
      bool _poolMigrated,
      bool _migrationConfigSet,
      uint256 tokenInventory,
      uint256 ethBalance,
      uint256 priceEthPerToken1e18
    )
  {
    v0 = V0;
    t0 = T0;
    _ethRaised = ethRaised;
    _tokensSold = tokensSold;
    virtualEthWei = V0 + ethRaised;
    virtualTokens = T0;
    currentTaxBps = _currentTaxBps();
    _graduated = graduated;
    _graduationEthTarget = graduationEthTarget;
    _graduationTimestamp = graduationTimestamp;
    _poolMigrated = poolMigrated;
    _migrationConfigSet = migrationConfigSet;
    tokenInventory = clockToken.balanceOf(address(this));
    ethBalance = address(this).balance;
    priceEthPerToken1e18 = getCurrentPrice1e18();
  }
} 
