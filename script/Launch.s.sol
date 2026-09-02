// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SignedPot} from "../src/SignedPot.sol";
import {PotConfig} from "../src/Config.sol";

interface IPonsFactory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function launchFee() external view returns (uint256);
}

interface ICurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// Step 2: launch FORM-4 on Pons V2 (pair ETH) with the pot as fee recipient,
/// bind the pot, and optionally dev-buy on the curve. Holding is sufficient.
///   POT=0x... DEV_BUY_ETH=0.01 forge script script/Launch.s.sol --rpc-url robinhood --broadcast
/// Env: PRIVATE_KEY, POT (deployed pot), optional DEV_BUY_ETH (ether, decimal string),
///      optional TOKEN_NAME / TOKEN_SYMBOL / TOKEN_DESC / TOKEN_LOGO / TWITTER / WEBSITE, CREATOR_TAX_BPS (default 200).
contract Launch is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(vm.addr(pk) == PotConfig.DEV, "PRIVATE_KEY is not the DEV wallet");
        SignedPot pot = SignedPot(payable(vm.envAddress("POT")));
        require(address(pot.token()) == address(0), "pot already bound");
        require(pot.DEPLOYER() == PotConfig.DEV, "pot DEPLOYER mismatch");
        IPonsFactory factory = IPonsFactory(PotConfig.PONS_FACTORY);

        IPonsFactory.TokenParams memory p;
        p.name = vm.envOr("TOKEN_NAME", string("FORM-4"));
        p.symbol = vm.envOr("TOKEN_SYMBOL", string("FORM4"));
        p.description = vm.envOr("TOKEN_DESC", string("They signed for it. So did we. Trading fees buy the stock the insider just bought. Hold FORM4, claim the stock."));
        p.logo = vm.envOr("TOKEN_LOGO", string(""));
        p.socials.twitter = vm.envOr("TWITTER", string(""));
        p.socials.website = vm.envOr("WEBSITE", string(""));
        p.creatorFeeRecipient = address(pot);
        p.creatorTaxBps = uint16(vm.envOr("CREATOR_TAX_BPS", uint256(200)));
        p.buybackEnabled = false;

        uint256 devBuy = vm.envOr("DEV_BUY_ETH", uint256(0));
        uint256 fee = factory.launchFee();

        vm.startBroadcast(pk);
        (address token, address curve) = factory.launchToken{value: fee}(p, 0, address(0));
        pot.bind(token);
        if (devBuy > 0) {
            ICurve(curve).buy{value: devBuy}(devBuy, 0, PotConfig.DEV);
        }
        vm.stopBroadcast();

        console2.log("FORM-4 token:", token);
        console2.log("curve:", curve);
        console2.log("pot bound to:", address(pot.token()));
        console2.log("dev holder balance:", IERC20(token).balanceOf(PotConfig.DEV));
    }
}
