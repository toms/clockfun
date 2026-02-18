// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IClockGame {
  struct ClockVrfConfig {
    uint256 vrfSubscriptionId;
    bytes32 vrfKeyHash;
    uint32 vrfCallbackGasLimit;
    uint16 vrfRequestConfirmations;
  }

  function handleBuy(address buyerAddress, uint256 wethAmount, uint256 tokenAmount, uint256 taxAmount, uint256 vrfFee) external payable;
  function handleSwap(uint256 taxAmount) external;
  function getVRFFee() external view returns (uint256);
  function isLocked(address buyerAddress) external view returns (bool);
  function startGame() external;
  function setVrfConfig(ClockVrfConfig calldata _vrfConfig) external;
  function getVrfConfig() external view returns (ClockVrfConfig memory);
}