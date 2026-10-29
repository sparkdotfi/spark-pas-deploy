// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test, Vm }   from "../lib/forge-std/src/Test.sol";
import { stdJson }    from "../lib/forge-std/src/StdJson.sol";

import { ScriptTools } from "../lib/dss-test/src/ScriptTools.sol";

import { IAccessControl }     from "../lib/pas/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { TimelockController } from "../lib/pas/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import { Pausable }           from "../lib/pas/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

import { BeamState }    from "../lib/pas/src/BeamState.sol";
import { Configurator } from "../lib/pas/src/Configurator.sol";
import { Timelock }     from "../lib/pas/src/timelock/Timelock.sol";

import { DeployPASBase, PASInstance } from "../deploy/Deploy.sol";

contract PASConfigurationTests is DeployPASBase, Test {

    using stdJson for string;

    string internal constant CONFIG_NAME = "deploy-pas-production";

    uint256 internal constant CHAIN_ID = 1;

    address internal constant PAS_OWNER        = 0xC758519Ace14E884fdbA9ccE25F2DbE81b7e136f;
    address internal constant PAS_CORE_COUNCIL = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    uint256 internal constant PAS_MIN_DELAY = 3 days;

    uint8 internal constant PAS_ROLE_DELAYED   = 1;  // BeamState actions routed through the Timelock
    uint8 internal constant PAS_ROLE_IMMEDIATE = 2;  // BeamState actions the Core Council can call directly

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /**********************************************************************************************/
    /*** Deployment                                                                             ***/
    /**********************************************************************************************/

    PASConfig internal cfg;

    address internal deployer;

    BeamState    internal beamState;
    Configurator internal configurator;
    Timelock     internal timelock;

    Vm.Log[] internal _deployLogs;

    function setUp() public {
        vm.createSelectFork(getChain("mainnet").rpcUrl);

        vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

        string memory config = ScriptTools.readInput(CONFIG_NAME);

        require(block.chainid == config.readUint(".chainId"), "PASConfigurationTests/invalid-chain-id");

        cfg = PASConfig({
            owner       : config.readAddress(".owner"),
            minDelay    : config.readUint(".minDelay"),
            coreCouncil : config.readAddress(".coreCouncil"),
            cancellers  : config.readAddressArray(".cancellers"),
            pausers     : config.readAddressArray(".pausers")
        });

        deployer = makeAddr("deployer");

        vm.recordLogs();

        vm.startPrank(deployer);
        PASInstance memory pas = _deployAndConfigurePAS(cfg, deployer);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; ++i) {
            _deployLogs.push(logs[i]);
        }

        beamState    = BeamState(pas.beamState);
        configurator = Configurator(pas.configurator);
        timelock     = Timelock(payable(pas.timelock));
    }

    /**********************************************************************************************/
    /*** Config                                                                                 ***/
    /**********************************************************************************************/

    function test_config() external view {
        assertEq(block.chainid, CHAIN_ID);

        assertEq(cfg.owner,       PAS_OWNER);
        assertEq(cfg.minDelay,    PAS_MIN_DELAY);
        assertEq(cfg.coreCouncil, PAS_CORE_COUNCIL);

        assertEq(cfg.cancellers.length, 1);
        assertEq(cfg.cancellers[0],     PAS_CORE_COUNCIL);

        assertEq(cfg.pausers.length, 1);
        assertEq(cfg.pausers[0],     PAS_CORE_COUNCIL);
    }

    /**********************************************************************************************/
    /*** Configurator                                                                           ***/
    /**********************************************************************************************/

    function test_configurator_state() external view {
        assertEq(address(configurator.beamState()), address(beamState));
    }

    /**********************************************************************************************/
    /*** BeamState                                                                              ***/
    /**********************************************************************************************/

    function test_beamState_stopped() external view {
        assertEq(beamState.stopped(), false);

        Vm.Log[] memory startLogs = _getEvents(address(beamState), BeamState.Start.selector);
        Vm.Log[] memory stopLogs  = _getEvents(address(beamState), BeamState.Stop.selector);

        assertEq(startLogs.length, 0);
        assertEq(stopLogs.length,  0);
    }

    function test_beamState_wards() external view {
        // BeamState admin: owner only, deployer is denied after configuration.

        assertEq(beamState.wards(PAS_OWNER), 1);
        assertEq(beamState.wards(deployer),  0);

        assertEq(beamState.wards(PAS_CORE_COUNCIL),  0);
        assertEq(beamState.wards(address(timelock)), 0);

        Vm.Log[] memory relyLogs = _getEvents(address(beamState), BeamState.Rely.selector);
        Vm.Log[] memory denyLogs = _getEvents(address(beamState), BeamState.Deny.selector);

        assertEq(relyLogs.length, 2);
        assertEq(denyLogs.length, 1);

        assertEq(relyLogs[0].topics[0],             BeamState.Rely.selector);
        assertEq(_toAddress(relyLogs[0].topics[1]), deployer);

        assertEq(relyLogs[1].topics[0],             BeamState.Rely.selector);
        assertEq(_toAddress(relyLogs[1].topics[1]), PAS_OWNER);

        assertEq(denyLogs[0].topics[0],             BeamState.Deny.selector);
        assertEq(_toAddress(denyLogs[0].topics[1]), deployer);
    }

    function test_beamState_userRoles() external view {
        // BeamState user roles: Timelock has delayed role, Core Council has immediate role.

        assertEq(beamState.hasUserRole(address(timelock), PAS_ROLE_DELAYED), true);
        assertEq(beamState.hasUserRole(PAS_CORE_COUNCIL,  PAS_ROLE_DELAYED), false);

        assertEq(beamState.hasUserRole(address(timelock), PAS_ROLE_IMMEDIATE), false);
        assertEq(beamState.hasUserRole(PAS_CORE_COUNCIL,  PAS_ROLE_IMMEDIATE), true);

        assertEq(beamState.hasUserRole(PAS_OWNER, PAS_ROLE_DELAYED),   false);
        assertEq(beamState.hasUserRole(PAS_OWNER, PAS_ROLE_IMMEDIATE), false);
        assertEq(beamState.hasUserRole(deployer,  PAS_ROLE_DELAYED),   false);
        assertEq(beamState.hasUserRole(deployer,  PAS_ROLE_IMMEDIATE), false);

        Vm.Log[] memory userRoleLogs = _getEvents(address(beamState), BeamState.SetUserRole.selector);

        assertEq(userRoleLogs.length, 2);

        assertEq(userRoleLogs[0].topics[0],                 BeamState.SetUserRole.selector);
        assertEq(_toAddress(userRoleLogs[0].topics[1]),     address(timelock));
        assertEq(uint8(uint256(userRoleLogs[0].topics[2])), PAS_ROLE_DELAYED);
        assertEq(abi.decode(userRoleLogs[0].data, (bool)),  true);

        assertEq(userRoleLogs[1].topics[0],                 BeamState.SetUserRole.selector);
        assertEq(_toAddress(userRoleLogs[1].topics[1]),     PAS_CORE_COUNCIL);
        assertEq(uint8(uint256(userRoleLogs[1].topics[2])), PAS_ROLE_IMMEDIATE);
        assertEq(abi.decode(userRoleLogs[1].data, (bool)),  true);
    }

    function test_beamState_actionRoles() external view {
        bytes4[18] memory actionSigs = _actionSigs();

        Vm.Log[] memory roleActionLogs = _getEvents(address(beamState), BeamState.SetRoleAction.selector);

        assertEq(roleActionLogs.length, 18);

        // First 8 actions are for DELAYED role
        for (uint256 i = 0; i < 8; i++) {
            assertEq(beamState.actionsRoles(actionSigs[i]), bytes32(uint256(1) << PAS_ROLE_DELAYED));

            assertEq(roleActionLogs[i].topics[0],                 BeamState.SetRoleAction.selector);
            assertEq(uint8(uint256(roleActionLogs[i].topics[1])), PAS_ROLE_DELAYED);
            assertEq(roleActionLogs[i].topics[2],                 bytes32(actionSigs[i]));
            assertEq(abi.decode(roleActionLogs[i].data, (bool)),  true);
        }

        // Next 10 actions are for IMMEDIATE role
        for (uint256 i = 8; i < 18; i++) {
            assertEq(beamState.actionsRoles(actionSigs[i]), bytes32(uint256(1) << PAS_ROLE_IMMEDIATE));

            assertEq(roleActionLogs[i].topics[0],                 BeamState.SetRoleAction.selector);
            assertEq(uint8(uint256(roleActionLogs[i].topics[1])), PAS_ROLE_IMMEDIATE);
            assertEq(roleActionLogs[i].topics[2],                 bytes32(actionSigs[i]));
            assertEq(abi.decode(roleActionLogs[i].data, (bool)),  true);
        }

        // Admin-only functions are not assigned to any role
        assertEq(beamState.actionsRoles(BeamState.rely.selector),          bytes32(0));
        assertEq(beamState.actionsRoles(BeamState.deny.selector),          bytes32(0));
        assertEq(beamState.actionsRoles(BeamState.setUserRole.selector),   bytes32(0));
        assertEq(beamState.actionsRoles(BeamState.setRoleAction.selector), bytes32(0));
    }

    function test_beamState_hop() external view {
        // No hop is configured at deployment, it is expected to be set through the Timelock.

        assertEq(beamState.hop(address(0)),    0);
        assertEq(beamState.getHop(address(0)), 0);

        assertEq(_getEvents(address(beamState), BeamState.SetHop.selector).length, 0);
    }

    function test_beamState_maxChange() external view {
        // No maxChange is configured at deployment, it is expected to be set through the Timelock.

        assertEq(beamState.maxChange(address(0)),    0);
        assertEq(beamState.getMaxChange(address(0)), 0);

        assertEq(_getEvents(address(beamState), BeamState.SetMaxChange.selector).length, 0);
    }

    function test_beamState_noRateLimitsControllersOrCBeams() external view {
        // No rateLimits, controllers, cBeams or init data are registered at deployment.

        assertEq(_getEvents(address(beamState), BeamState.AddRateLimits.selector).length,            0);
        assertEq(_getEvents(address(beamState), BeamState.DelRateLimits.selector).length,            0);
        assertEq(_getEvents(address(beamState), BeamState.AddController.selector).length,            0);
        assertEq(_getEvents(address(beamState), BeamState.DelController.selector).length,            0);
        assertEq(_getEvents(address(beamState), BeamState.AddCBeam.selector).length,                 0);
        assertEq(_getEvents(address(beamState), BeamState.DelCBeam.selector).length,                 0);
        assertEq(_getEvents(address(beamState), BeamState.SetCBeamForRateLimits.selector).length,    0);
        assertEq(_getEvents(address(beamState), BeamState.UnsetCBeamForRateLimits.selector).length,  0);
        assertEq(_getEvents(address(beamState), BeamState.SetCBeamForController.selector).length,    0);
        assertEq(_getEvents(address(beamState), BeamState.UnsetCBeamForController.selector).length,  0);
        assertEq(_getEvents(address(beamState), BeamState.AddInitRateLimits.selector).length,        0);
        assertEq(_getEvents(address(beamState), BeamState.DelInitRateLimits.selector).length,        0);
        assertEq(_getEvents(address(beamState), BeamState.AddInitControllerActions.selector).length, 0);
        assertEq(_getEvents(address(beamState), BeamState.DelInitControllerActions.selector).length, 0);
    }

    function test_beamState_events() external view {
        // Full ordered event sequence emitted by the BeamState during deployment:
        //   constructor, PASInit.init (18 role actions + 2 user roles), ownership handover.

        Vm.Log[] memory allEvents = _getEvents(address(beamState), bytes32(0));

        assertEq(allEvents.length, 23);

        assertEq(allEvents[0].topics[0],             BeamState.Rely.selector);
        assertEq(_toAddress(allEvents[0].topics[1]), deployer);

        for (uint256 i = 1; i < 19; i++) {
            assertEq(allEvents[i].topics[0], BeamState.SetRoleAction.selector);
        }

        assertEq(allEvents[19].topics[0],             BeamState.SetUserRole.selector);
        assertEq(_toAddress(allEvents[19].topics[1]), address(timelock));

        assertEq(allEvents[20].topics[0],             BeamState.SetUserRole.selector);
        assertEq(_toAddress(allEvents[20].topics[1]), PAS_CORE_COUNCIL);

        assertEq(allEvents[21].topics[0],             BeamState.Rely.selector);
        assertEq(_toAddress(allEvents[21].topics[1]), PAS_OWNER);

        assertEq(allEvents[22].topics[0],             BeamState.Deny.selector);
        assertEq(_toAddress(allEvents[22].topics[1]), deployer);
    }

    /**********************************************************************************************/
    /*** Timelock                                                                               ***/
    /**********************************************************************************************/

    function test_timelock_state() external view {
        assertEq(timelock.getMinDelay(),        PAS_MIN_DELAY);
        assertEq(timelock.paused(),             false);
        assertEq(timelock.getOperationsCount(), 0);

        // Admin: owner only, neither the deployer nor the timelock itself keep it.

        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE, PAS_OWNER),         true);
        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer),          false);
        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(timelock)), false);
        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE, PAS_CORE_COUNCIL),  false);

        // Core Council proposes, cancels and pauses; anyone can execute.

        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(),  PAS_CORE_COUNCIL), true);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), PAS_CORE_COUNCIL), true);
        assertEq(timelock.hasRole(timelock.PAUSER_ROLE(),    PAS_CORE_COUNCIL), true);
        assertEq(timelock.hasRole(timelock.EXECUTOR_ROLE(),  address(0)),       true);  // Anyone can execute

        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(),  deployer), false);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), deployer), false);
        assertEq(timelock.hasRole(timelock.PAUSER_ROLE(),    deployer), false);

        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(),  PAS_OWNER), false);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), PAS_OWNER), false);
        assertEq(timelock.hasRole(timelock.PAUSER_ROLE(),    PAS_OWNER), false);
    }

    function test_timelock_events() external view {
        bytes32 proposerRole  = timelock.PROPOSER_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        bytes32 executorRole  = timelock.EXECUTOR_ROLE();
        bytes32 pauserRole    = timelock.PAUSER_ROLE();

        Vm.Log[] memory allEvents = _getEvents(address(timelock), bytes32(0));

        assertEq(allEvents.length, 10);

        // Constructor

        _assertRoleGrantedEvent(allEvents[0], DEFAULT_ADMIN_ROLE, address(timelock), deployer);
        _assertRoleGrantedEvent(allEvents[1], DEFAULT_ADMIN_ROLE, deployer,          deployer);

        ( uint256 oldDuration, uint256 newDuration ) = abi.decode(allEvents[2].data, (uint256, uint256));

        assertEq(allEvents[2].topics[0], TimelockController.MinDelayChange.selector);
        assertEq(oldDuration,            0);
        assertEq(newDuration,            PAS_MIN_DELAY);

        _assertRoleRevokedEvent(allEvents[3], DEFAULT_ADMIN_ROLE, address(timelock), deployer);
        _assertRoleGrantedEvent(allEvents[4], executorRole,       address(0),        deployer);  // Anyone can execute

        // PASInit.init: coreCouncil is granted proposer and canceller, then cancellers and pausers.
        // The configured canceller is the coreCouncil itself, so no second CANCELLER_ROLE event.

        _assertRoleGrantedEvent(allEvents[5], proposerRole,  PAS_CORE_COUNCIL, deployer);
        _assertRoleGrantedEvent(allEvents[6], cancellerRole, PAS_CORE_COUNCIL, deployer);
        _assertRoleGrantedEvent(allEvents[7], pauserRole,    PAS_CORE_COUNCIL, deployer);

        // Admin handover

        _assertRoleGrantedEvent(allEvents[8], DEFAULT_ADMIN_ROLE, PAS_OWNER, deployer);
        _assertRoleRevokedEvent(allEvents[9], DEFAULT_ADMIN_ROLE, deployer,  deployer);

        // The timelock is never paused during deployment.

        assertEq(_getEvents(address(timelock), Pausable.Paused.selector).length, 0);
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _actionSigs() internal pure returns (bytes4[18] memory actionSigs) {
        // First 8 are for DELAYED role, next 10 are for IMMEDIATE role.
        actionSigs = [
            BeamState.start.selector,
            BeamState.setHop.selector,
            BeamState.setMaxChange.selector,
            BeamState.addRateLimits.selector,
            BeamState.addController.selector,
            BeamState.addCBeam.selector,
            BeamState.addInitRateLimits.selector,
            BeamState.addInitControllerActions.selector,
            BeamState.stop.selector,
            BeamState.delRateLimits.selector,
            BeamState.delController.selector,
            BeamState.delCBeam.selector,
            BeamState.setCBeamForRateLimits.selector,
            BeamState.unsetCBeamForRateLimits.selector,
            BeamState.setCBeamForController.selector,
            BeamState.unsetCBeamForController.selector,
            BeamState.delInitRateLimits.selector,
            BeamState.delInitControllerActions.selector
        ];
    }

    // Returns the logs emitted by `target` during deployment, optionally filtered by `topic0`
    // (zero means all events), in emission order.
    function _getEvents(address target, bytes32 topic0) internal view returns (Vm.Log[] memory logs) {
        uint256 count;

        for (uint256 i = 0; i < _deployLogs.length; ++i) {
            if (_matches(_deployLogs[i], target, topic0)) count++;
        }

        logs = new Vm.Log[](count);

        uint256 j;

        for (uint256 i = 0; i < _deployLogs.length; ++i) {
            if (_matches(_deployLogs[i], target, topic0)) logs[j++] = _deployLogs[i];
        }
    }

    function _matches(Vm.Log storage log, address target, bytes32 topic0) internal view returns (bool) {
        return log.emitter == target && (topic0 == bytes32(0) || log.topics[0] == topic0);
    }

    function _assertRoleGrantedEvent(Vm.Log memory log, bytes32 role, address account, address sender) internal pure {
        assertEq(log.topics[0],             IAccessControl.RoleGranted.selector);
        assertEq(log.topics[1],             role);
        assertEq(_toAddress(log.topics[2]), account);
        assertEq(_toAddress(log.topics[3]), sender);
    }

    function _assertRoleRevokedEvent(Vm.Log memory log, bytes32 role, address account, address sender) internal pure {
        assertEq(log.topics[0],             IAccessControl.RoleRevoked.selector);
        assertEq(log.topics[1],             role);
        assertEq(_toAddress(log.topics[2]), account);
        assertEq(_toAddress(log.topics[3]), sender);
    }

    function _toAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

}
