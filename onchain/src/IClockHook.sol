// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IClockHook {
  function setTaxStartTimestamp(uint256 ts) external;
}
