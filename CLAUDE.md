# L1/L2 Sync Smart Contracts

## Project Overview

This is a Foundry-based Solidity project implementing smart contracts for L1/L2 rollup synchronization. The system allows L2 executions to be verified and executed on L1 using ZK proofs.

## Build & Test Commands

```bash
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvv      # Run tests with verbose output
forge fmt            # Format code
```

## Architecture

### Core Contracts

- **Rollups.sol**: Main contract managing rollup state roots and L2 execution transitions
- **L2Proxy.sol**: Proxy contracts deployed via CREATE2, one per target address per rollup
- **IZKVerifier.sol**: Interface for external ZK proof verification

### Data Types

```solidity
enum ActionType { CALL, RESULT, L2TX }

struct Action {
    ActionType actionType;
    uint256 rollupId;
    address destination;    // for CALL
    uint256 value;          // for CALL
    bytes data;             // callData for CALL, returnData for RESULT, rlpEncodedTx for L2TX
    bool failed;            // for RESULT
    address sourceAddress;  // for CALL - immediate caller address
    uint256 sourceRollup;   // for CALL - immediate caller's rollup ID
}

struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;       // Change in rollup's ETH balance
}

struct StateCommitment {
    uint256 rollupId;
    bytes32 newState;
    int256 etherIncrement;   // Change in rollup's ETH balance (sum must be zero)
}

struct Execution {
    StateDelta[] stateDeltas;
    bytes32 actionHash;
    Action nextAction;
}

struct RollupConfig {
    address owner;           // Can update state and verification key
    bytes32 verificationKey; // Used for ZK proof verification
    bytes32 stateRoot;       // Current state root
    uint256 etherBalance;    // ETH held by this rollup
}
```

### Key Functions

1. **createRollup(initialState, verificationKey, owner)**: Creates a new rollup with custom initial state, verification key, and owner
2. **createL2ProxyContract(originalAddress, originalRollupId)**: Deploys L2Proxy via CREATE2
3. **postBatch(commitments, blobCount, callData, proof)**: Posts batch of state commitments with ZK proof (async path). Sum of etherIncrements must be zero.
4. **setStateByOwner(rollupId, newStateRoot)**: Updates state root without proof (owner only)
5. **setVerificationKey(rollupId, newVerificationKey)**: Updates verification key (owner only)
6. **transferRollupOwnership(rollupId, newOwner)**: Transfers rollup ownership (owner only)
7. **loadL2Executions(executions, proof)**: Loads pre-computed executions with ZK proof
8. **executeL2Execution(actionHash)**: Executes pre-loaded execution (only callable by authorized proxies)
9. **executeL2TX(rollupId, rlpEncodedTx)**: Executes an L2 transaction (permissionless)
10. **depositEther(rollupId)**: Deposits ETH to a rollup's balance
11. **withdrawEther(rollupId, amount)**: Withdraws ETH from a rollup's balance (only callable by authorized proxies)

### Execution Flow

1. ZK prover generates proof of valid L2 executions
2. Anyone calls `loadL2Executions` with executions and proof
3. L2Proxy calls `executeL2Execution` to apply executions
4. State deltas are applied and next action is returned
5. Used executions are removed from storage

### CREATE2 Address Derivation

Proxy addresses are deterministic based on:
- Salt: `keccak256(domain, originalRollupId, originalAddress)`
- Bytecode: Proxy creation code with constructor args

Use `computeL2ProxyAddress(originalAddress, originalRollupId, domain)` to predict addresses.

## Testing

Tests use a `MockZKVerifier` that accepts all proofs by default. Set `verifier.setVerifyResult(false)` to test proof rejection.
