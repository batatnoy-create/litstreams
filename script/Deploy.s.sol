// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LitStreams} from "../contracts/LitStreams.sol";

/// @notice Deploys LitStreams from the account whose key is in `PRIVATE_KEY`.
/// @dev Without `--broadcast` this is a dry run: it simulates against the RPC and sends nothing.
///      Run: forge script script/Deploy.s.sol --rpc-url $RPC_URL            (dry run)
///           forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast (real deploy)
contract Deploy is Script {
    function run() external returns (LitStreams deployed) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("Chain id:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Deployer balance (wei):", deployer.balance);

        vm.startBroadcast(pk);
        deployed = new LitStreams();
        vm.stopBroadcast();

        console.log("LitStreams:", address(deployed));
    }
}
