# Changelog

What changed in the ERC-8427 draft, its reference implementation, and the Arc testnet deployment, newest first. Dates are commit dates. An entry marked **interface** changes the registry ABI, the typed data, or `consume` behavior; grants signed or registered against an earlier registry do not carry over, because a new registry is a new domain.

The draft is [`ERCS/erc-8427.md`](ERCS/erc-8427.md), under review in [ethereum/ERCs#2037](https://github.com/ethereum/ERCs/pull/2037). Discussion is on the [Magicians thread](https://ethereum-magicians.org/t/erc-8427-portable-spend-grants/29776).

## 2026-10-14

- Integration review fixes. x402: the facilitator, in Solidity and TypeScript, refuses a deadline beyond `maxTimeoutSeconds` or within 5 seconds, reports `insufficient_funds` only for a real balance or allowance shortfall, refuses native currency, keeps the transaction hash when a send fails and reconciles after a timeout, and draws a random nonce; the Solidity README's error table is normative. Safe: the stale update is shown to be `StaleVersion`, the fallback-handler requirement and SignMessageLib approval are tested, and the approval is bounded. ERC-8004: the salt includes the identity chain, and `unsetAgentWallet`, contract wallets, and the deployed `MetadataSet` events are tested. ERC-4337: per-run keys and salts, fees at Arc's base fee, and a four-operation bundle that exhausts the window.
- Integration tests: `test/integrations/x402/` settles x402 payments under a registered grant through `SpendGrantAuthorizationExecutor`, with a proposed mapping of x402's payment requirements, payload, and error codes. No change to the draft or the contracts; the tests are not copied into the ERC bundle.
- The README lists integrations others have built against the reference.
- Integration tests: `test/integrations/safe/` runs Safe v1.4.1 on Arc testnet against the deployed registry and executor, with a 2-of-3 Safe registering, updating, and revoking as principal and a 2-of-2 Safe authorizing spends as delegate through ERC-1271. It is a fork test; `pnpm test:fork` now runs every `*Fork.t.sol` under `test/`.
- Integration tests: `test/integrations/erc8004/` grants to an agent's wallet resolved from the ERC-8004 Identity Registry on Arc testnet, and shows that a grant binds the address, not the identity: after `setAgentWallet` or a transfer of the agent, the old wallet spends until the principal revokes, the new wallet fails `UNAUTHORIZED_DELEGATE`, `update` cannot move the grant (`FixedField`), and rebinding is a revocation and a new registration. A salt derived from the identity registry and agent id labels the grant and authorizes nothing. It is a fork test.
- Integration tests: `test/integrations/erc4337/` runs an eth-infinitism SimpleAccount v0.7 on Arc testnet as a grant's delegate, spending through UserOperations submitted to EntryPoint v0.7, with a paymaster sponsoring an account that holds no gas or tokens. A spend the grant refuses, such as after a revocation or a cap cut, passes validation and fails in execution with `SpendGrantError(reason)` while the paymaster is still charged, so senders should call `check` first. The deployed SimpleAccount has no ERC-1271, so the executor rejects its owner's relayed authorizations with `BadAuthorization`. It is a fork test.
- TypeScript: `packages/x402-spend-grant/` (`@spend-grants/x402`) implements the proposed x402 `spend-grant` mapping off chain: a client helper that signs the `SpendAuthorization` for an `accepts` entry, and a facilitator whose `verify` simulates and `settle` submits `spendWithAuthorization`, returning x402 v2 responses with the mapping's error codes. Its tests run against a local anvil in `pnpm check`. The x402 integration README now names the `extra.executor` key, the payload's string encodings, and the `NativeRequiresAccountAdapter` code.

## 2026-10-13

**interface** Grants are registered on chain by the principal instead of signed and handed to the delegate. The delegate holds only the grant's id, the principal changes or revokes the grant by that id, and both parties list their grants and read their state from the registry. This needs a new registry. The Arc testnet deployment recorded on 2026-10-05 runs the previous design and stays on chain; this design is deployed beside it (see Deployment below).

### Specification

- **interface** `register(terms)`, callable only by the principal, stores a grant's full terms and returns `grantId`, the EIP-712 digest of the registered terms under the same type, domain, and hashing rules as before. Nothing is signed over a grant. Structural validation runs in `register` and `update`, not in `consume`. The preamble description, Abstract, Motivation, and Terms describe registered grants, and Terms defines `grantId`.
- **interface** `update(grantId, expectedVersion, terms)` changes a grant in place: everything but `principal`, `delegate`, and `windowSeconds` (`FixedField`), with usage kept, `salt` ignored, and `version` incremented. `expectedVersion` must equal the current version (`StaleVersion`), so an update built from an older version cannot undo a newer one. The caps in force are always the current terms', evaluated against all usage since registration. The new section Registering and changing a grant states each consequence: lowering `maxTotal` to or below `spent` exhausts the asset, lowering `maxPerWindow` to or below the window's spend blocks it until debits expire, a removed asset keeps its usage for when it is listed again, moving `validUntil` or `validAfter` revives, ends, pauses, or resumes the grant, and a recipient change applies from the next spend. Changing the delegate or the window still takes a revocation and a new grant, which starts with no usage.
- **interface** `revoke(grantId)` is open only to the principal and reverts for an unknown id (`UnknownGrant`); a revoked id stays registered, so identical terms cannot be registered again. `revoked(grantId)` replaces `revoked(principal, grantHash)`.
- **interface** New views: `getGrant` (terms, version, timestamps, revoked flag), `parties`, `grantsOf` and `grantsTo` (paginated, append-only lists), and `grantState` (status, caps, usage, next expiry, the principal's balance and allowance read fail-soft under a gas stipend with a 63/64 guard, and `spendableNow`). The spendable-now formula moves from wallet guidance into `grantState`.
- **interface** `check(grantId, authorizer, asset, amount, recipient)` returns the result of the evaluation `consume` runs. Given enough gas, `check` returns `OK` exactly when `consume` succeeds and otherwise the reason `consume` reverts with, and a registry may not add a failure mode outside the reason table.
- **interface** Every `grantHash` parameter and event field (`usage`, `rollingUsage`, `liveDebits`, `evict`, `GrantConsumed`) is now `grantId`.
- **interface** `consume(grantId, authorizer, asset, amount, recipient)` evaluates the stored terms; an unknown id fails with the new reason `NONEXISTENT`. There is no signature check, and structural validity is checked at registration, so the asset-code check is the only `INVALID_GRANT` condition left in `consume`.
- **interface** Revert data is normative: `SpendGrantError(uint8)` carries the reason's number, and the lifecycle errors are `NotPrincipal`, `GrantExists`, `UnknownGrant`, `GrantIsRevoked`, `StaleVersion`, and `FixedField`, and `grantState` reverts with `InsufficientGas` when it cannot give a read its whole stipend. Reason numbers are fixed and only appended, and the table lists them; `NONEXISTENT` is 14, and `BAD_SIGNATURE` (2) is reserved and never returned.
- **interface** Events: `GrantRegistered` and `GrantUpdated` carry each version's full terms, `GrantRevoked` is `(grantId, principal, delegate)`, and `GrantConsumed` is indexed by `grantId`, principal, and recipient.
- **interface** `register` and `update` reject a `recipientMode == 0` grant whose recipient is the registry, the executor, or a listed asset, since it could never pay in at least one listed asset; `consume` keeps its payee check.
- Canonical rendering: `Revocation registry: {revocationRegistry}` becomes `Registry: {registry}`; the first line stays `Spend grant v1`. JSON interchange: `revocationRegistry` becomes `registry`.
- Signatures cover delegate-signed authorizations only, with the same rules applied to the signer.
- Executor: an executor reads a grant's principal and delegate from its trusted registry, never from call input, and should revert with `NONEXISTENT` for an unknown id; knowing a `grantId` is not authorization. A signed authorization names `grantId`, and its nonce is recorded before `consume` or movement because the movement can reenter. The ERC-7710 record is keyed on the `grantId` in the execution calldata, with the principal read from the registry, and nothing is recorded for an unknown id.
- The ERC-7710 redemption enforcer accepts only the principal's own root delegation to the grant's `delegate`, redeemed by that delegate, and, for a grant the registry knows, reverts on every other delegation that carries it: one open to any delegate or to another account that re-delegates, a principal's delegation below the root, one signed by any other account, including the grant's delegate, and on a redemption by anyone but the delegate. It must also revert on any execution that is not a single default-mode call to the executor's spend function, which the reference already did. Before, the caveat was inert on any other delegator's delegation and on a principal's delegation below the root, and any other redeemer was recorded for `consume` to reject. Found by the money-path review: an account that is one grant's principal and another grant's delegate could sign a delegation open to any delegate, carrying the caveat, for its own grants, and anyone could redeem it to spend, through the direct path, under the grants others gave that account. The Rationale says why every other shape is refused.
- Security Considerations: terms are public from registration and the lists link each grant to both parties; a pending `update` can be front-run like `revoke`; an update applies to every unused signed authorization, which names the id and not a version, and expiry no longer ends one for good; anyone can add grants to a delegate's list, so wallets page through it and filter by principal; `grantState` is only as reliable as the token it reads; a contract principal's call policy is its grant policy; revocation needs no stored record; the chain-reset rule now rests on identical terms getting the same `grantId` while the executor's nonces are gone.
- Rationale: why grants are registered and what that costs, signed registration left to a later extension, why three fields are fixed and `salt` is ignored on update, why revoked ids stay occupied, why `check` shares `consume`'s evaluation and the encoding is normative, why `grantState` reads balances fail-soft, and why the registry keeps lists rather than leaving discovery to range-limited log queries. The ERC-8226 comparison adds that caps change in place here, where ERC-8226 revokes and re-issues, and `NONEXISTENT` joins the shared reason names.
- The ERC-7730 descriptor paragraph covers `register` and `update` calldata, and Test Cases no longer mention a grant signature.

Superseded, with where each was stated:

- Signed grants: the principal signing `grantHash`, `consume(grant, grantSignature, …)`, and choosing the executor "by choosing which registry to sign against" (thread post #1). The principal-side ERC-1271 and EIP-7702 rules are gone, so the question in #1 about checking an EIP-7702 principal's key before ERC-1271 is moot for principals; the same ordering now applies to delegates signing authorizations.
- "The executor must compute the grant hash itself" for a signed authorization (#5); it reads the grant's delegate from its registry.
- The ERC-7710 record keyed on "the grant hash (computed under the executor's registry from the execution calldata)" (#9); it is keyed on the `grantId` in the calldata.
- "Wallets SHOULD revoke the old hash when tightening a grant" (#11; 2026-10-05); a grant is tightened with `update`. Separate grants still stack.
- "A contract principal's ERC-1271 policy is its grant-signing policy" (#11; 2026-10-05); its call policy is.
- Finding "the hashes of grants it has lost" through `GrantConsumed` (#11, #19); `grantsOf` lists every grant.
- Replacement sizing `min(T, M) - S` (#17; 2026-10-12) and the lesser-of rule before it (2026-10-06). With `update`, lowering `maxTotal` from 1000 to 800 after 700 is spent leaves 100, with no sizing.
- Replacing a grant: holding the replacement back until the revocation is final, the disclosure that a replacement's window starts empty, "a signed grant appears nowhere on chain until its first use", and "I didn't add replaces" (#18; 2026-10-06).
- `hashGrant` as the value a wallet revokes, then reading `revoked` (#18; 2026-10-06), and the SHOULD to keep `grantSignature` for revocation; `revoke` and `update` revert for an id that is not registered.
- `GrantRevoked` naming the caller's namespace, and the rules for reading it (2026-10-06 and earlier); only the principal can revoke.
- "Encoding of revert data is implementation-defined" and "a view helper that returns `(bool, reason)` is not part of `ISpendGrantRegistry`".
- "Registry authors who want a single debit per transaction add their own lock"; a lock that `check` cannot see would break the equivalence.
- A caveat attached by any delegator other than the principal being inert, and the ERC-7710 redeemer of a sub-delegation or of a delegation open to any delegate being recorded as itself for `consume`'s comparison to reject (#9; 2026-10-05). The enforcer now reverts on both, so that comparison no longer does the filtering on this path.
- The list of what reverts on the ERC-7710 path, and "apart from the record rule above, those requirements are unchanged" (#19; 2026-10-13). A principal's delegation below the root, a delegation naming any other delegate, and a redemption by anyone but the delegate now revert too, so a delegate's account as the root with the principal's delegation below it reverts instead of paying as a direct call.

### Reference

- Types: `Reason` gains `NONEXISTENT` (14) and keeps `BAD_SIGNATURE` as reserved; `SpendGrantError(Reason)`, the six lifecycle errors, `InsufficientGas`, and `GrantState`. The `REASON_*` name constants follow, with `REASON_NONEXISTENT` added.
- `SpendGrantRegistry`: `register`, `update`, `revoke`, `getGrant`, `parties`, `grantsOf`, `grantsTo`, `grantState`, and `check`, with `check` and `consume` sharing one internal evaluator. The window length always comes from the stored terms, so no external function and no debit function takes a `windowSeconds` argument. The ring logic is unchanged.
- Executors take a `grantId` and read the principal and delegate with `parties`: `spend(grantId, asset, amount, recipient)` and `spendWithAuthorization(grantId, …)`; an unknown id reverts with `NONEXISTENT`. The `SpendAuthorization` type names `grantId`.
- `SpendGrantRedemptionEnforcer`: the execution must call `spend(bytes32,address,uint256,address)` on the executor; the record is keyed on `grantId`, the principal comes from `parties`, and an unknown id records nothing. `beforeHook` reverts with `WrongDelegator`, `NotRoot`, `WrongDelegate`, or `WrongRedeemer` unless the delegation is the principal's root delegation naming the grant's delegate and the redeemer is that delegate; an unknown id still records nothing and does not revert.
- TypeScript: `revocationRegistry` becomes `registry` in types, parsing, and rendering; `SpendAuthorization.grantHash` becomes `grantId`.
- Vectors: `v1.json` keeps the domain separator, struct hash, digest (now `grantId`), and rendering bytes (regenerated for the label), without the grant-signature fields; `authorization-v1.json` is regenerated for the new type.
- ERC-7730 descriptor: calldata formats for `register` and `update`; `deployments` lists the Arc testnet registry.
- Tests: 371 forge tests (157 before), 24 TypeScript tests (20 before), 12 fork tests on the live manager, and 15 Halmos properties with 2 canaries that must fail. New: lifecycle (every error and every update consequence), `check` order, revert encoding against the literal selector and numbers, `grantState` (each status, each bound of `spendableNow`, hostile tokens, starved gas), list pagination and spam, and a fuzzed and Halmos-proved `check`/`consume` equivalence with canaries that must fail. `SpendGrantUpdate.t.sol` replaces `SpendGrantReplacement.t.sol`: after an update to 800 with 700 spent, spending stops at 800, the window does not restart, and separate grants still stack. The invariant suite compares the registry with an independent model across `consume`, `update`, and `revoke`. Interleaving tests cover a principal revoking, lowering, pausing, or removing an asset from inside a token hook during a spend, updates inside a redemption and between the record and the execution, and re-entry into `grantState` from inside its own read; money-path tests cover replay across a chain split and a second executor, retrying accounts, calldata padding, and a delegation open to any delegate that carries the caveat, signed by an account that is also a delegate, which reverts; redemption tests, on the mock and the live manager, cover a loop from the delegate through another account and back, which pays once, and a hostile account in that loop, whose call the executor refuses before consulting any record. A mutation run over the reference found gaps that new tests close: the edges of the strict signature form (an inclusive low-s bound, exactly 65 bytes, a `v` of 27 or 28, and no ECDSA for 23-byte code that is not a designator), ERC-1271 answers that are not exactly one successful word, the library's `isValid`, `evict` dropping debits from storage, an unknown `recipientMode` with a zero recipient, a balance read that reverts with one word, the slot size at the amount bound, and the wiring each constructor checks. The ring is checked against the previous registry's ring as an oracle, and the `grantState` gas guard is swept warm and cold. The ERC-7710 matrix (8,130 cases, unchanged, and 494 strikes inside successful calls, down from 3,255 because only the two shapes that redeem the principal's root delegation to the delegate still pay; both pinned per test), the record Halmos properties against a registered grant, and the fork tests on MetaMask's DelegationManager v1.3.0 run under id keying.
- Deployment (Arc testnet, 5042002), both verified: registry `0xe8987A22a1e3fd4a63cB517A9476B9d214388287`, executor `0xB99785329AbEc9936b6EF6350015be39D3392646`. Registry `0x37ceecB34B97B39D5B07e8D7Dd974A5a9aD14425` and executor `0x08493Be1675070c2069a719A850f2F9d4624177E` run the previous design.

## 2026-10-12

No interface change. The Arc testnet deployment is unchanged.

### Specification

- Correction, Replacing a grant: the 2026-10-06 rule sized a replacement's lifetime cap as the lesser of the requested value and what the earlier grant had left, which did not take the earlier spend off the new total, so the delegate could pass it. With `maxTotal` 1000, 700 spent, and a new total of 800, it allowed 300 more instead of 100. To hold spend under the earlier grant and the replacement to a new lifetime total `T`, a wallet now signs no more than `min(T, M) - S`, where `M` is the earlier `maxTotal` and `S` what the earlier grant spent, read once the revocation is final, and leaves the asset out when that is zero or less. Raised by ted0x on the thread.
- Removed text that was not a requirement, a risk specific to this ERC, or the reason for a design choice, including chain-specific notes (Hedera's RPC decimals, Arbitrum's clock bounds, USDC's blocklist and `permit`), gas figures from the reference, relayer advice, and notes on accounts that can sign but cannot send transactions. Three requirements went with it: the SHOULD for relayers to cap forwarded gas, the SHOULD to keep a gas reserve where the native currency is also the spent ERC-20, and the MAY to confirm a revocation by simulating `consume`. The raw-digest note on session-key policies is also removed, and the delegation-framework paragraph in Security Considerations points to the Executor requirements instead of restating them.
- The recommendation that a wallet confirm a listed asset answers `balanceOf` and `decimals` moves from the Rationale to Security Considerations, still a SHOULD.
- Delegation framework: the enforcer writes a record only at the root delegation of the chain, whose delegator performs the execution, when that delegator is the principal and that delegation carries the caveat exactly once. Under the earlier rule a principal's delegation lower in a chain also wrote one, which the execution might never take, and a second copy of the caveat could write it again after a hook took the first; anyone who could drive the principal's account in between could pay the same spend again. Found while checking a point zexoverz raised on the thread, and reproduced on MetaMask's DelegationManager v1.3.0.
- Two statements in the Rationale's ERC-8226 comparison are updated for ERC-8226 as revised on 2026-10-09 (ethereum/ERCs#2060): only one mandate may be active per agent, principal, and asset, not per agent and principal, and `WRONG_ASSET` is no longer listed among the reason names the two share, since ERC-8226's `MandateReason` no longer has it.
- Two more statements in that comparison are corrected against ERC-8226's current text. It said ERC-8226's cumulative counter never resets, but a re-issued mandate starts at zero; it now says the counter does not reset on `extendMandate`. It said the shared reason names match where the conditions coincide, but `EXPIRED` and `OVER_TX_CAP` differ at the edges (ERC-8226's `EXPIRED` applies after `validUntil` and this proposal's from it, and this proposal's `OVER_TX_CAP` also covers a zero amount); it now calls them ERC-8226's names for the corresponding conditions.

### Reference

- `SpendGrantRedemptionEnforcer` checks for the root: the redeemer passes the delegation in the caveat's `args`, the manager's hash of it must equal the hash the hook received, its authority must be the root authority, and it must carry the caveat exactly once. A delegation of the principal's with no `args`, or with `args` that are not that delegation, reverts, and so does a root that carries the caveat twice. Redeemers must now fill `args` for this caveat; on MetaMask's live manager a root with one caveat costs about 21,000 more gas (18,000 execution, 3,100 calldata), more for larger roots, since `args` carry the whole delegation.
- The mock delegation manager follows v1.3.0's hook order and authority links, and like v1.3.0 its delegation hash commits to each caveat's enforcer and terms but not its args; a fork test checks its hook order against the live manager. A scenario matrix (nine chain shapes, a thief in every caveat slot or as a token-callback recipient, striking at every hook through four kinds of nested redemption, alone and in pairs: 8,130 cases) finds no redemption that pays twice, and Halmos proves the enforcer writes the principal's record only at a root delegation the manager hashed that carries the caveat exactly once.
- Tests: spend under a revoked grant and a replacement sized by the corrected rule stops at the new total; two identical entries in one batch through MetaMask's DelegationManager v1.3.0 both spend; an asset whose code accepts any call passes the code check, and the spend records a debit that moved nothing.

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

- Registry `0x37ceecB34B97B39D5B07e8D7Dd974A5a9aD14425`, executor `0x08493Be1675070c2069a719A850f2F9d4624177E`. Superseded on 2026-10-13.
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
