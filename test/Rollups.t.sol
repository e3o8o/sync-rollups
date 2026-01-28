// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Rollups, Action, ActionType, Execution, StateDelta, StateCommitment} from "../src/Rollups.sol";
import {L2Proxy} from "../src/L2Proxy.sol";
import {IZKVerifier} from "../src/IZKVerifier.sol";

/// @notice Mock ZK verifier that always returns true
contract MockZKVerifier is IZKVerifier {
    bool public shouldVerify = true;

    function setVerifyResult(bool _shouldVerify) external {
        shouldVerify = _shouldVerify;
    }

    function verify(bytes calldata, bytes32) external view override returns (bool) {
        return shouldVerify;
    }
}

/// @notice Simple target contract for testing
contract TestTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }
}

contract RollupsTest is Test {
    Rollups public rollups;
    MockZKVerifier public verifier;
    TestTarget public target;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    bytes32 constant DEFAULT_VK = keccak256("verificationKey");

    function setUp() public {
        verifier = new MockZKVerifier();
        rollups = new Rollups(address(verifier), 1);
        target = new TestTarget();
    }

    function _getRollupState(uint256 rollupId) internal view returns (bytes32) {
        (,, bytes32 stateRoot,) = rollups.rollups(rollupId);
        return stateRoot;
    }

    function _getRollupOwner(uint256 rollupId) internal view returns (address) {
        (address owner,,,) = rollups.rollups(rollupId);
        return owner;
    }

    function _getRollupVK(uint256 rollupId) internal view returns (bytes32) {
        (, bytes32 vk,,) = rollups.rollups(rollupId);
        return vk;
    }

    function _getRollupEtherBalance(uint256 rollupId) internal view returns (uint256) {
        (,,, uint256 etherBalance) = rollups.rollups(rollupId);
        return etherBalance;
    }

    function test_CreateRollup() public {
        bytes32 initialState = keccak256("initial");
        uint256 rollupId = rollups.createRollup(initialState, DEFAULT_VK, alice);
        assertEq(rollupId, 1);

        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);
        assertEq(rollupId2, 2);

        // Check initial state
        assertEq(_getRollupState(rollupId), initialState);
        assertEq(_getRollupOwner(rollupId), alice);
        assertEq(_getRollupVK(rollupId), DEFAULT_VK);

        // Check second rollup has zero state
        assertEq(_getRollupState(rollupId2), bytes32(0));
        assertEq(_getRollupOwner(rollupId2), bob);
    }

    function test_CreateL2ProxyContract() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        address targetAddr = address(0x1234);
        address proxy = rollups.createL2ProxyContract(targetAddr, rollupId);

        // Verify proxy is authorized
        assertTrue(rollups.authorizedProxies(proxy));

        // Verify proxy code was deployed (clone should have ~125 bytes)
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(proxy)
        }
        assertTrue(codeSize > 0);
    }

    function test_ComputeL2ProxyAddress() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        address targetAddr = address(0x5678);

        // Compute address before deployment
        address computedAddr = rollups.computeL2ProxyAddress(targetAddr, rollupId, block.chainid);

        // Deploy and verify addresses match
        address actualAddr = rollups.createL2ProxyContract(targetAddr, rollupId);

        assertEq(computedAddr, actualAddr);
    }

    function test_PostBatch() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("new state");

        // Create state commitments array
        StateCommitment[] memory commitments = new StateCommitment[](1);
        commitments[0] = StateCommitment({
            rollupId: rollupId,
            newState: newState,
            etherIncrement: 0
        });

        // Post batch with proof (no blobs, no calldata)
        rollups.postBatch(commitments, 0, "", "proof");

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_PostBatch_MultipleRollups() public {
        uint256 rollupId1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollupId2 = rollups.createRollup(bytes32(0), DEFAULT_VK, bob);
        bytes32 newState1 = keccak256("new state 1");
        bytes32 newState2 = keccak256("new state 2");

        // Create state commitments array for both rollups
        StateCommitment[] memory commitments = new StateCommitment[](2);
        commitments[0] = StateCommitment({
            rollupId: rollupId1,
            newState: newState1,
            etherIncrement: 0
        });
        commitments[1] = StateCommitment({
            rollupId: rollupId2,
            newState: newState2,
            etherIncrement: 0
        });

        // Post batch with proof
        rollups.postBatch(commitments, 0, "shared data", "proof");

        assertEq(_getRollupState(rollupId1), newState1);
        assertEq(_getRollupState(rollupId2), newState2);
    }

    function test_PostBatch_InvalidProof() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("new state");

        // Create state commitments array
        StateCommitment[] memory commitments = new StateCommitment[](1);
        commitments[0] = StateCommitment({
            rollupId: rollupId,
            newState: newState,
            etherIncrement: 0
        });

        // Make verifier reject proofs
        verifier.setVerifyResult(false);

        vm.expectRevert(Rollups.InvalidProof.selector);
        rollups.postBatch(commitments, 0, "", "bad proof");
    }

    function test_PostBatch_AfterL2ExecutionSameBlockReverts() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Create proxy
        address proxyAddr = rollups.createL2ProxyContract(address(target), rollupId);

        bytes32 currentState = bytes32(0);
        bytes32 newState = keccak256("state1");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddr,
            sourceRollup: rollupId
        });

        Action memory nextAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0
        });

        // Create state deltas array
        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: rollupId,
            currentState: currentState,
            newState: newState,
            etherDelta: 0
        });

        // Load execution
        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = nextAction;
        rollups.loadL2Executions(executions, "proof");

        // Execute L2 via proxy fallback
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);
        assertEq(_getRollupState(rollupId), newState);

        // Now try to call postBatch in the same block - should revert
        StateCommitment[] memory commitments = new StateCommitment[](1);
        commitments[0] = StateCommitment({
            rollupId: rollupId,
            newState: keccak256("another state"),
            etherIncrement: 0
        });

        vm.expectRevert(Rollups.StateAlreadyUpdatedThisBlock.selector);
        rollups.postBatch(commitments, 0, "", "proof");

        // State should remain unchanged from L2 execution
        assertEq(_getRollupState(rollupId), newState);
    }

    function test_SetStateByOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("owner set state");

        // Owner can set state without proof
        vm.prank(alice);
        rollups.setStateByOwner(rollupId, newState);

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_SetStateByOwner_NotOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newState = keccak256("owner set state");

        // Non-owner cannot set state
        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setStateByOwner(rollupId, newState);
    }

    function test_SetVerificationKey() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("new verification key");

        // Owner can update verification key
        vm.prank(alice);
        rollups.setVerificationKey(rollupId, newVK);

        assertEq(_getRollupVK(rollupId), newVK);
    }

    function test_SetVerificationKey_NotOwner() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        bytes32 newVK = keccak256("new verification key");

        // Non-owner cannot update verification key
        vm.prank(bob);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setVerificationKey(rollupId, newVK);
    }

    function test_TransferRollupOwnership() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Transfer ownership
        vm.prank(alice);
        rollups.transferRollupOwnership(rollupId, bob);

        assertEq(_getRollupOwner(rollupId), bob);

        // New owner can now update state
        vm.prank(bob);
        rollups.setStateByOwner(rollupId, keccak256("bob's state"));

        // Old owner cannot
        vm.prank(alice);
        vm.expectRevert(Rollups.NotRollupOwner.selector);
        rollups.setStateByOwner(rollupId, keccak256("alice's state"));
    }

    function test_LoadL2Executions() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Compute proxy address first (needed for action hash)
        address proxyAddr = rollups.computeL2ProxyAddress(address(target), rollupId, block.chainid);

        bytes32 currentState = bytes32(0);
        bytes32 newState = keccak256("state1");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddr,
            sourceRollup: rollupId
        });

        Action memory nextAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0
        });

        // Create state deltas array
        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: rollupId,
            currentState: currentState,
            newState: newState,
            etherDelta: 0
        });

        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = nextAction;

        rollups.loadL2Executions(executions, "proof");

        // Create and verify execution works via proxy fallback
        address actualProxyAddr = rollups.createL2ProxyContract(address(target), rollupId);
        assertEq(proxyAddr, actualProxyAddr); // Verify computed address matches
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);

        assertEq(_getRollupState(rollupId), newState);
    }

    function test_LoadL2Executions_InvalidProof() public {
        verifier.setVerifyResult(false);

        Execution[] memory executions = new Execution[](0);

        vm.expectRevert(Rollups.InvalidProof.selector);
        rollups.loadL2Executions(executions, "bad proof");
    }

    function test_ExecuteL2Execution() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Create proxy
        address proxyAddr = rollups.createL2ProxyContract(address(target), rollupId);

        bytes32 currentState = bytes32(0);
        bytes32 newState = keccak256("state1");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (42));

        Action memory action = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddr,
            sourceRollup: rollupId
        });

        Action memory nextAction = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0
        });

        // Create state deltas array
        StateDelta[] memory stateDeltas = new StateDelta[](1);
        stateDeltas[0] = StateDelta({
            rollupId: rollupId,
            currentState: currentState,
            newState: newState,
            etherDelta: 0
        });

        // Load execution
        Execution[] memory executions = new Execution[](1);
        executions[0].stateDeltas = stateDeltas;
        executions[0].actionHash = keccak256(abi.encode(action));
        executions[0].nextAction = nextAction;
        rollups.loadL2Executions(executions, "proof");

        // Execute via proxy fallback
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);

        // Verify state was updated
        assertEq(_getRollupState(rollupId), newState);
    }

    function test_ExecuteL2Execution_UnauthorizedProxy() public {
        rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        bytes32 actionHash = keccak256("some action");

        // Try to call directly (not from proxy)
        vm.expectRevert(Rollups.UnauthorizedProxy.selector);
        rollups.executeL2Execution(actionHash);
    }

    function test_ExecuteL2Execution_ExecutionNotFound() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Create proxy
        address proxyAddr = rollups.createL2ProxyContract(address(target), rollupId);

        // Try to execute without loading execution - call via fallback
        bytes memory callData = abi.encodeCall(TestTarget.setValue, (999));
        vm.expectRevert(Rollups.ExecutionNotFound.selector);
        (bool success,) = proxyAddr.call(callData);
        success; // silence unused variable warning
    }

    function test_ExecuteL2Execution_WithCall() public {
        uint256 rollupId = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        // Create proxy
        address proxyAddr = rollups.createL2ProxyContract(address(target), rollupId);

        bytes32 currentState = bytes32(0);
        bytes32 state1 = keccak256("state1");
        bytes32 state2 = keccak256("state2");

        bytes memory callData = abi.encodeCall(TestTarget.setValue, (100));

        // First action: initial CALL
        Action memory action1 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: callData,
            failed: false,
            sourceAddress: proxyAddr,
            sourceRollup: rollupId
        });

        // Next action after first CALL: another CALL to setValue(200)
        Action memory action2 = Action({
            actionType: ActionType.CALL,
            rollupId: rollupId,
            destination: address(target),
            value: 0,
            data: abi.encodeCall(TestTarget.setValue, (200)),
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0
        });

        // Result action from the second CALL (setValue returns nothing, so empty data)
        Action memory resultAction = Action({
            actionType: ActionType.RESULT,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0
        });

        // Final result action
        Action memory finalResult = Action({
            actionType: ActionType.RESULT,
            rollupId: 0,
            destination: address(0),
            value: 0,
            data: "",
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0
        });

        // State deltas for first execution
        StateDelta[] memory stateDeltas1 = new StateDelta[](1);
        stateDeltas1[0] = StateDelta({
            rollupId: rollupId,
            currentState: currentState,
            newState: state1,
            etherDelta: 0
        });

        // State deltas for second execution
        StateDelta[] memory stateDeltas2 = new StateDelta[](1);
        stateDeltas2[0] = StateDelta({
            rollupId: rollupId,
            currentState: state1,
            newState: state2,
            etherDelta: 0
        });

        // Load both executions
        Execution[] memory executions = new Execution[](2);

        // First execution: CALL -> next CALL
        executions[0].stateDeltas = stateDeltas1;
        executions[0].actionHash = keccak256(abi.encode(action1));
        executions[0].nextAction = action2;

        // Second execution: RESULT from setValue(200) -> final RESULT
        executions[1].stateDeltas = stateDeltas2;
        executions[1].actionHash = keccak256(abi.encode(resultAction));
        executions[1].nextAction = finalResult;

        rollups.loadL2Executions(executions, "proof");

        // Execute via fallback - should call target.setValue(200) from nextAction
        (bool success,) = proxyAddr.call(callData);
        assertTrue(success);

        // Verify the nextAction was executed
        assertEq(target.getValue(), 200);

        // Verify final state
        assertEq(_getRollupState(rollupId), state2);
    }

    function test_StartingRollupId() public {
        // Create new rollups contract with different starting ID
        Rollups rollups2 = new Rollups(address(verifier), 1000);

        uint256 rollupId = rollups2.createRollup(bytes32(0), DEFAULT_VK, alice);
        assertEq(rollupId, 1000);

        uint256 rollupId2 = rollups2.createRollup(bytes32(0), DEFAULT_VK, alice);
        assertEq(rollupId2, 1001);
    }

    function test_MultipleProxiesSameTarget() public {
        uint256 rollup1 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);
        uint256 rollup2 = rollups.createRollup(bytes32(0), DEFAULT_VK, alice);

        address targetAddr = address(0x9999);

        address proxy1 = rollups.createL2ProxyContract(targetAddr, rollup1);
        address proxy2 = rollups.createL2ProxyContract(targetAddr, rollup2);

        // Different rollup IDs should create different proxy addresses
        assertTrue(proxy1 != proxy2);

        // Both should be authorized
        assertTrue(rollups.authorizedProxies(proxy1));
        assertTrue(rollups.authorizedProxies(proxy2));
    }

    function test_RollupWithCustomInitialState() public {
        bytes32 customState = keccak256("custom initial state");
        bytes32 customVK = keccak256("custom vk");

        uint256 rollupId = rollups.createRollup(customState, customVK, bob);

        assertEq(_getRollupState(rollupId), customState);
        assertEq(_getRollupVK(rollupId), customVK);
        assertEq(_getRollupOwner(rollupId), bob);
    }
}
