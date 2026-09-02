// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SignedPot} from "../src/SignedPot.sol";
import {PotConfig} from "../src/Config.sol";

interface IPonsFactory {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// After a MANUAL Pons launch from the dev wallet: point fees at the pot if the UI
/// did not, and bind the pot to the token. Holders never stake.
///   POT=0x... TOKEN=0x... forge script script/Bind.s.sol --rpc-url robinhood --broadcast
/// Env: PRIVATE_KEY, POT, TOKEN, optional FIX_RECIPIENT=1 (call transferCreatorFeeRecipient first),
///      no staking or token approval is required.
contract Bind is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(vm.addr(pk) == PotConfig.DEV, "PRIVATE_KEY is not the DEV wallet");
        SignedPot pot = SignedPot(payable(vm.envAddress("POT")));
        address token = vm.envAddress("TOKEN");
        bool fixRecipient = vm.envOr("FIX_RECIPIENT", uint256(0)) == 1;

        vm.startBroadcast(pk);
        if (fixRecipient) {
            IPonsFactory(PotConfig.PONS_FACTORY).transferCreatorFeeRecipient(token, address(pot));
        }
        if (address(pot.token()) == address(0)) pot.bind(token);
        vm.stopBroadcast();

        console2.log("pot bound to:", address(pot.token()));
        console2.log("dev holder balance:", IERC20(token).balanceOf(PotConfig.DEV));
    }
}
