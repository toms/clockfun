// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { IPoolManager, SwapParams } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IClockGame } from "./IClockGame.sol";
import { IClockHook } from "./IClockHook.sol";

interface IMsgSender {
  function msgSender() external view returns (address);
}

/**
 * $TICKER Uniswap V4 hook
 * by t0m.eth
 */
contract ClockHook is BaseHook, AccessControl, IClockHook {
  using StateLibrary for IPoolManager;
  using PoolIdLibrary for PoolKey;
  Currency public immutable WETH;

  bytes32 public constant INITIALIZER_ROLE = keccak256("INITIALIZER_ROLE");
  bytes32 public constant ROUTER_OPERATOR_ROLE = keccak256("ROUTER_OPERATOR_ROLE");

  uint256 public constant INIT_TAX_BPS = 9_900;
  uint256 public constant FINAL_TAX_BPS = 1_000;

  mapping(PoolId => bool) public authorizedPools;
  mapping(address => bool) public whitelistedRouters;

  bool public isInitialized;

  IClockGame public clockGame;
  uint256 public taxStartTimestamp;
  address public bondingCurve;

  event RouterWhitelistUpdate(address indexed router, bool isWhitelisted);
  event AfterSwap(
    PoolId indexed poolId,
    address indexed originalCaller,
    bool zeroForOne,
    int256 amountSpecified,
    int128 amount0Delta,
    int128 amount1Delta,
    uint160 sqrtPriceX96,
    uint128 liquidity,
    int24 tick,
    uint256 swapTax,
    uint256 vrfFee,
    uint256 ethPerToken1e18
  );

  modifier onlyAuthorizedPool(PoolKey calldata key) {
    require(authorizedPools[key.toId()], "Pool not authorized");
    _;
  }

  modifier onlyBondingCurve() {
    require(msg.sender == bondingCurve, "Not bonding curve");
    _;
  }

  constructor(
    IPoolManager _poolManager,
    address _WETH,
    IClockGame _clockGame,
    address _owner,
    address _initialRouter
  ) BaseHook(_poolManager) {
    require(_owner != address(0), "Invalid owner");
    WETH = Currency.wrap(_WETH);
    clockGame = _clockGame;

    _grantRole(DEFAULT_ADMIN_ROLE, _owner);
    _grantRole(INITIALIZER_ROLE, _owner);
    _grantRole(ROUTER_OPERATOR_ROLE, _owner);

    if (_initialRouter != address(0)) {
      whitelistedRouters[_initialRouter] = true;
      emit RouterWhitelistUpdate(_initialRouter, true);
    }
  }

  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
      beforeInitialize: true,
      afterInitialize: false,
      beforeAddLiquidity: false,
      afterAddLiquidity: false,
      beforeRemoveLiquidity: false,
      afterRemoveLiquidity: false,
      beforeSwap: true,
      afterSwap: true,
      beforeDonate: false,
      afterDonate: false,
      beforeSwapReturnDelta: true,
      afterSwapReturnDelta: true,
      afterAddLiquidityReturnDelta: false,
      afterRemoveLiquidityReturnDelta: false
    });
  }

  receive() external payable {}

  function initializeHook(PoolKey calldata _initialPool) external onlyRole(INITIALIZER_ROLE) {
    require(!isInitialized, "Already initialized");
    require(address(_initialPool.hooks) == address(this), "Incorrect pool hook address");
    authorizedPools[_initialPool.toId()] = true;
    isInitialized = true;
  }

  function setBondingCurve(address bc) external onlyRole(INITIALIZER_ROLE) {
    require(bc != address(0), "Invalid address");
    require(bondingCurve == address(0), "Already set");
    bondingCurve = bc;
  }

  function setTaxStartTimestamp(uint256 ts) external onlyBondingCurve {
    require(ts > 0, "Invalid timestamp");
    taxStartTimestamp = ts;
  }

  function whitelistRouter(address router) external onlyRole(ROUTER_OPERATOR_ROLE) {
    require(router != address(0), "Invalid router address");
    require(!whitelistedRouters[router], "Router already whitelisted");
    whitelistedRouters[router] = true;
    emit RouterWhitelistUpdate(router, true);
  }

  function removeRouterFromWhitelist(address router) external onlyRole(ROUTER_OPERATOR_ROLE) {
    require(whitelistedRouters[router], "Router not whitelisted");
    whitelistedRouters[router] = false;
    emit RouterWhitelistUpdate(router, false);
  }
  function _getOriginalCaller(address sender, bool routerWhitelisted) internal view returns (address) {
    if (!routerWhitelisted) {
      return sender;
    }
    try IMsgSender(sender).msgSender() returns (address originalCaller) {
      return originalCaller;
    } catch {
      return sender;
    }
  }

  function isWhitelistedRouter(address router) public view returns (bool) {
    return whitelistedRouters[router];
  }

  function _getTaxAmount() internal view returns (uint256) {
    if (taxStartTimestamp == 0) {
      return INIT_TAX_BPS;
    }
    uint256 elapsedMinutes = (block.timestamp - taxStartTimestamp) / 60;
    uint256 reduction = elapsedMinutes * 100;
    uint256 decreased = INIT_TAX_BPS > reduction ? INIT_TAX_BPS - reduction : 0;
    return decreased < FINAL_TAX_BPS ? FINAL_TAX_BPS : decreased;
  }

  function _beforeInitialize(address sender, PoolKey calldata key, uint160)
    internal
    view
    override
    returns (bytes4)
  {
    require(authorizedPools[key.toId()], "Pool not authorized");
    require(sender == bondingCurve, "Only bonding curve can initialize");
    return BaseHook.beforeInitialize.selector;
  }

  function _isBuy(PoolKey calldata key, SwapParams calldata params) internal view returns (bool) {
    bool wethIsToken0 = Currency.unwrap(key.currency0) == Currency.unwrap(WETH);
    bool wethIsToken1 = Currency.unwrap(key.currency1) == Currency.unwrap(WETH);
    return (params.zeroForOne && wethIsToken0) || (!params.zeroForOne && wethIsToken1);
  }

  function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
    internal
    override
    onlyAuthorizedPool(key)
    returns (bytes4, BeforeSwapDelta, uint24)
  {
    bool routerWhitelisted = isWhitelistedRouter(sender);
    bool isBuy = _isBuy(key, params);
    bool usesVrf = isBuy && routerWhitelisted;
    (uint256 swapTax, Currency taxCurrency, uint256 vrfFee) = _getEthSpecifiedTaxDelta(key, params, usesVrf);
    uint256 taxDelta = swapTax + vrfFee;
    if (taxDelta > 0) {
      poolManager.take(taxCurrency, address(clockGame), uint256(uint128(taxDelta)));
    }
    BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(int256(taxDelta)), 0);
    return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
  }

  // exact input: user specifies how much they want to send in the tx
  // - unspecified: what the pool sends to the user
  // - specified: what the user sends to the pool
  //    --> zeroForOne = true --> user sends 0 and receives 1 --> unspecified = 1, specified = 0
  //    --> zeroForOne = false --> user sends 1 and receives 0 --> unspecified = 0, specified = 1
  // exact output --> user specifies how much they want to receive in the tx
  // - unspecified: what the user sends to the pool
  // - specified: what the pool sends to the user
  //    --> zeroForOne = true --> user sends 0 and receives 1 --> unspecified = 0, specified = 1
  //    --> zeroForOne = false --> user sends 1 and receives 0 --> unspecified = 1, specified = 0

  // returns the tax delta for transactions where the WETH input is unspecified (used in afterSwap hook)
  function _getEthUnspecifiedTaxDelta(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bool usesVrf)
    internal
    view
    returns (uint256, Currency, uint256)
  {
    bool exactInput = params.amountSpecified < 0;
    (Currency unspecified, int128 deltaAmount) = exactInput
      ? params.zeroForOne ? (key.currency1, delta.amount1()) : (key.currency0, delta.amount0())
      : params.zeroForOne ? (key.currency0, delta.amount0()) : (key.currency1, delta.amount1());
    if (Currency.unwrap(unspecified) != Currency.unwrap(WETH)) {
      return (0, unspecified, 0);
    }
    uint256 taxAmount = _getTaxAmount();
    uint256 swapTax = (_abs(deltaAmount) * taxAmount) / 10_000;
    uint256 vrfFee = usesVrf ? clockGame.getVRFFee() : 0;
    return (swapTax, unspecified, vrfFee);
  }

  // returns the tax delta for transactions where the ETH input is specified (used in beforeSwap hook)
  function _getEthSpecifiedTaxDelta(PoolKey calldata key, SwapParams calldata params, bool usesVrf)
    internal
    view
    returns (uint256 swapTax, Currency specified, uint256 vrfFee)
  {
    bool exactInput = params.amountSpecified < 0;
    specified = exactInput
      ? params.zeroForOne ? key.currency0 : key.currency1
      : params.zeroForOne ? key.currency1 : key.currency0;
    
    if (Currency.unwrap(specified) != Currency.unwrap(WETH)) {
      return (0, specified, 0);
    }
    uint256 taxAmount = _getTaxAmount();
    // add flat VRF fee for buys (WETH is the input leg)
    swapTax = (_abs(params.amountSpecified) * taxAmount) / 10_000;
    vrfFee = usesVrf ? clockGame.getVRFFee() : 0;
    return (swapTax, specified, vrfFee);
  }

  function _unpack(BalanceDelta delta) internal pure returns (int256 delta0, int256 delta1) {
    int256 raw = BalanceDelta.unwrap(delta);
    int128 hi = int128(raw >> 128);
    int128 lo = int128(raw);
    delta0 = int256(hi);
    delta1 = int256(lo);
  }
  // for a buy, the output token is the token amount given to the user
  function _getBuyTokenAmountReceived(SwapParams memory params, BalanceDelta delta)
    internal
    pure
    returns (uint256 tokenAmount, uint256 wethAmount)
  {
    (int256 d0, int256 d1) = _unpack(delta);
    if (params.zeroForOne) {
      tokenAmount = _abs(d1);
      wethAmount  = _abs(d0);
    } else {
      tokenAmount = _abs(d0);
      wethAmount  = _abs(d1);
    }
  }

  function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
    internal
    override
    onlyAuthorizedPool(key)
    returns (bytes4, int128)
  {
    bool isBuy = _isBuy(key, params);
    bool routerWhitelisted = isWhitelistedRouter(sender);
    bool usesVrf = isBuy && routerWhitelisted;
    address originalCaller = _getOriginalCaller(sender, routerWhitelisted);

    (uint256 unspecifiedSwapTax, Currency unspecifiedCurrency, uint256 unspecifiedVrfFee) = _getEthUnspecifiedTaxDelta(key, params, delta, usesVrf);
    uint256 totalUnspecifiedTax = unspecifiedSwapTax + unspecifiedVrfFee;

    if (totalUnspecifiedTax > 0) {
      poolManager.take(unspecifiedCurrency, address(clockGame), uint128(totalUnspecifiedTax));
    }

    (uint256 specifiedSwapTax, , uint256 specifiedVrfFee) = _getEthSpecifiedTaxDelta(key, params, usesVrf);

    uint256 swapTax = unspecifiedSwapTax > 0 ? unspecifiedSwapTax : specifiedSwapTax;
    uint256 vrfFee = specifiedVrfFee > 0 ? specifiedVrfFee : unspecifiedVrfFee;
    uint256 totalSwapTax = swapTax + vrfFee;

    if (isBuy && totalSwapTax > 0 && routerWhitelisted) {
      (uint256 tokenReceiveAmount, uint256 wethAmount) = _getBuyTokenAmountReceived(params, delta);
      uint256 totalSwapAmount = wethAmount + totalSwapTax;
      clockGame.handleBuy(originalCaller, totalSwapAmount, tokenReceiveAmount, swapTax, vrfFee);
    } else if (swapTax > 0 && (!usesVrf)) {
      // Distribute sells and buys through a non-whitelisted router to the game pools (no VRF request/game participation)
      clockGame.handleSwap(swapTax);
    }
    _emitAfterSwapEvent(key, originalCaller, params, delta, swapTax, vrfFee);
    return (BaseHook.afterSwap.selector, int128(int256(totalUnspecifiedTax)));
  }

  function _emitAfterSwapEvent(
    PoolKey calldata key,
    address originalCaller,
    SwapParams calldata params,
    BalanceDelta delta,
    uint256 swapTax,
    uint256 vrfFee
  ) internal {
    PoolId poolId = key.toId();
    (uint160 sqrtPriceX96, int24 tick, , ) = poolManager.getSlot0(poolId);
    uint128 liquidity = poolManager.getLiquidity(poolId);
    uint256 ethPerToken1e18 = _getEthPerToken(key, sqrtPriceX96);
    emit AfterSwap(
      poolId,
      originalCaller,
      params.zeroForOne,
      params.amountSpecified,
      delta.amount0(),
      delta.amount1(),
      sqrtPriceX96,
      liquidity,
      tick,
      swapTax,
      vrfFee,
      ethPerToken1e18
    );
  }

  function _getEthPerToken(PoolKey calldata key, uint160 sqrtPriceX96) private view returns (uint256) {
    bool wethIsToken0 = Currency.unwrap(key.currency0) == Currency.unwrap(WETH);
    uint256 price1Per0 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * 1e18, uint256(1) << 192);
    if (wethIsToken0) {
      return price1Per0 == 0 ? 0 : FullMath.mulDiv(1e18, 1e18, price1Per0);
    }
    return price1Per0;
  }

  function _abs(int256 x) private pure returns (uint256) {
    return uint256(x >= 0 ? x : -x);
  }
}
