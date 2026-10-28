// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ScriptTools } from "../lib/dss-test/src/ScriptTools.sol";

import { PASDeploy, PASInstance } from "../lib/pas/deploy/PASDeploy.sol";
import { PASInit }                from "../lib/pas/deploy/PASInit.sol";

interface ITimelockLike {

    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

}

contract DeployPASBase {

    struct PASConfig {
        address   owner;
        uint256   minDelay;
        address   coreCouncil;
        address[] cancellers;
        address[] pausers;
    }

    function _deployAndConfigurePAS(address deployer, PASConfig memory cfg) internal returns (PASInstance memory pas) {
        pas = PASDeploy.deploy({
            deployer : deployer,
            owner    : deployer,
            minDelay : cfg.minDelay
        });

        PASInit.init({
            pasInstance : pas,
            minDelay    : cfg.minDelay,
            coreCouncil : cfg.coreCouncil,
            cancellers  : cfg.cancellers,
            pausers     : cfg.pausers
        });

        ScriptTools.switchOwner(pas.beamState, deployer, cfg.owner);

        ITimelockLike timelock = ITimelockLike(pas.timelock);

        bytes32 defaultAdminRole = timelock.DEFAULT_ADMIN_ROLE();

        timelock.grantRole(defaultAdminRole,  cfg.owner);
        timelock.revokeRole(defaultAdminRole, deployer);
    }

}
