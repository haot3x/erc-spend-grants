# x402 payments under a spend grant

[`SpendGrantX402.t.sol`](SpendGrantX402.t.sol) shows an agent paying an [x402](https://github.com/coinbase/x402) resource server from its principal's funds, under a registered ERC-8427 grant, through the reference `SpendGrantAuthorizationExecutor`. The agent holds no funds and signs only a `SpendAuthorization`; a facilitator settles it.

This is a proposed mapping for experiment, not an x402 scheme. x402's EVM `exact` scheme carries an EIP-3009 or Permit2 authorization signed by the payer, and here the signer is the grant's delegate while the funds leave the principal, so the payload is a different shape and needs its own scheme name. The tests use `spend-grant` for it; no such scheme is registered with x402.

## Run

```bash
forge test --match-path 'test/integrations/x402/*'
```

It runs with the rest of the suite in `pnpm test`. It sits under `test/integrations/`, so `pnpm erc:promote` does not copy it into the ERC bundle.

## Mapping

| x402 | Spend grant |
| --- | --- |
| `accepts[i].scheme` | `spend-grant` |
| `accepts[i].network` | CAIP-2 of the registry's chain, for example `eip155:5042002` for Arc testnet |
| `accepts[i].asset` | `asset` |
| `accepts[i].amount` | `amount` |
| `accepts[i].payTo` | `recipient` |
| `accepts[i].maxTimeoutSeconds` | the agent signs `deadline = now + maxTimeoutSeconds`; the facilitator refuses a `deadline` later than the latest block plus `maxTimeoutSeconds` (see [Facilitator checks](#facilitator-checks)) |
| `accepts[i].extra` | `{ executor }`, the executor address, so the agent can compute the authorization digest |
| PAYMENT-SIGNATURE `payload` | `{ grantId, nonce, deadline, authorization }`: `grantId` and `authorization` as hex, `nonce` and `deadline` as decimal strings, as x402 carries `amount` |
| facilitator `/verify` | `spendWithAuthorization` simulated with `eth_call` |
| facilitator `/settle` | `spendWithAuthorization` submitted |
| `SettlementResponse.payer` | the grant's principal, from `parties(grantId)` |

The grant uses `recipientMode = 1`, because `payTo` differs from one resource server to the next. The signature binds `payTo` and `amount`, so the facilitator can neither redirect a payment nor raise it.

## Facilitator checks

The facilitator, not the agent, enforces these before it calls the executor. The TypeScript package applies all of them. The Solidity model applies the `maxTimeoutSeconds`, `asset` and `deadline` checks in `_verify` and `_settle`.

- `extra.executor` must be the facilitator's own executor, or the code is `invalid_payment_requirements`. A payment signed for another executor's domain recovers a different signer and would otherwise fail with a misleading code. The Solidity model carries no `extra`, so only the TypeScript package enforces this.
- `maxTimeoutSeconds` must be at least 1, or the code is `invalid_payment_requirements`.
- `asset` must not be the native sentinel `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`, or the code is `invalid_payment_requirements`. The reference executors do not move native currency.
- The `deadline` must lie in `(t + 5, t + maxTimeoutSeconds]`, with `t` the latest block's timestamp, or the code is `invalid_payload`. The upper bound stops an agent from signing a far-future deadline, which would make the payload a long-lived bearer authorization. The lower bound, `MIN_SLACK` of 5 seconds, stops a deadline that would expire before the transaction is mined, which the facilitator would pay gas to revert. A `maxTimeoutSeconds` of 5 or less therefore never settles.
- The version, scheme, network and field formats are checked in the TypeScript package only: a contract test has no wire format.

The agent should draw a random 256-bit `nonce` for every payment. `nonceUsed` is keyed by the signer and the nonce across all of its grants and every server, so a counter or a guessable value lets one server's payload, or an attacker who saw it, burn another payment's nonce. `createSpendGrantPayment` in the TypeScript package draws one when none is given.

## Error codes

x402's `exact` error codes are scoped to that scheme, so this mapping derives its own. This table is normative for both the Solidity model and the TypeScript package, whose README links here.

| Condition | `errorCode` |
| --- | --- |
| `x402Version` is not 2 | `invalid_x402_version` |
| `scheme` is not `spend-grant` | `unsupported_scheme` |
| `network` is not the facilitator's chain | `invalid_network` |
| `extra.executor` is not the facilitator's executor; `maxTimeoutSeconds` below 1; `asset` is the native sentinel | `invalid_payment_requirements` |
| A malformed field, or a `deadline` outside the bound above | `invalid_payload` |
| `SpendGrantError(reason)` | `invalid_spend_grant_<reason>`, the reason name in lower case, for example `invalid_spend_grant_over_cumulative_cap` |
| `NonceAlreadyUsed()` | `invalid_spend_grant_nonce_used` |
| `AuthorizationExpired()` | `invalid_spend_grant_authorization_expired` |
| `BadAuthorization()` | `invalid_spend_grant_signature` |
| `TransferFailed()`, with the principal's balance or allowance below `amount` in `grantState(grantId, asset)` at the same block | `insufficient_funds` |
| `TransferFailed()` otherwise (a blocklisted payee, a paused token) | `unexpected_verify_error` in `/verify`, `unexpected_settle_error` in `/settle` |
| `NativeRequiresAccountAdapter()` (the native asset is refused before the call, so this is a fallback) | `invalid_payment_requirements` |
| Any other revert | `unexpected_verify_error` in `/verify`, `unexpected_settle_error` in `/settle` |
| `/settle` only: the mined transaction reverted but its re-simulation succeeds | `invalid_transaction_state`, with `transaction: ""` |
| `/settle` only: the transaction was broadcast and the outcome is unknown | `invalid_transaction_state`, with the hash in `transaction`; see the package README |

The Solidity model has no transaction or wire format, so it produces the revert-derived codes, `invalid_payment_requirements`, `invalid_payload` and the two `unexpected_*_error` fallbacks.

A signature over different terms is not a `BadAuthorization()` for every delegate. For an EOA delegate the executor recovers some other address, passes it on, and the registry rejects it, so a tampered `amount` or `payTo` reports `invalid_spend_grant_unauthorized_delegate`. For a delegate with code (ERC-1271, or an EIP-7702 account) the executor asks the delegate itself to validate the signature, so a tampered payload reports `invalid_spend_grant_signature`. A signature the executor cannot parse or recover is `invalid_spend_grant_signature`. An id the registry does not know is `invalid_spend_grant_nonexistent`, and the response carries no `payer`.

## What the tests show

| Case | Result |
| --- | --- |
| Facilitator settles | The principal pays `payTo` exactly `amount`; the agent and facilitator balances do not change |
| One grant, two resource servers | Both are paid; `payTo` is per payment |
| Same payment settled again | `nonce_used`; `payTo` paid once |
| Someone else submits the payment first | It pays the `payTo` the agent signed; the facilitator's settle reports `nonce_used`, and `nonceUsed(agent, nonce)` with the `payTo` balance shows it already settled |
| Agent cancels the nonce before settlement | `nonce_used`; nothing paid |
| Principal lowers the lifetime cap after verify | `over_cumulative_cap`; nothing paid, nonce still unused |
| Principal revokes after verify | `revoked`; nothing paid |
| Principal's allowance below the amount | `insufficient_funds` |
| Principal's balance below the amount | `insufficient_funds` |
| Token fails the transfer for another reason | `unexpected_verify_error` in `/verify`, `unexpected_settle_error` in `/settle`; nothing paid, nonce unused |
| Deadline beyond `maxTimeoutSeconds`, or within 5 seconds of the latest block | `invalid_payload`; nothing submitted, nonce unused |
| Deadline at the end of each accepted range | Settles |
| Settlement one second before the deadline, at the executor | Succeeds |
| Settlement at the deadline, at the executor | `authorization_expired` |
| Facilitator raises the amount or changes `payTo` (EOA agent) | `unauthorized_delegate`; nothing paid, nonce unused |
| `payTo` is the principal, zero, the registry, the executor, or the token | `wrong_recipient` |
| Amount over the grant's per-call cap | `over_tx_cap` |
| `maxTimeoutSeconds` is 0 | `invalid_payment_requirements` |
| `asset` is the native sentinel | `invalid_payment_requirements`; nonce unused |
| Authorization of 64 or 65 zero bytes | `invalid_spend_grant_signature` |
| Unknown `grantId` | `invalid_spend_grant_nonexistent`; the principal read from `parties` is zero, so no `payer` |

## Limits

- Verification is a simulation, not a reservation: the principal can update or revoke the grant, and another payment can use the remaining cap, between `/verify` and `/settle`. The resource server should serve the resource only after `/settle` succeeds.
- The payload is a bearer authorization until it settles or its deadline passes. Anyone who sees it can submit it, though only to the `payTo` and for the `amount` it names. The facilitator caps the deadline at `maxTimeoutSeconds` past the latest block, and a short `maxTimeoutSeconds` shortens the window; `cancelNonce` ends it early.
- ERC-20 only. The reference executors do not move native currency.
- Only EOA agents are exercised. ERC-1271 and EIP-7702 delegates are covered by the core suite in [`test/SpendGrantAuthorization.t.sol`](../../SpendGrantAuthorization.t.sol).
- The facilitator here is modeled in Solidity. [`packages/x402-spend-grant/`](../../../packages/x402-spend-grant/) implements the same mapping in TypeScript.
