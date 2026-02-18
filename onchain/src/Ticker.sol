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

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

import { IClockGame } from "./IClockGame.sol";

contract Ticker is ERC20, ERC20Permit, AccessControl {
  bytes32 public constant INITIALIZER_ROLE = keccak256("INITIALIZER_ROLE");

  string public constant NAME = "Ticker";
  string public constant SYMBOL = "TICKER";

  IClockGame public clockGame;

  constructor(uint256 initialSupply)
    ERC20(NAME, SYMBOL)
    ERC20Permit(NAME)
  {
    _grantRole(INITIALIZER_ROLE, msg.sender);
    _mint(msg.sender, initialSupply);
  }

  function initialize(IClockGame _clockGame) external onlyRole(INITIALIZER_ROLE) {
    require(address(clockGame) == address(0), "Already initialized");
    require(address(_clockGame) != address(0), "Invalid ClockGame address");
    clockGame = _clockGame;
    _revokeRole(INITIALIZER_ROLE, msg.sender); // contract becomes immutable
  }

  function _update(address from, address to, uint256 value) internal override {
    // to prevent flash loans from exploting the Clock Game, we lock the sender from
    // transferring tokens until their VRF is fulfilled (typically ~1 block)
    if (address(clockGame) != address(0)) {
      require(!clockGame.isLocked(from), "Awaiting VRF fulfillment");
    }

    super._update(from, to, value);
  }
}
