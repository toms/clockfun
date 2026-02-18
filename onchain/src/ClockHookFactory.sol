// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * $TICKER hook factory
 * by t0m.eth
 */
contract ClockHookFactory {
  event HookDeployed(address indexed hook, bytes32 indexed salt);

  function deployHookWithCustomArgs(bytes32 salt, bytes memory bytecode) external returns (address hook) {
    assembly {
      hook := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
    }
    
    require(hook != address(0), "ClockHookFactory: deployment failed");
    
    emit HookDeployed(hook, salt);
  }


  function computeHookAddress(bytes32 salt, bytes32 bytecodeHash) external view returns (address) {
    bytes32 hash = keccak256(
      abi.encodePacked(
        bytes1(0xff),
        address(this),
        salt,
        bytecodeHash
      )
    );
    
    return address(uint160(uint256(hash)));
  }

}
