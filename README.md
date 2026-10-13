# ERC-8427: Portable Spend Grants

A draft ERC for a signed spend grant: one signature that lets a delegate spend native currency and ERC-20s under per-call, rolling, and lifetime caps.

- **Draft in this repo:** [`ERCS/erc-8427.md`](ERCS/erc-8427.md)
- **Magicians thread:** <https://ethereum-magicians.org/t/erc-8427-portable-spend-grants/29776>
- **ERC-8427:** submitted as [ethereum/ERCs#2037](https://github.com/ethereum/ERCs/pull/2037); it will be at <https://eips.ethereum.org/EIPS/eip-8427> once merged

## Why

`approve` is usually one token, no expiry, and no trailing window. “Daily” allowances that reset at midnight let someone spend the cap twice in two hours. Wallet permission APIs exist, but they leave the meaning of the permission opaque, so two implementations can show the same hash and still disagree on the window or whether a second asset has its own remaining.

This draft is that object: typed terms, a canonical rendering, JSON interchange, and an on-chain remaining store. Tokens do not need a hook. The registry never moves funds.

## The grant

A principal signs an [EIP-712](https://eips.ethereum.org/EIPS/eip-712) `SpendGrant` bound to one chain and one registry:

- **Who** — `principal` and `delegate`
- **Where funds may go** — one recipient, or any
- **Which assets** — native currency is the [ERC-7528](https://eips.ethereum.org/EIPS/eip-7528) address `0xEeee…EEeE`; everything else is an ERC-20. Up to 16 assets, unique and sorted
- **How much** — each asset has `maxPerCall`, `maxPerWindow`, and `maxTotal`. Zero is never unlimited
- **How those caps combine** — each asset has its own remaining. `assetCombine` is fixed at `0`; other values are reserved
- **When** — `validAfter` inclusive, `validUntil` exclusive
- **Window** — a trailing lookback in seconds (`86400` is 24 hours, not a UTC day). A debit drops out when its age is `>= windowSeconds`, so spend frees up as each payment expires, not at a reset time; `liveDebits` returns each live payment's expiry, so a wallet can show what is available now and when more frees up. Lifetime never resets

Contract principals validate with [ERC-1271](https://eips.ethereum.org/EIPS/eip-1271); [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702) accounts also accept their own key's signature. Revoke is per hash and permanent, and only the principal's own revocation stops a grant: anyone can revoke a hash in their own namespace, which has no effect on it.

The registry’s `consume` records the debit. It rejects a payee of zero, the principal, the registry, the executor, or the asset itself in either mode, checks code only on the asset being spent (and not an EIP-7702 account), emits `GrantConsumed` indexed by grant hash, principal, and recipient so a principal's wallet can find its spends by address, and lets anyone `evict` expired debits in bounded pieces so a burst expiring at once does not land its whole cost on the next spend. A separate executor must authenticate who authorized the spend (holding the grant and its signature is not enough, since both are public after first use), pass the address it authenticated to `consume`, and call it in the same transaction as moving the principal's funds, reverting if either step fails. The registry rejects any authorizer other than the grant's delegate.

The reference ships three executors. `SpendGrantExecutor` authenticates the delegate as its caller. `SpendGrantAuthorizationExecutor` also accepts a delegate-signed EIP-712 authorization that anyone may submit, with the grant hash computed by the executor, a nonce recorded under the signer before `consume`, a deadline, and cancellation. `SpendGrantRedemptionExecutor` also accepts ERC-7710 redemptions performed by the principal's own account: a caveat enforcer, `SpendGrantRedemptionEnforcer`, placed once on the principal's root delegation, with that delegation passed in its `args`, records the redeemer the manager authenticated, scoped to the exact spend and held in transient storage, and the executor takes the record once before `consume`; a caveat on any other delegation records nothing, and no other caller can use the record path. Both ask the token for exactly the amount `consume` records and support ERC-20 assets only; a transfer fee or a rebase is the token's behavior, and the caps bound the request, as the allowance does (the tests show the optional balance check as an extension). Spending native currency from the principal needs an account adapter. This draft does not specify account adapters, a caveat format, swap venues, or compliance screening.

## This repository

|                                       |                                                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Draft ERC                             | [`ERCS/erc-8427.md`](ERCS/erc-8427.md)                                         |
| Golden vectors                        | [`vectors/v1.json`](vectors/v1.json)                                                                             |
| Solidity reference                    | [`src/`](src/), tests in [`test/`](test/)                                                                         |
| TypeScript hashing / rendering / JSON | [`packages/grants/`](packages/grants/)                                                                           |
| ERC-7730 display descriptor           | [`descriptors/spend-grant.erc7730.json`](descriptors/spend-grant.erc7730.json)                                   |
| Deployments                           | [`deployments/`](deployments/) (Arc testnet: registry `0x37ceecB34B97B39D5B07e8D7Dd974A5a9aD14425`)             |

Neighboring standards (ERC-7710, 7715, 8226, and the bounded-agent-actions draft) are cited in the Rationale.

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

`pnpm test:symbolic` runs the [Halmos](https://github.com/a16z/halmos) properties in `test/symbolic/` (`pip install halmos`). `pnpm analyze` runs [Aderyn](https://github.com/Cyfrin/aderyn) over `src/`. `pnpm test:fork` runs `test/fork/`, which drives the redemption enforcer and executor through MetaMask's DelegationManager v1.3.0 as deployed on Arc testnet, over the `arc_testnet` RPC; without `FORK_TESTS=true` those tests are skipped, so `pnpm check` stays offline. None of the three is part of the ERC bundle.

Solidity and TypeScript must reproduce the same domain separator, struct hash, and digest. TypeScript also checks the canonical rendering bytes.

## Deploy

`script/Deploy.s.sol` deploys a registry and the authorization executor, which accepts both direct calls and relayed delegate-signed authorizations, and writes the addresses to `deployments/<chainId>.json`. On chains that use Ethereum's CREATE address rule, a fresh account (nonce 0) gives the same addresses on every chain. Never redeploy at an address a previous registry occupied on a chain whose state was reset but kept its chain ID: the signing domain would be the same with revocations and usage gone. The registry and executors need Shanghai (PUSH0); the redemption enforcer needs Cancun (transient storage) and refuses to deploy without it. `evm_version` is pinned to `cancun` so the bytecode does not move with Foundry's default. The redemption executor and its enforcer are exercised in the tests and are not deployed; deploying that pair means fixing the enforcer to the chain's ERC-7710 delegation manager, and the registry to that executor.

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
