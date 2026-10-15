# ERC-8004 agent identity as the delegate

[`SpendGrant8004Fork.t.sol`](SpendGrant8004Fork.t.sol) runs against the ERC-8004 Identity Registry and the ERC-8427 registry and executor deployed on Arc testnet (chain 5042002). It registers a fresh agent, grants to the agent's wallet, then changes, unsets, and transfers the agent NFT, including a contract wallet. No ERC-8004 code is copied into this repository; the test declares only the interface it calls.

**A grant binds an address, not an identity.** `principal`, `delegate`, and `windowSeconds` are fixed for a grant's life. When the agent's wallet changes or the agent NFT is transferred, the old wallet keeps spending until the principal revokes, and the new wallet cannot spend under the old grant (`UNAUTHORIZED_DELEGATE`). `update` cannot move a grant to another delegate (`FixedField`). Re-binding is a revocation plus a new registration, which starts with no usage.

- **Resolving the delegate.** The principal reads `getAgentWallet(agentId)` and registers a grant with that address as `delegate`. ERC-8004 sets the wallet to the owner's address at `register()`; the owner changes it with `setAgentWallet`, proving control of the new wallet with its EIP-712 signature (ERC-1271 for a contract), or clears it with `unsetAgentWallet`. ERC-8004: "When the agent is transferred, `agentWallet` is automatically cleared (effectively resetting it to the zero address) and must be re-verified by the new owner."
- **Labeling the grant.** `salt = uint256(keccak256(abi.encode(identityChainId, identityRegistry, agentId, n)))`, with `n` a counter so one principal can register several grants to the same agent. It mirrors ERC-8004's `agentRegistry` form `{namespace}:{chainId}:{identityRegistry}`, so a verifier knows to query the registry on `identityChainId`. The same registry address is live on several testnets, so the chain id is what disambiguates. A third party reads the terms with `getGrant`, recomputes the salt, and compares `delegate` with `getAgentWallet(agentId)`. The salt keeps matching after a wallet change; only the delegate comparison shows the grant is stale. The salt is a label, not an authority: it does not let the new wallet spend. `update` ignores the salt, so the label cannot be changed or removed.
- **Discovery.** `grantsTo(delegate, offset, limit)` is keyed by address. After a wallet change the new wallet's list is empty and the old grant stays on the old wallet's list, until the principal registers a grant to the new wallet.

## Run

```bash
pnpm test:fork
```

It needs the `arc_testnet` RPC. Without `FORK_TESTS=true` the suite is skipped, so `pnpm check` stays offline. It sits under `test/integrations/`, so `pnpm erc:promote` does not copy it into the ERC bundle.

## Contracts

The suite runs against the latest Arc testnet block, and `setUp` fails if the Identity Registry's `getVersion` is no longer `2.0.0`. Last checked at block 67252825.

| Contract | Address |
| --- | --- |
| ERC-8004 Identity Registry (proxy, `getVersion` 2.0.0) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| ERC-8427 registry | `0xe8987A22a1e3fd4a63cB517A9476B9d214388287` |
| ERC-8427 executor | `0xB99785329AbEc9936b6EF6350015be39D3392646` |

The token is a mock deployed in the fork. The Identity Registry address is the testnet one listed by [erc-8004/erc-8004-contracts](https://github.com/erc-8004/erc-8004-contracts) for Arc Testnet.

## What the tests show

| Case | Result |
| --- | --- |
| Principal registers with `getAgentWallet(agentId)` as delegate; the agent spends | Paid |
| Owner sets a new wallet; the old wallet spends | Paid |
| New wallet spends under the old grant | `UNAUTHORIZED_DELEGATE` |
| Principal updates the grant's delegate to the new wallet | `FixedField` |
| Principal revokes after the wallet change; the old wallet spends | `REVOKED` |
| Old wallet spends; principal revokes and registers to the new wallet | New id with no usage; the new wallet spends a full window cap |
| Owner unsets the wallet; the old wallet spends | `getAgentWallet` is zero; paid |
| Principal registers with the unset wallet as delegate | `INVALID_GRANT` |
| A contract wallet is set through ERC-1271; a grant to it is spent by the contract; the EOA wallet's grant still pays; another address spends | Paid; paid; `UNAUTHORIZED_DELEGATE` |
| Agent NFT transferred | `getAgentWallet` is zero; the old wallet still spends |
| Principal registers with the cleared wallet as delegate | `INVALID_GRANT` |
| New owner verifies a new wallet; it spends under the old grant | `UNAUTHORIZED_DELEGATE` |
| New owner re-verifies a wallet; principal revokes and registers to it | The new wallet spends |
| Third party recomputes the salt, with the chain id, from `getGrant` before and after a wallet change | Salt matches both times; `delegate` matches `getAgentWallet` only before |
| New wallet spends under a grant whose salt names its agent | `UNAUTHORIZED_DELEGATE` |
| Principal updates with a different salt | Update applies; the stored salt is unchanged |
| `grantsTo` for the old and new wallets across a wallet change and a rebind | Old grant only under the old wallet; the new grant under the new wallet |

## Notes for integrators

- A principal that grants to an agent identity must watch the Identity Registry for `MetadataSet` on the `agentWallet` key and for `Transfer` of the agent, and revoke the grants whose delegate is the previous wallet. Neither event changes a grant. Until the revocation, the previous wallet can spend up to the grant's caps, including after the agent has been sold.
- ERC-8004 requires `MetadataSet` for `agentWallet` only at `register`. The deployed implementation also emits it on `setAgentWallet`, on `unsetAgentWallet`, and on the clear at transfer (empty value); the tests check all three. That is the implementation's behavior, not the text's. The event does not carry the previous wallet, so a principal must have recorded which wallet each of its grants names.
- Check that `getAgentWallet(agentId)` is not zero before registering. After a transfer or an `unsetAgentWallet` it is zero until the owner sets a wallet again, and the registry refuses a zero delegate.
- "Verified" for a contract wallet means only that its `isValidSignature` returned the magic value (the implementation tries ECDSA, then ERC-1271). A permissive contract can be set as the wallet, so a principal resolving `getAgentWallet` gets no more assurance than that.
- A verifier that trusts the salt label alone will attribute a stale grant to the agent's current wallet. Compare `delegate` with `getAgentWallet(agentId)` as well.
- An agent that changes its wallet leaves its grants live on the old key until its principals revoke. A wallet change made because the old key leaked does not stop that key from spending.
- The `setAgentWallet` signing details come from the deployed implementation, not the ERC-8004 text, which says only EIP-712 or ERC-1271: the type is `AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)`, the signed `owner` is the token owner, approved operators may also call `setAgentWallet` and `unsetAgentWallet`, the domain is `ERC8004IdentityRegistry` version `1`, and the deadline may be at most five minutes ahead. The test reads the domain from `eip712Domain()` and fails if it changes.
- ERC-8004 text as last committed on 2026-01-25. The Reputation and Validation registries are out of scope.
