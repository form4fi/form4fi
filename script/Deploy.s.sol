// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SignedPot} from "../src/SignedPot.sol";
import {PotConfig} from "../src/Config.sol";

/// Step 1: deploy the pot. Nothing else. Run BEFORE launching on Pons.
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast
contract Deploy is Script {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(vm.addr(pk) == PotConfig.DEV, "PRIVATE_KEY is not the DEV wallet baked into Config.sol");
        require(NVDA.codehash == PotConfig.STOCK_CODEHASH, "STOCK_CODEHASH does not match NVDA on this chain");
        vm.startBroadcast(pk);
        SignedPot pot = new SignedPot(PotConfig.get());
        vm.stopBroadcast();
        console2.log("SignedPot:", address(pot));
        console2.log("operator:", pot.DEPLOYER());
    }
}
