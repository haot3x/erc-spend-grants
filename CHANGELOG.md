# Changelog

What changed in the ERC-8427 draft, its reference implementation, and the Arc testnet deployment, newest first. Dates are commit dates. An entry marked **interface** changes the registry ABI, the typed data, or `consume` behavior; grants signed against an earlier registry do not carry over, because a new registry is a new signing domain.

The draft is [`ERCS/erc-8427.md`](ERCS/erc-8427.md), under review in [ethereum/ERCs#2037](https://github.com/ethereum/ERCs/pull/2037). Discussion is on the [Magicians thread](https://ethereum-magicians.org/t/erc-8427-portable-spend-grants/29776).

## 2026-10-12

No interface change. The Arc testnet deployment is unchanged.

### Specification

- Correction, Replacing a grant: the 2026-10-06 rule sized a replacement's lifetime cap as the lesser of the requested value and what the earlier grant had left, which did not take the earlier spend off the new total, so the delegate could pass it. With `maxTotal` 1000, 700 spent, and a new total of 800, it allowed 300 more instead of 100. To hold spend under the earlier grant and the replacement to a new lifetime total `T`, a wallet now signs no more than `min(T, M) - S`, where `M` is the earlier `maxTotal` and `S` what the earlier grant spent, read once the revocation is final, and leaves the asset out when that is zero or less. Raised by ted0x on the thread.
- Removed text that was not a requirement, a risk specific to this ERC, or the reason for a design choice, including chain-specific notes (Hedera's RPC decimals, Arbitrum's clock bounds, USDC's blocklist and `permit`), gas figures from the reference, relayer advice, and notes on accounts that can sign but cannot send transactions. Three requirements went with it: the SHOULD for relayers to cap forwarded gas, the SHOULD to keep a gas reserve where the native currency is also the spent ERC-20, and the MAY to confirm a revocation by simulating `consume`. The raw-digest note on session-key policies is also removed, and the delegation-framework paragraph in Security Considerations points to the Executor requirements instead of restating them.
- The recommendation that a wallet confirm a listed asset answers `balanceOf` and `decimals` moves from the Rationale to Security Considerations, still a SHOULD.

### Reference

- Tests: spend under a revoked grant and a replacement sized by the corrected rule stops at the new total; an asset whose code accepts any call passes the code check, and the spend records a debit that moved nothing.

## 2026-10-06

Two parts: text corrections, then one interface addition and two reference decisions made ahead of the next deployment.

### Specification

- **interface** `hashGrant(grant)` returns the hash the registry computes for a grant. Wallets revoke that value rather than one they computed, because `revoke` cannot tell a wrong hash from a right one.

### Reference

- The deploy script binds the registry to `SpendGrantAuthorizationExecutor`, which accepts direct calls and relayed delegate-signed authorizations. A registry fixes its executor for good, so the relayed path has to be chosen at deployment.
- The authorization's EIP-712 domain name is `SpendAuthorization`, version `1`, no longer the contract's name. `vectors/authorization-v1.json` is regenerated.

### Corrections (no interface change)

### Specification

- Canonical rendering: the byte-exact rule applies to a plain-text presentation of a grant's complete terms in raw signed values. A display that converts units, dates, or names, summarizes, or shows only some terms is a formatted display whatever its medium.
- Revocation: wallets keep `grantSignature` with the grant. The confirmation step is restated so it can be carried out: check the stored signature against the computed hash, revoke, then read `revoked`; or simulate `consume` with the signature, the delegate as authorizer, and a time inside validity.
- Delegation framework: the hook and redeemer-record mechanics are stated as conditions of a framework rather than as properties of ERC-7710. Every requirement on the enforcer and executor is unchanged, and any other source of the redeemer must give the same properties.
- Rationale: expired debits are dropped by `consume` or `evict`; the payee rule names the spent asset and why.
- Replacing a grant: terms cannot be changed in place in either direction. A replacement is released to the delegate only after the earlier grant reads as revoked; wallets show the change as incomplete until then; a replacement starts with fresh usage, so its lifetime cap is sized from what the earlier grant had left and the window reset is disclosed or avoided with `validAfter`. Raised on the thread. `test/SpendGrantReplacement.t.sol` pins the behavior the text relies on.
- Security Considerations: a principal without gas can stop every grant over a permit-capable token with a signed zero approval; disabling a delegation is not a revocation; a signer that signs raw digests sees no domain, so domain-scoped session-key policies need a format that carries the typed data.

## 2026-10-05

Three rounds in one day: two reviewers' points from the thread, a logic review of the whole draft, and an audit pass over the reference (nine checklist domains, Slither, fuzzing, Halmos). One High was found and fixed.

### Specification

- **interface** `consume` rejects a payee of zero, the principal, the registry, the executor, or the asset being spent, in both recipient modes.
- **interface** Code is checked only on the asset being spent, after the asset is matched, and an EIP-7702 delegated account is not a token.
- **interface** `GrantConsumed` indexes `grantHash`, `principal`, and `recipient`; `asset` and `amount` are data.
- **interface** `evict(grantHash, asset, maxCount)` lets anyone drop expired debits in bounded pieces.
- Caps bound the amount the executor requests, which must equal the amount passed to `consume`. Token fees and rebases are the asset's behavior. A balance check is optional and may only revert.
- Delegation framework mechanism rewritten around the two shapes a redemption takes. The record path is confined to the principal's own account: the enforcer writes a record only for the principal's delegation, clears what is not taken, and the executor accepts no other caller on that path. This closes the High: a middle delegator riding the delegate's redemption for extra spends.
- Grants never supersede one another; wallets should revoke the old hash when replacing a grant and show per-delegate totals.
- A contract principal's ERC-1271 policy is its grant-signing policy. The ERC-1271 call must be a `STATICCALL`.
- `consume` and the movement happen within one call to the executor.
- Signed authorizations: EIP-712 over their own message, nonce checked before the signature, and invalidation fails for a nonce that already ran.
- Spendable-now is bounded by free debit slots. Added notes on relayer gas exposure, rollup clock bounds, Arc's USDC as the gas balance, and not redeploying at an old address on a reset chain.

### Reference

- `SpendGrantAuthorizationExecutor`: delegate-signed authorizations submitted by anyone.
- `SpendGrantRedemptionEnforcer` and `SpendGrantRedemptionExecutor`: the ERC-7710 path, tested against a mock manager and against MetaMask's DelegationManager v1.3.0 on Arc (`pnpm test:fork`).
- `SpendGrantSignature`: the Signatures rules, shared by the registry and executors. Low-level calls copy at most one word of return data.
- `vectors/authorization-v1.json`: a viem-generated vector for the authorization digest, checked in TypeScript and Solidity.
- `evm_version` pinned to `cancun`.

### Deployment (Arc testnet, 5042002)

- Registry `0x37ceecB34B97B39D5B07e8D7Dd974A5a9aD14425`, executor `0x08493Be1675070c2069a719A850f2F9d4624177E`. Current.
- Superseded the same day: registry `0x867C295d38dF1E0d6069bC0b10d1A3148C7E17d5`, executor `0x8074A7bCb5c26AD9d90E7cAC91aCF3809c40BFfd`.

## 2026-09-28

### Specification

- Number assigned: ERC-8427.
- **interface** `consume` takes `authorizer`. Executors must authenticate who authorized each spend; holding a grant and its signature is not authority. New reason `UNAUTHORIZED_DELEGATE`. Raised on the thread by zexoverz.
- **interface** `liveDebits(grantHash, asset, maxCount)` returns each unexpired debit's expiry and amount, so wallets can show what is spendable now and when more frees up. Raised on the thread by Anzus_GemWallet.
- Movement must come from the principal's own balance.
- Stated assumptions an implementer or wallet could miss: grants are public and linkable, revocation is front-runnable and needs the grant, the registry fixes the executor's address and not its code.

### Deployment (Arc testnet, 5042002)

- Superseded: registry `0xf22647d93a960db3629cAEd6D75AdC688A6947B4`, executor `0x45708e14e1B19B43cBaB9a90D4374C6bEd4a70Dd`.
- Superseded: registry `0xA4B1Cf19bE43f8c4879e779e82b6Eee026e925f1`, executor `0x2e5386E8b9c43b2c90Cd59b257e89085bA28AcD5`.

## 2026-09-25

### Specification

- First public draft, posted to Ethereum Magicians and opened as ethereum/ERCs#2037.
- `renderingHash` dropped from the signed grant; the rendering is a function of the signed fields.
- `assetCombine` reserved at `0`; a shared budget across assets is left to a later version.

### Reference

- Registry with an exact rolling window in a 1024-slot ring, minimal executor, TypeScript hashing, rendering, and strict JSON parsing, golden vectors, Halmos properties, and an ERC-7730 descriptor.

### Deployment (Arc testnet, 5042002)

- Superseded: registry `0xE3591E35c6473FB2A9D2f7370d1FE3454864fb32`, executor `0xd0F9e902b054fd8B329Ae8615F9C8247A199ecd2`.
