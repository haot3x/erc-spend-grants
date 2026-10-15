# ERC-4337 smart account as delegate

[`SpendGrant4337Fork.t.sol`](SpendGrant4337Fork.t.sol) runs an ERC-4337 SimpleAccount (eth-infinitism v0.7) as an ERC-8427 grant's delegate against EntryPoint v0.7, the SimpleAccountFactory, and the ERC-8427 registry and executor deployed on Arc testnet (chain 5042002). It builds and signs real PackedUserOperations and submits them through the live EntryPoint's `handleOps`. A minimal paymaster is defined in the test file. No account or EntryPoint code is copied into this repository. The principal is an EOA in the fork.

- **Spend.** The account is the delegate, so it calls `executor.spend` itself. The UserOperation's callData is `account.execute(executor, 0, spend(grantId, asset, amount, recipient))`. The executor authenticates `msg.sender`, which is the account. The funds move from the principal to the recipient and never touch the account.
- **Gas.** The account pays its own prefund, or a paymaster does. With a paymaster, the account needs no native balance and no tokens, and it may be counterfactual, deployed by the same operation's `initCode`.
- **Grant failure.** The grant is checked in the execution phase, not in validation. A UserOperation built against a grant that the principal then revokes or tightens passes validation. Its execution reverts with `SpendGrantError(reason)`, which the EntryPoint reports in `UserOperationRevertReason`. The gas is still charged to whoever pays, which here is the paymaster's deposit.
- **ERC-1271.** The deployed SimpleAccount v0.7 has no `isValidSignature`, so it cannot authorize a relayed `spendWithAuthorization`. For an account whose code is not an EIP-7702 delegation designator, as here, the executor accepts ERC-1271 only and never recovers an ECDSA signer, so the owner's signature is rejected with `BadAuthorization`. Such an account spends through its own UserOperation. An account that implements ERC-1271 (see [`../safe/`](../safe/)) can use the relayed path.

## Run

```bash
pnpm test:fork
```

It needs the `arc_testnet` RPC. Without `FORK_TESTS=true` the suite is skipped, so `pnpm check` stays offline. It sits under `test/integrations/`, so `pnpm erc:promote` does not copy it into the ERC bundle.

## Contracts

Checked on Arc testnet at block 67244286.

| Contract | Address |
| --- | --- |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| SimpleAccountFactory v0.7 | `0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985` |
| SimpleAccount v0.7 implementation | `0x68641DE71cfEa5a5d0D29712449Ee254bb1400C2` |
| ERC-8427 registry | `0xe8987A22a1e3fd4a63cB517A9476B9d214388287` |
| ERC-8427 executor | `0xB99785329AbEc9936b6EF6350015be39D3392646` |

The factory's `accountImplementation()` is `0x68641DE71cfEa5a5d0D29712449Ee254bb1400C2`, and that implementation's `entryPoint()` is the v0.7 EntryPoint. The selectors present are consistent with eth-infinitism v0.7: `validateUserOp` over `PackedUserOperation`, and `executeBatch(address[],uint256[],bytes[])`. The factory has no `senderCreator`, and the account has no `isValidSignature`. The `setUp` asserts the factory, implementation, and EntryPoint binding.

Arc also has EntryPoint v0.8 at `0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108`. This factory does not use it, and the tests do not.

The token is a mock deployed in the fork.

## What the tests show

| Case | Result |
| --- | --- |
| UserOperation from the account calls `spend`; the account pays its own gas | The principal pays the vendor exactly the amount; the account's own token balance does not change; what left the account's native balance, less the unused prefund the EntryPoint keeps as its deposit, equals the operation's `actualGasCost` |
| Paymaster sponsors a counterfactual account with no native balance and no tokens | The `initCode` deploys the account and the spend settles; the account's balances and EntryPoint deposit stay zero; the paymaster's deposit drops by the operation's `actualGasCost` |
| Principal revokes after the operation is signed | Validation passes; execution reverts `SpendGrantError(REVOKED)`; nothing moves; the paymaster's deposit is charged |
| Principal cuts a cap below the amount after the operation is signed | Validation passes; execution reverts `SpendGrantError(OVER_TX_CAP)`; nothing moves; the paymaster's deposit is charged |
| Grant names the owner's key as delegate; the account sends the operation | Validation passes; execution reverts `SpendGrantError(UNAUTHORIZED_DELEGATE)`; nothing moves; the paymaster's deposit is charged |
| `check` before each of the three failing operations, and before and after a revoke | Reports the reason the execution reverts with; `OK` before the revoke |
| SimpleAccount and ERC-1271 | `isValidSignature` reverts with no data; `supportsInterface(0x1626ba7e)` is false |
| Owner signs the executor's authorization digest, raw or with the Ethereum signed-message prefix; a relayer submits | `BadAuthorization` |

## Notes for integrators

- Call the registry's `check(grantId, account, asset, amount, recipient)` before sending the UserOperation. Neither the account's validation nor the bundler's simulation of validation evaluates the grant. A grant revoked or tightened after the operation was signed is discovered only in execution, after the gas is spent.
- A paymaster that sponsors spends should run the same check, or simulate execution, before it signs for the operation. Otherwise it pays for failures.
- `check` is a read at one block. The principal can still change the grant before the operation is included.
- The account is the delegate, not its owner key. A grant to the owner EOA is a different grant; the account's spend under it fails with `UNAUTHORIZED_DELEGATE`.
- SimpleAccount v0.7 cannot be a relayed delegate, because it has no ERC-1271. Session keys and other account modules are out of scope here.
