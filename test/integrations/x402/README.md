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
| `accepts[i].maxTimeoutSeconds` | `deadline = now + maxTimeoutSeconds` |
| `accepts[i].extra` | the executor address, so the agent can compute the authorization digest |
| PAYMENT-SIGNATURE `payload` | `{ grantId, nonce, deadline, authorization }` |
| facilitator `/verify` | `spendWithAuthorization` simulated with `eth_call` |
| facilitator `/settle` | `spendWithAuthorization` submitted |
| `SettlementResponse.payer` | the grant's principal, from `parties(grantId)` |

The grant uses `recipientMode = 1`, because `payTo` differs from one resource server to the next. The signature binds `payTo` and `amount`, so the facilitator can neither redirect a payment nor raise it.

## Error codes

x402's `exact` error codes are scoped to that scheme, so this mapping derives its own from the revert:

| Revert | `errorCode` |
| --- | --- |
| `SpendGrantError(reason)` | `invalid_spend_grant_<reason>`, the reason name in lower case, for example `invalid_spend_grant_over_cumulative_cap` |
| `NonceAlreadyUsed()` | `invalid_spend_grant_nonce_used` |
| `AuthorizationExpired()` | `invalid_spend_grant_authorization_expired` |
| `BadAuthorization()` | `invalid_spend_grant_signature` |
| `TransferFailed()` | `insufficient_funds` |

An EOA agent's signature over different terms recovers some other address, which the executor passes on and the registry rejects, so a tampered payload reports `invalid_spend_grant_unauthorized_delegate`, not `invalid_spend_grant_signature`. `TransferFailed()` covers every token failure, a short balance or allowance included; the facilitator can tell which from `grantState`.

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
| Settlement one second before the deadline | Succeeds |
| Settlement at the deadline | `authorization_expired` |
| Facilitator raises the amount or changes `payTo` | `unauthorized_delegate`; nothing paid |
| `payTo` is the registry, the executor, or the token | `wrong_recipient` |
| Amount over the grant's per-call cap | `over_tx_cap` |

## Limits

- Verification is a simulation, not a reservation: the principal can update or revoke the grant, and another payment can use the remaining cap, between `/verify` and `/settle`. The resource server should serve the resource only after `/settle` succeeds.
- The payload is a bearer authorization until it settles or its deadline passes. Anyone who sees it can submit it, though only to the `payTo` and for the `amount` it names. A short `maxTimeoutSeconds` bounds that; `cancelNonce` ends it early.
- ERC-20 only. The reference executors do not move native currency.
- Only EOA agents are exercised. ERC-1271 and EIP-7702 delegates are covered by the core suite in [`test/SpendGrantAuthorization.t.sol`](../../SpendGrantAuthorization.t.sol).
- The facilitator here is modeled in Solidity. An off-chain facilitator speaking x402's HTTP transport is not part of this test.
