// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SignedPot} from "./SignedPot.sol";

/// @notice The frozen constructor config. One place, used by tests and the deploy script.
library PotConfig {
    address internal constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant PONS_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address internal constant UNI_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant DEV = 0x0F3807c87C4B1bBA350A3C37530aE4635407fd8D;
    /// Runtime codehash of every Robinhood stock token (beacon proxy). Fingerprinted
    /// on chain by scripts/build_allowlist.py; NVDA, AAPL, TSLA... all match.
    bytes32 internal constant STOCK_CODEHASH = 0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630;

    function get() internal pure returns (SignedPot.Config memory c) {
        c.factory = PONS_FACTORY;
        c.escrow = PONS_ESCROW;
        c.v3Factory = UNI_V3_FACTORY;
        c.weth = WETH;
        c.usdg = USDG;
        c.deployer = DEV;
        c.stockCodehash = STOCK_CODEHASH;
        c.buyInterval = 1 hours;
        c.minSpendBps = 2500; // a buy must spend >= 25% of the pot
        c.minSpendWei = 0.001 ether;
        // Long enough that nobody loses stock by not checking in; short enough
        // that a dead round's remainder gets back to holders in the same year.
        c.claimWindow = 90 days;
        // A fifth of every harvest pays to deliver the stock; four fifths buy
        // it. Buys cannot touch the reserve, so a push always has fuel.
        c.reserveBps = 2000;
        // ~0.00005 ETH a head. Measured cost is ~67k gas, about 0.000026 ETH at
        // 0.39 gwei, so this is roughly 2x headroom for gas rises and real
        // proof calldata. If it ever under-covers we top up ourselves.
        c.gasPerPayout = 0.00005 ether;
    }
}
