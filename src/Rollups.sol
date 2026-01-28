// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZKVerifier} from "./IZKVerifier.sol";
import {L2Proxy} from "./L2Proxy.sol";
import {Proxy} from "./Proxy.sol";

/// @notice Action type enum
enum ActionType {
    CALL,
    RESULT,
    L2TX
}

/// @notice Represents an action in the state transition
/// @dev For CALL: rollupId, destination, value, data (callData), sourceAddress, and sourceRollup are used
/// @dev For RESULT: failed and data (returnData) are used
/// @dev For L2TX: rollupId and data (rlpEncodedTx) are used
struct Action {
    ActionType actionType;
    uint256 rollupId;
    address destination;
    uint256 value;
    bytes data;
    bool failed;
    address sourceAddress;
    uint256 sourceRollup;
}

/// @notice Represents a state delta for a single rollup (before/after snapshot)
struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;
}

/// @notice Represents a state commitment for a rollup (used in postBatch)
struct StateCommitment {
    uint256 rollupId;
    bytes32 newState;
    int256 etherIncrement;
}

/// @notice Represents a pre-computed execution that can affect multiple rollups
struct Execution {
    StateDelta[] stateDeltas;
    bytes32 actionHash;
    Action nextAction;
}

/// @notice Rollup configuration
struct RollupConfig {
    address owner;
    bytes32 verificationKey;
    bytes32 stateRoot;
    uint256 etherBalance;
}

/// @title Rollups
/// @notice Main contract for L1/L2 rollup synchronization
/// @dev Manages rollup state roots and L2 execution transitions
contract Rollups {
    /// @notice The ZK verifier contract
    IZKVerifier public immutable zkVerifier;

    /// @notice The L2Proxy implementation contract
    address public immutable l2ProxyImplementation;

    /// @notice Counter for generating rollup IDs
    uint256 public rollupCounter;

    /// @notice Mapping from rollup ID to rollup configuration
    mapping(uint256 rollupId => RollupConfig config) public rollups;

    /// @notice Mapping from action hash to array of pre-computed executions
    mapping(bytes32 actionHash => Execution[] executions) internal _executions;

    /// @notice Mapping of authorized L2Proxy contracts
    mapping(address proxy => bool authorized) public authorizedProxies;

    /// @notice Last block number when state was modified
    uint256 public lastStateUpdateBlock;

    /// @notice Emitted when a new rollup is created
    event RollupCreated(uint256 indexed rollupId, address indexed owner, bytes32 verificationKey, bytes32 initialState);

    /// @notice Emitted when a rollup state is updated
    event StateUpdated(uint256 indexed rollupId, bytes32 newStateRoot);

    /// @notice Emitted when a rollup verification key is updated
    event VerificationKeyUpdated(uint256 indexed rollupId, bytes32 newVerificationKey);

    /// @notice Emitted when a rollup owner is transferred
    event OwnershipTransferred(uint256 indexed rollupId, address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a new L2Proxy is created
    event L2ProxyCreated(address indexed proxy, address indexed originalAddress, uint256 indexed originalRollupId);

    /// @notice Emitted when executions are loaded
    event ExecutionsLoaded(uint256 count);

    /// @notice Emitted when an L2 execution is performed
    event L2ExecutionPerformed(uint256 indexed rollupId, bytes32 currentState, bytes32 newState);

    /// @notice Error when proof verification fails
    error InvalidProof();

    /// @notice Error when caller is not an authorized proxy
    error UnauthorizedProxy();

    /// @notice Error when execution is not found
    error ExecutionNotFound();

    /// @notice Error when rollup does not exist
    error RollupNotFound();

    /// @notice Error when caller is not the rollup owner
    error NotRollupOwner();

    /// @notice Error when updateStates is called more than once in the same block
    error StateAlreadyUpdatedThisBlock();

    /// @notice Error when the sum of ether increments is not zero
    error EtherIncrementsSumNotZero();

    /// @notice Error when a rollup would have negative ether balance
    error InsufficientRollupBalance();

    /// @notice Error when ether transfer fails
    error EtherTransferFailed();

    /// @notice Error when a call execution fails
    error CallExecutionFailed();

    /// @param _zkVerifier The ZK verifier contract address
    /// @param startingRollupId The starting ID for rollup numbering
    constructor(address _zkVerifier, uint256 startingRollupId) {
        zkVerifier = IZKVerifier(_zkVerifier);
        rollupCounter = startingRollupId;
        l2ProxyImplementation = address(new L2Proxy());
    }

    /// @notice Creates a new rollup
    /// @param initialState The initial state root for the rollup
    /// @param verificationKey The verification key for state transition proofs
    /// @param owner The owner who can update the verification key and state
    /// @return rollupId The ID of the newly created rollup
    function createRollup(
        bytes32 initialState,
        bytes32 verificationKey,
        address owner
    ) external returns (uint256 rollupId) {
        rollupId = rollupCounter++;
        rollups[rollupId] = RollupConfig({
            owner: owner,
            verificationKey: verificationKey,
            stateRoot: initialState,
            etherBalance: 0
        });
        emit RollupCreated(rollupId, owner, verificationKey, initialState);
    }

    /// @notice Creates a new L2Proxy contract for an original address
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @return proxy The address of the deployed Proxy
    function createL2ProxyContract(address originalAddress, uint256 originalRollupId) external returns (address proxy) {
        return _createL2ProxyContractInternal(originalAddress, originalRollupId);
    }

    /// @notice Modifier to check if caller is the rollup owner
    modifier onlyRollupOwner(uint256 rollupId) {
        if (rollups[rollupId].owner != msg.sender) {
            revert NotRollupOwner();
        }
        _;
    }

    /// @notice Posts a batch of state commitments for multiple rollups with ZK proof verification
    /// @param commitments The state commitments for each rollup
    /// @param blobCount Number of blobs containing shared data
    /// @param callData Shared data passed via calldata
    /// @param proof The ZK proof
    function postBatch(
        StateCommitment[] calldata commitments,
        uint256 blobCount,
        bytes calldata callData,
        bytes calldata proof
    ) external {
        // Check if state was already updated in this block
        if (lastStateUpdateBlock == block.number) {
            revert StateAlreadyUpdatedThisBlock();
        }

        // Collect current states and verification keys
        bytes32[] memory currentStates = new bytes32[](commitments.length);
        bytes32[] memory verificationKeys = new bytes32[](commitments.length);
        bytes32[] memory newStates = new bytes32[](commitments.length);

        for (uint256 i = 0; i < commitments.length; i++) {
            RollupConfig storage config = rollups[commitments[i].rollupId];
            currentStates[i] = config.stateRoot;
            verificationKeys[i] = config.verificationKey;
            newStates[i] = commitments[i].newState;
        }

        // Collect blob hashes
        bytes32[] memory blobHashes = new bytes32[](blobCount);
        for (uint256 i = 0; i < blobCount; i++) {
            blobHashes[i] = blobhash(i);
        }

        // Prepare public inputs hash for verification
        // First byte indicates proof type: 0x00 = postBatch
        bytes32 publicInputsHash = keccak256(
            abi.encodePacked(
                bytes1(0x00),
                blockhash(block.number - 1),
                abi.encode(commitments),
                abi.encode(currentStates),
                abi.encode(verificationKeys),
                abi.encode(blobHashes),
                keccak256(callData)
            )
        );

        if (!zkVerifier.verify(proof, publicInputsHash)) {
            revert InvalidProof();
        }

        // Verify that the sum of ether increments is zero
        int256 totalIncrement = 0;
        for (uint256 i = 0; i < commitments.length; i++) {
            totalIncrement += commitments[i].etherIncrement;
        }
        if (totalIncrement != 0) {
            revert EtherIncrementsSumNotZero();
        }

        // Apply state commitments and ether increments
        for (uint256 i = 0; i < commitments.length; i++) {
            RollupConfig storage config = rollups[commitments[i].rollupId];
            config.stateRoot = commitments[i].newState;

            // Apply ether increment
            int256 increment = commitments[i].etherIncrement;
            if (increment < 0) {
                uint256 decrement = uint256(-increment);
                if (config.etherBalance < decrement) {
                    revert InsufficientRollupBalance();
                }
                config.etherBalance -= decrement;
            } else {
                config.etherBalance += uint256(increment);
            }

            emit StateUpdated(commitments[i].rollupId, commitments[i].newState);
        }
    }

    /// @notice Updates the state root for a rollup (owner only, no proof required)
    /// @param rollupId The rollup ID to update
    /// @param newStateRoot The new state root
    function setStateByOwner(uint256 rollupId, bytes32 newStateRoot) external onlyRollupOwner(rollupId) {
        rollups[rollupId].stateRoot = newStateRoot;
        emit StateUpdated(rollupId, newStateRoot);
    }

    /// @notice Updates the verification key for a rollup (owner only)
    /// @param rollupId The rollup ID to update
    /// @param newVerificationKey The new verification key
    function setVerificationKey(uint256 rollupId, bytes32 newVerificationKey) external onlyRollupOwner(rollupId) {
        rollups[rollupId].verificationKey = newVerificationKey;
        emit VerificationKeyUpdated(rollupId, newVerificationKey);
    }

    /// @notice Transfers ownership of a rollup to a new owner
    /// @param rollupId The rollup ID
    /// @param newOwner The new owner address
    function transferRollupOwnership(uint256 rollupId, address newOwner) external onlyRollupOwner(rollupId) {
        address previousOwner = rollups[rollupId].owner;
        rollups[rollupId].owner = newOwner;
        emit OwnershipTransferred(rollupId, previousOwner, newOwner);
    }

    /// @notice Loads pre-computed L2 executions with ZK proof verification
    /// @param executions The executions to load
    /// @param proof The ZK proof
    function loadL2Executions(Execution[] calldata executions, bytes calldata proof) external {
        // Build public inputs hash from all executions
        bytes32[] memory executionHashes = new bytes32[](executions.length);
        for (uint256 i = 0; i < executions.length; i++) {
            // Collect verification keys for each state delta
            bytes32[] memory verificationKeys = new bytes32[](executions[i].stateDeltas.length);
            for (uint256 j = 0; j < executions[i].stateDeltas.length; j++) {
                verificationKeys[j] = rollups[executions[i].stateDeltas[j].rollupId].verificationKey;
            }

            executionHashes[i] = keccak256(
                abi.encodePacked(
                    abi.encode(executions[i].stateDeltas),
                    abi.encode(verificationKeys),
                    executions[i].actionHash,
                    abi.encode(executions[i].nextAction)
                )
            );
        }

        // Hash all execution hashes into a single public inputs hash
        // First byte indicates proof type: 0x01 = loadL2Executions
        bytes32 publicInputsHash = keccak256(abi.encodePacked(bytes1(0x01), abi.encode(executionHashes)));

        if (!zkVerifier.verify(proof, publicInputsHash)) {
            revert InvalidProof();
        }

        // Store executions - key is actionHash
        for (uint256 i = 0; i < executions.length; i++) {
            _executions[executions[i].actionHash].push(executions[i]);
        }

        emit ExecutionsLoaded(executions.length);
    }

    /// @notice Executes an L2 execution by an authorized proxy
    /// @param actionHash The action hash to look up
    /// @return nextAction The next action to perform
    function executeL2Execution(bytes32 actionHash) external returns (Action memory nextAction) {
        if (!authorizedProxies[msg.sender]) {
            revert UnauthorizedProxy();
        }
        return _findAndApplyExecution(actionHash);
    }

    /// @notice Internal function to find and apply an execution
    /// @param actionHash The action hash to look up
    /// @return nextAction The next action to perform
    function _findAndApplyExecution(bytes32 actionHash) internal returns (Action memory nextAction) {
        // Look up executions array
        Execution[] storage executions = _executions[actionHash];

        // Search from the last entry backwards to find matching execution
        for (uint256 i = executions.length; i > 0; i--) {
            Execution storage execution = executions[i - 1];

            // Check if all state deltas match current rollup states
            bool allMatch = true;
            for (uint256 j = 0; j < execution.stateDeltas.length; j++) {
                StateDelta storage delta = execution.stateDeltas[j];
                if (rollups[delta.rollupId].stateRoot != delta.currentState) {
                    allMatch = false;
                    break;
                }
            }

            if (allMatch) {
                // Found matching execution - apply all state deltas and ether deltas
                for (uint256 k = 0; k < execution.stateDeltas.length; k++) {
                    StateDelta storage delta = execution.stateDeltas[k];
                    RollupConfig storage config = rollups[delta.rollupId];
                    config.stateRoot = delta.newState;

                    // Apply ether delta
                    if (delta.etherDelta < 0) {
                        uint256 decrement = uint256(-delta.etherDelta);
                        if (config.etherBalance < decrement) {
                            revert InsufficientRollupBalance();
                        }
                        config.etherBalance -= decrement;
                    } else if (delta.etherDelta > 0) {
                        config.etherBalance += uint256(delta.etherDelta);
                    }

                    emit L2ExecutionPerformed(delta.rollupId, delta.currentState, delta.newState);
                }

                // Record this block as having an L2 execution
                lastStateUpdateBlock = block.number;

                // Copy nextAction to memory before removing from storage
                nextAction = execution.nextAction;

                // Remove the execution from storage to free space
                uint256 lastIndex = executions.length - 1;
                if (i - 1 != lastIndex) {
                    executions[i - 1] = executions[lastIndex];
                }
                executions.pop();

                return nextAction;
            }
        }

        revert ExecutionNotFound();
    }

    /// @notice Executes an L2 transaction
    /// @param rollupId The rollup ID for the transaction
    /// @param rlpEncodedTx The RLP-encoded transaction data
    /// @return result The result data from the execution
    function executeL2TX(uint256 rollupId, bytes calldata rlpEncodedTx) external returns (bytes memory result) {
        // Build the L2TX action
        Action memory action = Action({
            actionType: ActionType.L2TX,
            rollupId: rollupId,
            destination: address(0),
            value: 0,
            data: rlpEncodedTx,
            failed: false,
            sourceAddress: address(0),
            sourceRollup: 0
        });

        // Compute action hash and get first nextAction
        bytes32 currentActionHash = keccak256(abi.encode(action));
        Action memory nextAction = _findAndApplyExecution(currentActionHash);

        // Process actions in a loop until we get a RESULT
        while (true) {
            if (nextAction.actionType == ActionType.CALL) {
                // Compute source proxy address
                address sourceProxy = this.computeL2ProxyAddress(
                    nextAction.sourceAddress,
                    nextAction.sourceRollup,
                    block.chainid
                );

                // Create source proxy if it doesn't exist
                if (!authorizedProxies[sourceProxy]) {
                    _createL2ProxyContractInternal(nextAction.sourceAddress, nextAction.sourceRollup);
                }

                // Withdraw ETH from rollup if needed for the call
                if (nextAction.value > 0) {
                    RollupConfig storage config = rollups[nextAction.sourceRollup];
                    if (config.etherBalance < nextAction.value) {
                        revert InsufficientRollupBalance();
                    }
                    config.etherBalance -= nextAction.value;
                }

                // Execute the call through the source proxy (ETH is sent directly from Rollups contract)
                (bool success, bytes memory returnData) = L2Proxy(payable(sourceProxy)).executeOnBehalf{value: nextAction.value}(
                    nextAction.destination,
                    nextAction.data
                );

                // Build RESULT action from the call result
                Action memory resultAction = Action({
                    actionType: ActionType.RESULT,
                    rollupId: nextAction.rollupId,
                    destination: address(0),
                    value: 0,
                    data: returnData,
                    failed: !success,
                    sourceAddress: address(0),
                    sourceRollup: 0
                });

                // Compute new action hash and get next action
                currentActionHash = keccak256(abi.encode(resultAction));
                nextAction = _findAndApplyExecution(currentActionHash);
            } else {
                // RESULT type - return the data or revert if failed
                if (nextAction.failed) {
                    revert CallExecutionFailed();
                }
                return nextAction.data;
            }
        }
    }

    /// @notice Internal function to create an L2Proxy contract
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @return proxy The address of the deployed Proxy
    function _createL2ProxyContractInternal(address originalAddress, uint256 originalRollupId) internal returns (address proxy) {
        bytes32 salt = keccak256(abi.encodePacked(block.chainid, originalRollupId, originalAddress));

        proxy = address(new Proxy{salt: salt}(l2ProxyImplementation, address(this), originalAddress, originalRollupId));

        authorizedProxies[proxy] = true;

        emit L2ProxyCreated(proxy, originalAddress, originalRollupId);
    }

    /// @notice Deposits ether to a rollup's balance
    /// @param rollupId The rollup ID to deposit to
    function depositEther(uint256 rollupId) external payable {
        rollups[rollupId].etherBalance += msg.value;
    }

    /// @notice Withdraws ether from a rollup's balance (only callable by authorized proxies)
    /// @param rollupId The rollup ID to withdraw from
    /// @param amount The amount of ether to withdraw
    function withdrawEther(uint256 rollupId, uint256 amount) external {
        if (!authorizedProxies[msg.sender]) {
            revert UnauthorizedProxy();
        }
        RollupConfig storage config = rollups[rollupId];
        if (config.etherBalance < amount) {
            revert InsufficientRollupBalance();
        }
        config.etherBalance -= amount;
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert EtherTransferFailed();
        }
    }

    /// @notice Computes the CREATE2 address for an L2Proxy
    /// @param originalAddress The original address this proxy represents
    /// @param originalRollupId The original rollup ID
    /// @param domain The domain (chain ID) for the address computation
    /// @return The computed proxy address
    function computeL2ProxyAddress(address originalAddress, uint256 originalRollupId, uint256 domain) external view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(domain, originalRollupId, originalAddress));
        bytes32 bytecodeHash = keccak256(
            abi.encodePacked(
                type(Proxy).creationCode,
                abi.encode(l2ProxyImplementation, address(this), originalAddress, originalRollupId)
            )
        );

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash)))));
    }
}
