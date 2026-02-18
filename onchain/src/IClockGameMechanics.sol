// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IClockGameMechanics {
    function getJackpotOddsPPM(uint256 buyWei, uint256 poolBalanceWei) external view returns (uint256);
    function calculateTimeDelta(uint256 currentEndTimestamp, uint256 currentTimestamp) external view returns (uint256);
    function calculateExtensionProbabilityPPM(uint256 wethAmount, uint256 poolBalance) external view returns (uint256);
    function getRoundLength() external view returns (uint256);
    function randomizeJackpotAlpha(uint256 randomWord) external;
    function getJackpotCap() external view returns (uint256);
}
