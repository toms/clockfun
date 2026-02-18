// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ud, unwrap } from "@prb/math/src/UD60x18.sol";

import { IClockGameMechanics } from "./IClockGameMechanics.sol";
import { IClockGame } from "./IClockGame.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * $TICKER game mechanics
 * by t0m.eth
 */
contract ClockGameMechanics is IClockGameMechanics, AccessControl {
  bytes32 public constant INITIALIZER_ROLE = keccak256("INITIALIZER_ROLE");

  IClockGame public clockGame;

  // Extension probability parameters
  uint256 public constant K_POWER_LAW = 650_000_000_000_000_000; // k = 0.650
  uint256 public constant MIN_PCT = 150_000_000_000_000; // 0.015%
  uint256 public constant PIVOT_C0 = 1 ether;
  uint256 public constant PRECISION_DENOMINATOR = 10_000_000;

  uint256 public constant EXTENSION_DELTA = 120 seconds;
  uint256 public constant ROUND_LENGTH = 24 hours;

  // jackpot params
  uint256 public constant jackpotMaxOddsPercent = 50; // max odds of winning the jackpot (1-100)
  uint256 public constant jackpotCap = 1000 ether; // max size of the jackpot pool
  uint256 public constant jackpotStartRange = 100;
  uint256 public constant jackpotEndRange = 1000;
  uint256 public jackpotAlpha = 150 ether; // tuning constant (wei)

  event JackpotOddsRandomized(uint256 newJackpotAlpha);

  modifier onlyClockGame() {
    require(msg.sender == address(clockGame), "Only ClockGame can call this function");
    _;
  }

  constructor(address _deployer) {
    require(_deployer != address(0), "Invalid deployer");
    _grantRole(INITIALIZER_ROLE, _deployer);
  }

  function initialize(IClockGame _clockGame) external onlyRole(INITIALIZER_ROLE) {
    require(address(clockGame) == address(0), "Already initialized");
    clockGame = _clockGame;
    _revokeRole(INITIALIZER_ROLE, msg.sender); // contract becomes immutable
  }

  function randomizeJackpotAlpha(uint256 randomWord) external onlyClockGame override {
    uint256 emRandom = (randomWord >> 48) % (jackpotEndRange - jackpotStartRange + 1);
    jackpotAlpha = (jackpotStartRange + emRandom) * 1 ether;
    emit JackpotOddsRandomized(jackpotAlpha);
  }

  function getJackpotOddsPPM(uint256 buyAmount, uint256 poolBalance) external view override returns (uint256) {
    if (buyAmount == 0 || poolBalance == 0) return 0;

    uint256 baseOddsPPM = (buyAmount * PRECISION_DENOMINATOR) / (poolBalance + buyAmount);
    uint256 cappedOddsPPM = _getCappedJackpotOddsPPM(poolBalance);

    return baseOddsPPM > cappedOddsPPM ? cappedOddsPPM : baseOddsPPM;
  }

  function _getCappedJackpotOddsPPM(uint256 poolBalanceWei) internal view returns (uint256) {
    uint256 maxOddsPPM = (jackpotMaxOddsPercent * PRECISION_DENOMINATOR) / 100;
    uint256 scaledPPM = (poolBalanceWei * jackpotMaxOddsPercent * PRECISION_DENOMINATOR) / (jackpotAlpha * 100);
    if (scaledPPM > maxOddsPPM) {
      return maxOddsPPM;
    }
    return scaledPPM;
  }

  function calculateTimeDelta(uint256 currentEndTimestamp, uint256 currentTimestamp) external pure override returns (uint256) {
    uint256 cap = currentTimestamp + ROUND_LENGTH;
    if (currentEndTimestamp >= cap) {
      return 0;
    }
    uint256 remainingTime = cap - currentEndTimestamp;
    return remainingTime < EXTENSION_DELTA ? remainingTime : EXTENSION_DELTA;
  }

  function calculateExtensionProbabilityPPM(uint256 buyAmount, uint256 poolBalance) external pure override returns (uint256) {
    if (poolBalance == 0) return 0;
    uint256 x100;
    if (poolBalance < PIVOT_C0) {
      x100 = unwrap(ud(poolBalance).mul(ud(MIN_PCT)));
    } else {
      x100 = unwrap(ud(poolBalance).pow(ud(K_POWER_LAW)).mul(ud(MIN_PCT)));
    }
    if (x100 == 0 || buyAmount >= x100) {
      return PRECISION_DENOMINATOR;
    }
    uint256 probPPM = (buyAmount * PRECISION_DENOMINATOR) / x100;
    return probPPM;
  }

  function getRoundLength() external pure override returns (uint256) {
    return ROUND_LENGTH;
  }

  function getJackpotCap() external pure override returns (uint256) {
    return jackpotCap;
  }
}

