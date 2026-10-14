# Safe as principal and as delegate

[`SpendGrantSafeFork.t.sol`](SpendGrantSafeFork.t.sol) runs against Safe v1.4.1 and the ERC-8427 registry and executor deployed on Arc testnet (chain 5042002). It deploys a 2-of-3 treasury Safe and a 2-of-2 agent Safe through the live proxy factory and drives them with real Safe transactions and signatures. No Safe code is copied into this repository.

The two sides use different mechanisms:

- **Principal.** A registered grant carries no principal signature. `register`, `update`, and `revoke` require `msg.sender == principal`, so the Safe calls them through `execTransaction` at its threshold. An owner's own key is not the principal. This is the spec's "the account's call policy is its grant policy": whatever can make the Safe call the registry controls its grants, and ERC-1271 plays no part.
- **Delegate.** An agent that is a Safe authorizes a spend through the executor's signed path, which validates the delegate's signature with ERC-1271. Safe's `isValidSignature` checks owner signatures over the digest wrapped as a SafeMessage, `getMessageHashForSafe(safe, abi.encode(digest))`, not over the digest itself.

## Run

```bash
pnpm test:fork
```

It needs the `arc_testnet` RPC. Without `FORK_TESTS=true` the suite is skipped, so `pnpm check` stays offline. It sits under `test/integrations/`, so `pnpm erc:promote` does not copy it into the ERC bundle.

## Contracts

Checked on Arc testnet at block 67212822.

| Contract | Address |
| --- | --- |
| Safe v1.4.1 singleton | `0x41675C099F32341bf84BFc5382aF534df5C7461a` |
| SafeProxyFactory v1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |
| CompatibilityFallbackHandler v1.4.1 | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |
| MultiSendCallOnly v1.4.1 | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |
| ERC-8427 registry | `0xe8987A22a1e3fd4a63cB517A9476B9d214388287` |
| ERC-8427 executor | `0xB99785329AbEc9936b6EF6350015be39D3392646` |

The token is a mock deployed in the fork.

## What the tests show

| Case | Result |
| --- | --- |
| One Safe transaction, batched through MultiSendCallOnly, approves the executor and registers | Registered with the Safe as principal; `grantsOf(safe)` lists it; `grantState` reads the Safe's balance and allowance |
| Agent spends | The Safe pays the vendor directly; no Safe transaction or owner signature per spend |
| An owner calls `register` from its own key | `NotPrincipal` |
| One owner signs a 2-of-3 Safe transaction to register | Safe reverts `GS020`; nothing registered |
| Safe transaction lowers the caps | Usage kept; `spendableNow` drops; the next spend over the new window cap fails `OVER_WINDOW_CAP` |
| Safe transaction built from the older version, executed after an update | `StaleVersion` inside the call, which Safe reports as `GS013`; the newer caps stay |
| Safe transaction revokes | The next spend fails `REVOKED` |
| Agent Safe owners sign the SafeMessage-wrapped authorization; a relayer submits | Paid; the nonce is recorded under the agent Safe |
| Agent Safe owners sign the raw authorization digest | `BadAuthorization` |
| One of the agent Safe's two owners signs | `BadAuthorization` |

## Notes for integrators

- Batch the approval with the registration, as here, or approve first. A grant registered before the approval shows `spendableNow` of zero until the approval lands.
- Safe reports any failed inner call as `GS013` when `safeTxGas` and `gasPrice` are zero, so a wallet that wants the registry's error, such as `StaleVersion`, should simulate the inner call before proposing the Safe transaction.
- An agent Safe's signers sign a SafeMessage. Tooling that signs the executor's digest directly, as it would for an EOA delegate, produces signatures the Safe rejects.
- A module or guard that lets something other than the owners make the Safe call the registry can register and change grants. The treasury's module set is part of its grant policy.
