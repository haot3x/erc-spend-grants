# Order amendments under a spend grant

This ports the cap-cut-after-consent boundary from the [order-amendment integration experiment](https://github.com/haot3x/agent-order-amendments/blob/d73681f932c4bfe7b140ff4d99f99d4f426f9acc/ERC8427.md) into the reference suite, following the [discussion invitation](https://ethereum-magicians.org/t/erc-8427-portable-spend-grants/29776/26).

```bash
forge test --match-path 'test/integrations/order-amendments/*'
```

No fork, RPC endpoint or extra dependency is required. The tests use the repository's unchanged `SpendGrantRegistry`, `SpendGrantExecutor` and `MockERC20`; the consumer contract is both the registered delegate and the fixed escrow recipient. Only the executor has a token allowance from the buyer.

## Cases

The buyer funds an earlier order with 600 and the target order with 100, under one grant with lifetime cap 1000. Both parties approve increasing the target total to 180. The setup debits leave the rolling window before the amendment so that only the lifetime cap binds.

| Interleaving | Expected result |
| --- | --- |
| Both approve; preflight passes; principal lowers cap to 750; execute | `OVER_CUMULATIVE_CAP`; lifetime usage stays 700, target stays at price 100/revision 0 with its original terms hash, balances and rolling usage stay unchanged, and no debit or applied-amendment event persists. The grant update remains in force. |
| Both approve; principal lowers cap to 800; execute | The 80 supplement succeeds exactly once: lifetime usage 780, target price 180/revision 1 and new terms hash; the earlier order is unchanged. |
| Execution fails under 750; cap is restored to 800 | The old attempt stays consumed. A new intent with only the buyer's approval cannot execute; fresh approval by both parties permits the supplement. |

## Scope

`check` is a preflight read, not a reservation. The order consumer must call the executor against the live grant when it actually funds the amendment. Grant updates do not supply or replace counterparty consent.

The small consumer models the relevant application boundary: separate explicit approvals, an order/base-state binding, and an isolated self-call whose failure leaves the order and funds unchanged while consuming the outer execution attempt. This consumed-on-failure policy belongs to the order experiment, not ERC-8427. It is deliberately not a complete ERC-8001 implementation: EIP-712 messages, EOA/ERC-1271 signature validation, deadlines, invalidation, delivery and payout are not reproduced here. The linked experiment tests the full signed workflow separately. These tests establish neither independent profile conformance nor production escrow safety.

Only test files are added. As with the other integrations, they are not promoted into the ERC assets bundle.
