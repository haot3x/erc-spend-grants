# ERC-8427: Portable Spend Grants

A draft ERC for registered spend grants: terms a principal registers on chain that let a delegate spend native currency and ERC-20s under per-call, rolling, and lifetime caps, changed in place or revoked by id.

- **Draft in this repo:** [`ERCS/erc-8427.md`](ERCS/erc-8427.md)
- **Magicians thread:** <https://ethereum-magicians.org/t/erc-8427-portable-spend-grants/29776>
- **ERC-8427:** submitted as [ethereum/ERCs#2037](https://github.com/ethereum/ERCs/pull/2037); it will be at <https://eips.ethereum.org/EIPS/eip-8427> once merged

## Why

`approve` is usually one token, no expiry, and no trailing window. “Daily” allowances that reset at midnight let someone spend the cap twice in two hours. Wallet permission APIs exist, but they leave the meaning of the permission opaque, so two implementations can show the same hash and still disagree on the window or whether a second asset has its own remaining.

This draft is that object: typed terms, a canonical rendering, JSON interchange, and an on-chain registry that holds the terms, what remains under them, and revocations. Tokens do not need a hook. The registry never moves funds.

## The grant

A principal registers a `SpendGrant` with a registry on one chain. The registry identifies it by `grantId`, the [EIP-712](https://eips.ethereum.org/EIPS/eip-712) digest of the registered terms, and that id is all the delegate needs. The terms:

- **Who** — `principal` and `delegate`
- **Where funds may go** — one recipient, or any
- **Which assets** — native currency is the [ERC-7528](https://eips.ethereum.org/EIPS/eip-7528) address `0xEeee…EEeE`; everything else is an ERC-20. Up to 16 assets, unique and sorted
- **How much** — each asset has `maxPerCall`, `maxPerWindow`, and `maxTotal`. Zero is never unlimited
- **How those caps combine** — each asset has its own remaining. `assetCombine` is fixed at `0`; other values are reserved
- **When** — `validAfter` inclusive, `validUntil` exclusive
- **Window** — a trailing lookback in seconds (`86400` is 24 hours, not a UTC day). A debit drops out when its age is `>= windowSeconds`, so spend frees up as each payment expires, not at a reset time; `liveDebits` returns each live payment's expiry, so a wallet can show what is available now and when more frees up. Lifetime never resets

The principal changes a grant in place with `update(grantId, expectedVersion, terms)`: everything but the principal, the delegate, and the window can change, the caps in force are always the current terms' against everything already spent, and `expectedVersion` makes a stale update revert instead of undoing a newer one. `revoke(grantId)` is permanent, and a revoked id can never be registered again. `grantsOf(principal)` and `grantsTo(delegate)` list every grant either side has, revoked ones included, and `grantState(grantId, asset)` returns a grant's status, caps, usage, the principal's balance and allowance, and what is spendable now. Changing the delegate or the window takes a revocation and a new grant, which starts with no usage.

The registry's `consume` records the debit. It rejects a payee of zero, the principal, the registry, the executor, or the asset itself in either mode, checks code only on the asset being spent (and not an EIP-7702 account), emits `GrantConsumed` indexed by grant id, principal, and recipient, and lets anyone `evict` expired debits in bounded pieces so a burst expiring at once does not land its whole cost on the next spend. `check` runs the same evaluation and returns the reason `consume` would give, and `consume` reverts with `SpendGrantError(uint8)` carrying that reason's number. A separate executor must authenticate who authorized the spend (knowing a `grantId` is not enough, since ids are public), pass the address it authenticated to `consume`, and call it in the same transaction as moving the principal's funds, reverting if either step fails. The registry rejects any authorizer other than the grant's delegate.

The reference ships three executors. Each takes a `grantId` and reads the grant's principal and delegate from the registry. `SpendGrantExecutor` authenticates the delegate as its caller. `SpendGrantAuthorizationExecutor` also accepts a delegate-signed EIP-712 authorization naming the `grantId`, which anyone may submit: a contract delegate signs under [ERC-1271](https://eips.ethereum.org/EIPS/eip-1271), an [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702) account's own key also signs, the nonce is recorded under the signer before `consume`, and authorizations carry a deadline and can be cancelled. `SpendGrantRedemptionExecutor` also accepts ERC-7710 redemptions performed by the principal's own account: a caveat enforcer, `SpendGrantRedemptionEnforcer`, placed once on the principal's root delegation to the grant's delegate, with that delegation passed in its `args`, records the redeemer the manager authenticated, which must be that delegate, scoped to the exact spend and held in transient storage, and the executor takes the record once before `consume`. The enforcer reverts on every other shape: a delegation open to any delegate or to another account that re-delegates, a principal's delegation below the root, a delegation signed by any other account, including the grant's delegate, and a redemption by anyone but the delegate. An execution naming a grant id the registry does not know records nothing, and no other caller can use the record path. All three ask the token for exactly the amount `consume` records and support ERC-20 assets only; a transfer fee or a rebase is the token's behavior, and the caps bound the request, as the allowance does (the tests show the optional balance check as an extension). Spending native currency from the principal needs an account adapter. This draft does not specify account adapters, a caveat format, swap venues, or compliance screening.

## This repository

|                                       |                                                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Draft ERC                             | [`ERCS/erc-8427.md`](ERCS/erc-8427.md)                                         |
| Golden vectors                        | [`vectors/v1.json`](vectors/v1.json)                                                                             |
| Solidity reference                    | [`src/`](src/), tests in [`test/`](test/)                                                                         |
| TypeScript hashing / rendering / JSON | [`packages/grants/`](packages/grants/)                                                                           |
| ERC-7730 display descriptor           | [`descriptors/spend-grant.erc7730.json`](descriptors/spend-grant.erc7730.json)                                   |
| Integration tests                     | [`test/integrations/`](test/integrations/): [x402](test/integrations/x402/) payments settled under a grant; [Safe](test/integrations/safe/) as principal and delegate on Arc (fork); [ERC-8004](test/integrations/erc8004/) agent wallet as delegate on Arc (fork); [ERC-4337](test/integrations/erc4337/) SimpleAccount as delegate through the EntryPoint on Arc (fork) |
| Deployments                           | [`deployments/`](deployments/) (Arc testnet: registry `0xe8987A22a1e3fd4a63cB517A9476B9d214388287`, executor `0xB99785329AbEc9936b6EF6350015be39D3392646`) |

Neighboring standards (ERC-7710, 7715, 8226, and the bounded-agent-actions draft) are cited in the Rationale.

Integrations built by others against this reference:

- [haot3x/agent-order-amendments](https://github.com/haot3x/agent-order-amendments/blob/d73681f932c4bfe7b140ff4d99f99d4f426f9acc/ERC8427.md): an ERC-8001 order-amendment profile that funds agreed price changes through the registry and direct executor, pinned at `d70b04c`.

What changed and when, including which changes need a new registry, is in [`CHANGELOG.md`](CHANGELOG.md).

## Status

Draft. Unaudited. [CC0 1.0](LICENSE.md).

The ERCs editors assigned the number 8427. The draft is under review in [ethereum/ERCs#2037](https://github.com/ethereum/ERCs/pull/2037).

## Check the vectors

From the repo root:

```bash
pnpm install   # also installs pinned forge-std into lib/
pnpm build
pnpm test      # forge tests (256 fuzz runs, set in foundry.toml), then TypeScript tests
```

`pnpm test:sol` and `pnpm test:ts` run either half.

`pnpm check` runs formatting, lint, both test suites, the typecheck, and `erc:check`. There is no hosted CI; run it before pushing.

`pnpm test:symbolic` runs the [Halmos](https://github.com/a16z/halmos) properties in `test/symbolic/` (`pip install halmos`). `pnpm analyze` runs [Aderyn](https://github.com/Cyfrin/aderyn) over `src/`. `pnpm test:fork` runs every `*Fork.t.sol` under `test/` over the `arc_testnet` RPC: `test/fork/` drives the redemption enforcer and executor through MetaMask's DelegationManager v1.3.0 as deployed on Arc testnet, and `test/integrations/` drives Safe v1.4.1, the ERC-8004 Identity Registry, and an ERC-4337 SimpleAccount v0.7 through EntryPoint v0.7 against the deployed registry and executor; without `FORK_TESTS=true` those tests are skipped, so `pnpm check` stays offline. None of the three is part of the ERC bundle.

Solidity and TypeScript must reproduce the same domain separator, struct hash, and `grantId`. TypeScript also checks the canonical rendering bytes.

## Deploy

`script/Deploy.s.sol` deploys a registry and the authorization executor, which accepts both direct calls and relayed delegate-signed authorizations, and writes the addresses to `deployments/<chainId>.json`. On chains that use Ethereum's CREATE address rule, a fresh account (nonce 0) gives the same addresses on every chain. Never redeploy at an address a previous registry occupied on a chain whose state was reset but kept its chain ID: registering the same terms there would give the same `grantId`, and with the executor's recorded nonces gone, the delegate's old signed authorizations would run again. `deployments/5042002.json` records the Arc testnet deployment. The registry before it, `0x37ceecB34B97B39D5B07e8D7Dd974A5a9aD14425`, runs the earlier signed-grant interface. The registry and executors need Shanghai (PUSH0); the redemption enforcer needs Cancun (transient storage) and refuses to deploy without it. `evm_version` is pinned to `cancun` so the bytecode does not move with Foundry's default. The redemption executor and its enforcer are exercised in the tests and are not deployed; deploying that pair means fixing the enforcer to the chain's ERC-7710 delegation manager, and the registry to that executor.

```bash
# dry run
forge script script/Deploy.s.sol --rpc-url arc_testnet --sender <deployer>

# broadcast and verify on the Arc testnet explorer (Blockscout)
forge script script/Deploy.s.sol --rpc-url arc_testnet --account <keystore> --broadcast \
  --verify --verifier blockscout --verifier-url https://explorer.testnet.arc.io/api/
```

The contracts are unaudited and immutable. Deploy to testnets only.

## Promote to the ERCs fork

This repository holds the only copy of the reference. The ERC submission layout is generated from it:

```bash
pnpm erc:check                      # assemble assets/erc-8427 in a temp dir and run its tests standalone
pnpm erc:promote -- --to ../ERCs    # write ERCS/erc-8427.md and assets/erc-8427/ into an ERCs checkout
```

`erc:promote` only writes files; review and commit in the ERCs checkout.

Discussion belongs on the [Magicians thread](https://ethereum-magicians.org/t/erc-8427-portable-spend-grants/29776). If you want to send a change, fork and open a pull request.
