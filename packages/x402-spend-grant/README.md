# @spend-grants/x402

An off-chain TypeScript client helper and facilitator for an [x402](https://github.com/coinbase/x402) payment that is paid from a principal's funds under an ERC-8427 spend grant. The agent signs a `SpendAuthorization`; the facilitator submits it to the reference `SpendGrantAuthorizationExecutor`. The scheme name is `spend-grant`. It is a proposed scheme for experiment and is not registered with x402. The mapping and its rationale are in [`test/integrations/x402/README.md`](../../test/integrations/x402/README.md).

The package is private and licensed CC0-1.0. It is built on [viem](https://viem.sh).

## Run

```bash
forge build                                # the tests read contracts from out/
pnpm --filter @spend-grants/x402 test
pnpm --filter @spend-grants/x402 build     # dist/ is gitignored; build before importing the package from elsewhere
```

The tests need the `anvil` binary from Foundry. The harness uses `ANVIL_BIN` when set, then `~/.foundry/bin/anvil`, then `anvil` on `PATH`. They start a local anvil on a free port, deploy `SpendGrantRegistry`, `SpendGrantAuthorizationExecutor` and `MockERC20` from `out/`, and stop anvil when they finish. They make no calls to a public RPC, so they run offline. `pnpm check` runs them after `forge test`, which builds `out/`.

## Wire format

The package follows the x402 v2 types in [`specs/x402-specification-v2.md`](https://github.com/coinbase/x402/blob/dd927a26cfefc98c24b3ec38b3a8f204dad0c60d/specs/x402-specification-v2.md) at commit `dd927a2`. The Solidity mapping leaves some details open. This package chooses:

- `extra.executor` holds the executor address. The facilitator refuses a payment whose `extra.executor` differs from its own executor.
- `nonce` and `deadline` are decimal strings, the same way x402 carries `amount`. This keeps 256-bit values out of JSON numbers.
- `recipient` in the signed data is `payTo`. `deadline` is the current time plus `maxTimeoutSeconds`.
- The signed typed data is `SpendAuthorization(bytes32 grantId,address asset,uint256 amount,address recipient,uint256 nonce,uint256 deadline)`. The domain name is `SpendAuthorization`, the version is `1`, the chain ID comes from `network`, and `verifyingContract` is `extra.executor`.

An accepts entry:

```json
{
  "scheme": "spend-grant",
  "network": "eip155:5042002",
  "amount": "250000",
  "asset": "0x<token address>",
  "payTo": "0x<resource server address>",
  "maxTimeoutSeconds": 60,
  "extra": { "executor": "0xB99785329AbEc9936b6EF6350015be39D3392646" }
}
```

The `PaymentPayload` the agent sends back:

```json
{
  "x402Version": 2,
  "accepted": { "...": "the accepts entry above" },
  "payload": {
    "grantId": "0x<32-byte grant id>",
    "nonce": "1",
    "deadline": "1700000060",
    "authorization": "0x<65-byte signature>"
  }
}
```

The `grantId` is the registered grant's id. The principal gives the delegate this id, and that is all the delegate needs to sign.

## API

```ts
SPEND_GRANT_SCHEME                            // "spend-grant"
createSpendGrantPayment({ requirements, grantId, nonce, account, now?, resource? })
spendAuthorizationDomain(chainId, executor)   // EIP-712 domain
spendAuthorizationTypes                       // the SpendAuthorization struct
verify(paymentPayload, requirements, ctx)
settle(paymentPayload, requirements, ctx)
supported(ctx)
errorCodeFromRevert(error)
spendGrantExecutorAbi
spendGrantRegistryAbi
```

`ctx` is `{ publicClient, walletClient, executor, registry, receiptTimeoutMs? }`. `receiptTimeoutMs` bounds how long `settle` waits for the receipt and defaults to viem's. `createSpendGrantPayment` signs with the delegate's `account`. `now` is the signing time in Unix seconds and defaults to the current time. `resource` is the optional x402 resource descriptor. It is not part of the signed data.

Responses:

- `VerifyResponse`: `{ isValid, invalidReason?, payer? }`
- `SettlementResponse`: `{ success, errorReason?, payer?, transaction, network }`. `transaction` is `""` when settlement fails before a transaction is broadcast or the mined transaction reverted. When a failure comes after broadcast, `transaction` holds the hash. That deviates from x402's empty-string rule so the resource server can reconcile by hash. A settlement replaced or cancelled at the same nonce returns `invalid_transaction_state` with `transaction: ""`. A repriced replacement (same call, higher fee) reports the mined hash.
- `SupportedResponse`: `{ kinds: [{ x402Version: 2, scheme, network }], extensions: [], signers: { "eip155:*": [facilitator address] } }`

## Facilitator behavior

Both `verify` and `settle` check the request first and return the x402 section 9 codes: `invalid_x402_version`, `unsupported_scheme`, `invalid_network`, `invalid_payment_requirements` (when `extra.executor` is not the facilitator's executor or `maxTimeoutSeconds` is not a non-negative integer), and `invalid_payload`. Addresses must be lower case or carry a correct EIP-55 checksum, and `amount`, `nonce` and `deadline` must be canonical decimal strings that fit in a uint256. `createSpendGrantPayment` applies the same rules and throws instead of signing input the facilitator would refuse.

`asset`, `amount` and `payTo` come from the `requirements` the resource server passes. `grantId`, `nonce`, `deadline` and `authorization` come from the payload. Requirements whose amount or `payTo` differ from what the agent signed fail the signature check and report `invalid_spend_grant_unauthorized_delegate`. The facilitator cannot redirect or raise a payment.

- `verify` simulates `spendWithAuthorization` with `eth_call`. Nothing is submitted.
- `settle` simulates, submits, and waits for the receipt. If the receipt reverted, it simulates again at that block to recover the revert reason and map it to a code. If the re-simulation succeeds, the code is `invalid_transaction_state`.
- `payer` is the grant's principal, read from the registry's `parties(grantId)`. It is omitted when the grant is unknown or a pre-check fails.

Error codes:

| Revert | `errorCode` |
| --- | --- |
| `SpendGrantError(reason)` | `invalid_spend_grant_<reason>`, the reason in lower case, for example `invalid_spend_grant_over_cumulative_cap` |
| `NonceAlreadyUsed()` | `invalid_spend_grant_nonce_used` |
| `AuthorizationExpired()` | `invalid_spend_grant_authorization_expired` |
| `BadAuthorization()` | `invalid_spend_grant_signature` |
| `TransferFailed()` | `insufficient_funds` |
| `NativeRequiresAccountAdapter()` | `invalid_payload` |
| any other revert in `verify` | `unexpected_verify_error` |
| mined revert whose re-simulation succeeds | `invalid_transaction_state`, with `transaction: ""` |
| settlement replaced or cancelled by another transaction at the same nonce | `invalid_transaction_state`, with `transaction: ""` because the sent hash was never mined |
| failure after broadcast (receipt timeout, RPC error while polling) | `invalid_transaction_state`, with the hash in `transaction` |
| any other revert in `settle` | `unexpected_settle_error` |

After a post-broadcast failure the transaction may still be mined. The resource server must reconcile by hash before it retries, or it can pay twice.

`TransferFailed()` covers every token failure, including a short balance or allowance. A caller can tell which by reading the token's `balanceOf` and `allowance`.

## Wiring into an HTTP handler

The handler below serves the three endpoints with `node:http`. The facilitator account sends one transaction per settlement, so concurrent settles need viem's `nonceManager`. Without it, parallel settles read the same pending nonce and all but one fail.

```ts
import { createServer } from "node:http";
import { createPublicClient, createWalletClient, http, nonceManager, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { settle, supported, verify, type PaymentPayload, type PaymentRequirements } from "@spend-grants/x402";

const transport = http(process.env.RPC_URL);
const ctx = {
  publicClient: createPublicClient({ transport }),
  walletClient: createWalletClient({
    account: privateKeyToAccount(process.env.FACILITATOR_KEY as Hex, { nonceManager }),
    transport,
  }),
  executor: process.env.EXECUTOR_ADDRESS as Address,
  registry: process.env.REGISTRY_ADDRESS as Address,
};

createServer(async (req, res) => {
  const send = (status: number, body: unknown) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body)); // responses hold no bigint, so this needs no replacer
  };
  try {
    if (req.method === "GET" && req.url === "/supported") return send(200, await supported(ctx));
    if (req.method !== "POST" || !["/verify", "/settle"].includes(req.url ?? "")) return send(404, {});
    let raw = "";
    for await (const chunk of req) raw += chunk;
    let body: { paymentPayload: PaymentPayload; paymentRequirements: PaymentRequirements };
    try {
      body = JSON.parse(raw);
    } catch {
      return send(400, { error: "invalid JSON" });
    }
    const run = req.url === "/verify" ? verify : settle;
    return send(200, await run(body.paymentPayload, body.paymentRequirements, ctx));
  } catch {
    return send(500, { error: "internal error" });
  }
}).listen(Number(process.env.PORT ?? 4402));
```

The resource server calls `POST /verify` before it does the work and `POST /settle` before it returns the resource, which is what the Limits below require.

## Limits

- `verify` is a simulation, not a reservation. The principal can update or revoke the grant, and another payment can use the remaining cap, between `/verify` and `/settle`. Serve the resource only after `/settle` succeeds.
- The payload is a bearer authorization until it settles or its deadline passes. Anyone who sees it can submit it, but only to the `payTo` and for the `amount` it names. A short `maxTimeoutSeconds` bounds that window. The agent can end it early with `cancelNonce`.
- ERC-20 only. The reference executors do not move native currency.
- The tests cover EOA agents only. ERC-1271 and EIP-7702 delegates are covered by the core suite in [`test/SpendGrantAuthorization.t.sol`](../../test/SpendGrantAuthorization.t.sol).
