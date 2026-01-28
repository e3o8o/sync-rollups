# Sync Rollups

Smart contracts to manage synchronous rollups in Ethereum.

## Overview

Sync Rollups enables synchronous composability between based rollups sharing the same L1 sequencer. By pre-computing state transitions off-chain and loading them with ZK proofs, the protocol enables atomic cross-rollup calls that execute within a single L1 block.

This restores the synchronous execution semantics that DeFi protocols depend on—now across multiple rollups.

## Features

- **Atomic Multi-Rollup Execution**: State changes across multiple rollups happen atomically in a single transaction
- **Cross-Rollup Flash Loans**: Borrow on Rollup A, use on Rollup B, repay on A—all atomic
- **Unified Liquidity**: AMMs can source liquidity from multiple rollups
- **ZK-Verified State Transitions**: All executions are verified with ZK proofs
- **Gas-Efficient Proxies**: Shared implementation pattern reduces proxy deployment cost by ~50%
- **ETH Balance Tracking**: Per-rollup ETH accounting with conservation guarantees

## Architecture

### Core Contracts

| Contract | Description |
|----------|-------------|
| `Rollups.sol` | Main contract managing rollup state roots and L2 execution transitions |
| `L2Proxy.sol` | Implementation contract for L2 proxy functionality |
| `Proxy.sol` | Minimal proxy contract that delegates to L2Proxy implementation |
| `IZKVerifier.sol` | Interface for ZK proof verification |

### Data Types

```solidity
struct Execution {
    StateDelta[] stateDeltas;  // Can affect multiple rollups atomically
    bytes32 actionHash;         // Hash of the triggering action
    Action nextAction;          // What happens next (call or result)
}

struct StateDelta {
    uint256 rollupId;
    bytes32 currentState;
    bytes32 newState;
    int256 etherDelta;      // Change in ETH balance for this rollup
}

struct Action {
    ActionType actionType;  // CALL or RESULT
    uint256 rollupId;
    address destination;
    uint256 value;
    bytes data;
    bool failed;
}

struct StateCommitment {
    uint256 rollupId;
    bytes32 newState;
    int256 etherIncrement;  // ETH change (can be negative, sum must be zero)
}
```

### Execution Flow

1. **Load Phase**: Off-chain provers compute valid executions and submit them with a ZK proof via `loadL2Executions()`
2. **Execute Phase**: Users call L2Proxy contracts, which trigger pre-loaded executions via `executeL2Execution()`
3. **State Update**: State deltas are applied atomically across all affected rollups
4. **Cleanup**: Used executions are removed from storage to reclaim gas

```
User calls L2Proxy.someFunction()
    └─> L2Proxy computes actionHash = keccak256(CALL action)
        └─> Rollups.executeL2Execution(actionHash)
            └─> Find execution matching current states
            └─> Apply state deltas atomically
            └─> Return nextAction (another CALL or final RESULT)
```

### ETH Balance Tracking

Each rollup maintains an ETH balance held by the Rollups contract. This enables cross-rollup value transfers while maintaining conservation guarantees.

**Key Properties:**
- ETH received by L2Proxy is automatically deposited to the rollup's balance
- Cross-rollup transfers require the sum of ether increments to be zero in `postBatch()`
- Executions can transfer ETH between rollups via `etherDelta` in StateDelta
- L2Proxy withdraws ETH from rollup balance when making outgoing calls

```
ETH Flow:
User sends ETH to L2Proxy
    └─> L2Proxy.depositEther() to Rollups contract
        └─> rollups[rollupId].etherBalance += amount
            └─> On outgoing call: Rollups.withdrawEther()
                └─> ETH sent to L2Proxy for external call
```

## Installation

```bash
# Clone the repository
git clone https://github.com/jbaylina/sync-rollups.git
cd sync-rollups

# Install dependencies
forge install
```

## Build & Test

```bash
# Compile contracts
forge build

# Run tests
forge test

# Run tests with verbose output
forge test -vvv

# Format code
forge fmt
```

## Usage

### Creating a Rollup

```solidity
Rollups rollups = new Rollups(zkVerifierAddress, startingRollupId);

uint256 rollupId = rollups.createRollup(
    initialState,      // bytes32
    verificationKey,   // bytes32
    owner              // address
);
```

### Creating an L2Proxy

```solidity
address proxy = rollups.createL2ProxyContract(
    originalAddress,   // The L2 contract address
    originalRollupId   // The rollup ID
);
```

### Loading Executions

```solidity
Execution[] memory executions = new Execution[](1);
executions[0] = Execution({
    stateDeltas: stateDeltas,
    actionHash: actionHash,
    nextAction: nextAction
});

rollups.loadL2Executions(executions, zkProof);
```

### Computing Proxy Addresses

```solidity
address proxyAddr = rollups.computeL2ProxyAddress(
    originalAddress,
    originalRollupId,
    domain  // chain ID where proxy will be deployed
);
```

## Key Functions

| Function | Description |
|----------|-------------|
| `createRollup()` | Creates a new rollup with initial state, verification key, and owner |
| `createL2ProxyContract()` | Deploys an L2Proxy via CREATE2 |
| `postBatch()` | Posts batch of state commitments with ZK proof (async path) |
| `loadL2Executions()` | Loads pre-computed executions with ZK proof |
| `executeL2Execution()` | Executes pre-loaded execution (only callable by authorized proxies) |
| `depositEther()` | Deposits ETH to a rollup's balance |
| `withdrawEther()` | Withdraws ETH from a rollup's balance (authorized proxies only) |
| `computeL2ProxyAddress()` | Computes deterministic proxy address |
| `convertAddress()` | Translates addresses between rollup domains |

## ZK Proof Structure

Two proof types are supported:

**Type 0x00 - Batch Posts** (async updates):
```
publicInputs = hash(0x00, blockhash, commitments, currentStates, verificationKeys, blobHashes, callDataHash)
```

**Type 0x01 - L2 Executions** (synchronous cross-rollup):
```
publicInputs = hash(0x01, executionHashes[])
```

## Security Considerations

- Only authorized proxies can execute L2 executions and withdraw ETH
- Same-block protection prevents conflicts between async and sync state updates
- All state transitions are verified with ZK proofs
- Rollup owners can update verification keys and transfer ownership
- ETH balance conservation: sum of ether increments in batch must be zero
- Rollup ETH balances cannot go negative (enforced on every state update)

## License

MIT
