// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { console2 }        from "lib/forge-std/src/console2.sol";
import { Script, stdJson } from "lib/forge-std/src/Script.sol";

import { ScriptTools } from "lib/dss-test/src/ScriptTools.sol";

import { PASDeploy, PASInstance } from "lib/pas/deploy/PASDeploy.sol";
import { PASInit }                from "lib/pas/deploy/PASInit.sol";

contract DeployPAS is Script {

    using stdJson     for string;
    using ScriptTools for string;

    function run() public {
        _setRHChainFork();

        string memory chain = vm.envOr("CHAIN", string("mainnet"));

        vm.createSelectFork(getChain(chain).rpcUrl);

        vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

        string memory env      = vm.envString("ENV");
        string memory fileSlug = string(abi.encodePacked("deploy-pas-", env));
        string memory config   = ScriptTools.loadConfig(fileSlug);

        require(block.chainid == config.readUint(".chainId"), "DeployPAS/Invalid chain ID");

        vm.startBroadcast();

        PASInstance memory pas = PASDeploy.deploy({
            deployer : msg.sender,
            owner    : msg.sender,
            minDelay : config.readUint(".minDelay")
        });

        PASInit.init({
            pasInstance : pas,
            minDelay    : config.readUint(".minDelay"),
            coreCouncil : config.readAddress(".coreCouncil"),
            cancellers  : config.readAddressArray(".cancellers"),
            pausers     : config.readAddressArray(".pausers")
        });

        vm.stopBroadcast();

        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("beamState")),    address(pas.beamState));
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("configurator")), address(pas.configurator));
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("timelock")),     address(pas.timelock));
    }

    function _setRHChainFork() internal {
        setChain("robinhood_chain", ChainData({
            name    : "Robinhood Chain",
            rpcUrl  : vm.envString("RH_RPC_URL"),
            chainId : 4663
        }));
    }

}
