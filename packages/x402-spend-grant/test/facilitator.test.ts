import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { getAddress, hashDomain, hashTypedData, keccak256, zeroAddress, type Address, type Hex } from "viem";
import {
  MIN_DEADLINE_SLACK_SECONDS,
  createSpendGrantPayment,
  settle,
  spendAuthorizationDomain,
  spendAuthorizationTypes,
  spendGrantExecutorAbi,
  supported,
  verify,
  type FacilitatorContext,
  type PaymentPayload,
  type PaymentRequirements,
} from "../src/index.js";
import { account, artifact, clients, deploy, startAnvil, type Deployment } from "./harness.js";

const MAX_TIMEOUT = 60;
let CHAIN_ID: number;

const registryArt = artifact("SpendGrantRegistry.sol", "SpendGrantRegistry");
const executorArt = artifact("SpendGrantAuthorizationExecutor.sol", "SpendGrantAuthorizationExecutor");
const tokenArt = artifact("MockERC20.sol", "MockERC20");

const NATIVE: Address = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
/**
 * Runtime code for a token whose balanceOf and allowance read as 2^256-1 and whose transferFrom always reverts: a
 * failure that is not a balance or allowance shortfall, as a blocklisted payee would cause.
 * 5f 35 60e0 1c 63 23b872dd 14 6016 57 | 5f 19 5f 52 6020 5f f3 | 5b 5f 5f fd
 */
const BLOCKING_TOKEN_CODE: Hex = "0x5f3560e01c6323b872dd146016575f195f5260205ff35b5f5ffd";

const deployerAcct = account(0);
const principalAcct = account(1);
const agentAcct = account(2);
const facilitatorAcct = account(3);
const observerAcct = account(4);
const serverA: Address = getAddress("0x00000000000000000000000000000000000A11CE".toLowerCase());
const serverB: Address = getAddress("0x0000000000000000000000000000000000000B0B".toLowerCase());

let stop: () => void;
let c: ReturnType<typeof clients>;
let d: Deployment;
let ctx: FacilitatorContext;
let grantId: Hex;
let snap: Hex;

const principal = () => c.wallet(principalAcct);

async function mined(hash: Hex) {
  const r = await c.publicClient.waitForTransactionReceipt({ hash });
  expect(r.status).toBe("success");
}

const tokenBalance = (who: Address) =>
  c.publicClient.readContract({ address: d.token, abi: tokenArt.abi, functionName: "balanceOf", args: [who] }) as Promise<bigint>;

const nonceUsed = (who: Address, nonce: bigint) =>
  c.publicClient.readContract({
    address: d.executor,
    abi: spendGrantExecutorAbi,
    functionName: "nonceUsed",
    args: [who, nonce],
  });

const now = async () => (await c.publicClient.getBlock()).timestamp;

const facilitatorTxCount = (blockTag: "latest" | "pending" = "latest") =>
  c.publicClient.getTransactionCount({ address: facilitatorAcct.address, blockTag });

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** With automine off, `settle` has put its transaction in the pool once the pending nonce moves. */
async function waitForPendingSettle(start: number) {
  for (let i = 0; i < 100; i++) {
    if ((await facilitatorTxCount("pending")) > start) return;
    await sleep(20);
  }
  throw new Error("settle did not broadcast");
}

/**
 * Starts `settle` with automine off, lets `frontRun` queue a competing transaction after the facilitator's
 * simulation but before the block, then mines one block holding both. The front-runner's fee is higher, so it
 * is ordered first.
 */
async function settleFrontRun(p: PaymentPayload, r: PaymentRequirements, frontRun: () => Promise<Hex>) {
  await c.testClient.setAutomine(false);
  try {
    const start = await facilitatorTxCount("pending");
    const settling = settle(p, r, ctx);
    await waitForPendingSettle(start);
    await frontRun();
    await c.testClient.mine({ blocks: 1 });
    return await settling;
  } finally {
    await c.testClient.setAutomine(true);
  }
}

const frontRunFees = { maxPriorityFeePerGas: 10n ** 11n, maxFeePerGas: 10n ** 12n } as const;

function requirements(payTo: Address, amount: bigint, asset: Address = d.token): PaymentRequirements {
  return {
    scheme: "spend-grant",
    network: `eip155:${CHAIN_ID}`,
    amount: amount.toString(),
    asset,
    payTo,
    maxTimeoutSeconds: MAX_TIMEOUT,
    extra: { executor: d.executor },
  };
}

async function pay(req: PaymentRequirements, nonce: bigint): Promise<PaymentPayload> {
  return createSpendGrantPayment({ requirements: req, grantId, nonce, account: agentAcct, now: await now() });
}

beforeAll(async () => {
  const anvil = await startAnvil();
  stop = anvil.stop;
  CHAIN_ID = anvil.chainId;
  c = clients(anvil.url, anvil.chainId);
  const deployer = c.wallet(deployerAcct);
  d = await deploy(c.publicClient, deployer);

  expect(
    await c.publicClient.readContract({ address: d.executor, abi: executorArt.abi, functionName: "registry" }),
  ).toBe(d.registry);

  ctx = {
    publicClient: c.publicClient,
    walletClient: c.wallet(facilitatorAcct),
    executor: d.executor,
    registry: d.registry,
  };

  await mined(
    await deployer.writeContract({
      address: d.token,
      abi: tokenArt.abi,
      functionName: "mint",
      args: [principalAcct.address, 1_000e6],
    }),
  );
  await mined(
    await principal().writeContract({
      address: d.token,
      abi: tokenArt.abi,
      functionName: "approve",
      args: [d.executor, 2n ** 256n - 1n],
    }),
  );

  const t = await now();
  const registered = await c.publicClient.simulateContract({
    account: principalAcct,
    address: d.registry,
    abi: registryArt.abi,
    functionName: "register",
    args: [
      {
        principal: principalAcct.address,
        delegate: agentAcct.address,
        recipientMode: 1,
        recipient: "0x0000000000000000000000000000000000000000",
        assetCombine: 0,
        windowSeconds: 86400n,
        assets: [{ asset: d.token, maxPerCall: 1e6, maxPerWindow: 5e6, maxTotal: 20e6 }],
        validAfter: t - 1000n,
        validUntil: t + 100_000_000n,
        salt: 1n,
      },
    ],
  });
  grantId = registered.result as Hex;
  await mined(await principal().writeContract(registered.request));
}, 60_000);

afterAll(() => stop?.());

beforeEach(async () => {
  snap = await c.testClient.snapshot();
});

afterEach(async () => {
  await c.testClient.revert({ id: snap });
});

describe("settlement", () => {
  it("settles from the principal to payTo; agent and facilitator hold nothing", async () => {
    const req = requirements(serverA, 250_000n);
    const p = await pay(req, 1n);
    expect(await verify(p, req, ctx)).toEqual({ isValid: true, payer: principalAcct.address });
    const res = await settle(p, req, ctx);
    expect(res).toMatchObject({
      success: true,
      payer: principalAcct.address,
      network: `eip155:${CHAIN_ID}`,
    });
    expect(res.transaction).toMatch(/^0x[0-9a-f]{64}$/);
    expect(await tokenBalance(serverA)).toBe(250_000n);
    expect(await tokenBalance(principalAcct.address)).toBe(1_000_000_000n - 250_000n);
    expect(await tokenBalance(agentAcct.address)).toBe(0n);
    expect(await tokenBalance(facilitatorAcct.address)).toBe(0n);
  });

  it("one grant pays two servers", async () => {
    const a = requirements(serverA, 400_000n);
    const b = requirements(serverB, 600_000n);
    expect((await settle(await pay(a, 1n), a, ctx)).success).toBe(true);
    expect((await settle(await pay(b, 2n), b, ctx)).success).toBe(true);
    expect(await tokenBalance(serverA)).toBe(400_000n);
    expect(await tokenBalance(serverB)).toBe(600_000n);
  });
});

describe("replay and races", () => {
  it("a retried payment is rejected by verify and settle, and paid once", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    expect((await settle(p, req, ctx)).success).toBe(true);
    expect(await verify(p, req, ctx)).toMatchObject({
      isValid: false,
      invalidReason: "invalid_spend_grant_nonce_used",
      payer: principalAcct.address,
    });
    expect(await settle(p, req, ctx)).toMatchObject({
      success: false,
      errorReason: "invalid_spend_grant_nonce_used",
      transaction: "",
      payer: principalAcct.address,
    });
    expect(await tokenBalance(serverA)).toBe(500_000n);
  });

  it("another submitter settles first", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    await mined(
      await c.wallet(observerAcct).writeContract({
        address: d.executor,
        abi: spendGrantExecutorAbi,
        functionName: "spendWithAuthorization",
        args: [
          p.payload.grantId,
          d.token,
          500_000n,
          serverA,
          1n,
          BigInt(p.payload.deadline),
          p.payload.authorization,
        ],
      }),
    );
    expect((await settle(p, req, ctx)).errorReason).toBe("invalid_spend_grant_nonce_used");
    expect(await nonceUsed(agentAcct.address, 1n)).toBe(true);
    expect(await tokenBalance(serverA)).toBe(500_000n);
  });

  it("the agent cancels the nonce", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    await mined(
      await c.wallet(agentAcct).writeContract({
        address: d.executor,
        abi: spendGrantExecutorAbi,
        functionName: "cancelNonce",
        args: [1n],
      }),
    );
    expect((await settle(p, req, ctx)).errorReason).toBe("invalid_spend_grant_nonce_used");
    expect(await tokenBalance(serverA)).toBe(0n);
  });
});

describe("a transaction that is mined and reverts", () => {
  it("the principal revokes in the same block: the reason is recovered, nothing is paid", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const sent = await facilitatorTxCount();
    const res = await settleFrontRun(p, req, () =>
      principal().writeContract({
        address: d.registry,
        abi: registryArt.abi,
        functionName: "revoke",
        args: [grantId],
        gas: 200_000n,
        ...frontRunFees,
      }),
    );
    expect(await facilitatorTxCount()).toBe(sent + 1); // the reverted transaction was mined
    expect(res).toMatchObject({
      success: false,
      errorReason: "invalid_spend_grant_revoked",
      transaction: "",
      payer: principalAcct.address,
    });
    expect(await tokenBalance(serverA)).toBe(0n);
  });

  it("another submitter spends the nonce in the same block: paid once", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const sent = await facilitatorTxCount();
    const res = await settleFrontRun(p, req, () =>
      c.wallet(observerAcct).writeContract({
        address: d.executor,
        abi: spendGrantExecutorAbi,
        functionName: "spendWithAuthorization",
        args: [p.payload.grantId, d.token, 500_000n, serverA, 1n, BigInt(p.payload.deadline), p.payload.authorization],
        gas: 500_000n,
        ...frontRunFees,
      }),
    );
    expect(await facilitatorTxCount()).toBe(sent + 1);
    expect(res).toMatchObject({ success: false, errorReason: "invalid_spend_grant_nonce_used", transaction: "" });
    expect(await tokenBalance(serverA)).toBe(500_000n);
  });
});

describe("a failure after the transaction is broadcast", () => {
  it("a receipt timeout reports invalid_transaction_state with the hash", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    await c.testClient.setAutomine(false);
    try {
      const res = await settle(p, req, { ...ctx, receiptTimeoutMs: 300 });
      expect(res).toMatchObject({
        success: false,
        errorReason: "invalid_transaction_state",
        payer: principalAcct.address,
        network: `eip155:${CHAIN_ID}`,
      });
      expect(res.transaction).toMatch(/^0x[0-9a-f]{64}$/);
    } finally {
      await c.testClient.setAutomine(true);
    }
  });

  it("a send that fails after the node took the transaction still returns the hash", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const publicClient = new Proxy(c.publicClient, {
      get(target, prop, receiver) {
        if (prop !== "sendRawTransaction") return Reflect.get(target, prop, receiver) as unknown;
        return async (...args: Parameters<typeof target.sendRawTransaction>) => {
          await target.sendRawTransaction(...args);
          throw new Error("connection reset");
        };
      },
    });
    const res = await settle(p, req, { ...ctx, publicClient });
    expect(res).toMatchObject({
      success: false,
      errorReason: "invalid_transaction_state",
      payer: principalAcct.address,
    });
    expect(res.transaction).toMatch(/^0x[0-9a-f]{64}$/);
    expect((await c.publicClient.getTransactionReceipt({ hash: res.transaction as Hex })).status).toBe("success");
    expect(await tokenBalance(serverA)).toBe(500_000n);
  });

  /** A client whose wait for the receipt fails and whose send is handed to `send`, which may not forward it. */
  function brokenWait(send: (serialized: Hex) => Promise<void>) {
    return new Proxy(c.publicClient, {
      get(target, prop, receiver) {
        if (prop === "waitForTransactionReceipt") {
          return () => Promise.reject(new Error("rpc unavailable"));
        }
        if (prop !== "sendRawTransaction") return Reflect.get(target, prop, receiver) as unknown;
        return async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
          await send(serializedTransaction);
          return keccak256(serializedTransaction);
        };
      },
    });
  }

  const cancelFacilitatorNonce = async () =>
    mined(await c.wallet(facilitatorAcct).sendTransaction({ to: facilitatorAcct.address, value: 0n }));

  it("a failed wait for a transaction that was mined reports the mined outcome", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const publicClient = brokenWait(async (serialized) =>
      mined(await c.publicClient.sendRawTransaction({ serializedTransaction: serialized })),
    );
    const res = await settle(p, req, { ...ctx, publicClient });
    expect(res).toMatchObject({ success: true, payer: principalAcct.address });
    expect(res.transaction).toMatch(/^0x[0-9a-f]{64}$/);
    expect(await tokenBalance(serverA)).toBe(500_000n);
  });

  it("a failed wait after another transaction took the nonce and nothing was paid reports no hash", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const res = await settle(p, req, { ...ctx, publicClient: brokenWait(cancelFacilitatorNonce) });
    expect(res).toMatchObject({
      success: false,
      errorReason: "invalid_transaction_state",
      transaction: "",
      payer: principalAcct.address,
    });
    expect(await tokenBalance(serverA)).toBe(0n);
  });

  it("a failed wait after another transaction took the nonce and paid keeps the hash", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const paidByObserver = async () => {
      await mined(
        await c.wallet(observerAcct).writeContract({
          address: d.executor,
          abi: spendGrantExecutorAbi,
          functionName: "spendWithAuthorization",
          args: [p.payload.grantId, d.token, 500_000n, serverA, 1n, BigInt(p.payload.deadline), p.payload.authorization],
        }),
      );
      await cancelFacilitatorNonce();
    };
    const res = await settle(p, req, { ...ctx, publicClient: brokenWait(paidByObserver) });
    expect(res).toMatchObject({ success: false, errorReason: "invalid_transaction_state", payer: principalAcct.address });
    expect(res.transaction).toMatch(/^0x[0-9a-f]{64}$/);
    expect(await tokenBalance(serverA)).toBe(500_000n);
  });

  // The reference contracts cannot mine a revert that also re-simulates cleanly, so a test double reports the
  // receipt as reverted, at the block before the transaction was mined, where the nonce was still unused.
  it("a mined revert whose re-simulation passes reports invalid_transaction_state with no hash", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const publicClient = new Proxy(c.publicClient, {
      get(target, prop, receiver) {
        if (prop !== "waitForTransactionReceipt") return Reflect.get(target, prop, receiver) as unknown;
        return async (...args: Parameters<typeof target.waitForTransactionReceipt>) => {
          const receipt = await target.waitForTransactionReceipt(...args);
          return { ...receipt, status: "reverted" as const, blockNumber: receipt.blockNumber - 1n };
        };
      },
    });
    const res = await settle(p, req, { ...ctx, publicClient });
    expect(res).toMatchObject({
      success: false,
      errorReason: "invalid_transaction_state",
      transaction: "",
      payer: principalAcct.address,
    });
  });

  it("a same-nonce cancel mined in place of the settlement is not a success", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    await c.testClient.setAutomine(false);
    try {
      const start = await facilitatorTxCount("pending");
      const settling = settle(p, req, ctx);
      await waitForPendingSettle(start);
      await c.wallet(facilitatorAcct).sendTransaction({
        to: facilitatorAcct.address,
        value: 0n,
        nonce: start,
        gas: 21_000n,
        ...frontRunFees,
      });
      await c.testClient.mine({ blocks: 1 });
      expect(await settling).toMatchObject({
        success: false,
        errorReason: "invalid_transaction_state",
        transaction: "",
        payer: principalAcct.address,
        network: `eip155:${CHAIN_ID}`,
      });
    } finally {
      await c.testClient.setAutomine(true);
    }
    expect(await tokenBalance(serverA)).toBe(0n);
  });

  it("a repriced replacement of the settlement is the settlement: paid once, its hash reported", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    await c.testClient.setAutomine(false);
    try {
      const start = await facilitatorTxCount("pending");
      const settling = settle(p, req, ctx);
      await waitForPendingSettle(start);
      const pool = (await c.publicClient.request({ method: "txpool_content" } as never)) as {
        pending: Record<string, Record<string, { to: Address; input: Hex; value: Hex; gas: Hex }>>;
      };
      const byNonce = Object.entries(pool.pending).find(([from]) => from.toLowerCase() === facilitatorAcct.address.toLowerCase())?.[1];
      const original = byNonce?.[String(start)];
      if (original === undefined) throw new Error("the settlement is not in the pool");
      const repriced = await c.wallet(facilitatorAcct).sendTransaction({
        to: original.to,
        data: original.input,
        value: BigInt(original.value),
        nonce: start,
        gas: BigInt(original.gas),
        ...frontRunFees,
      });
      await c.testClient.mine({ blocks: 1 });
      const res = await settling;
      expect(res).toMatchObject({ success: true, transaction: repriced, payer: principalAcct.address });
    } finally {
      await c.testClient.setAutomine(true);
    }
    expect(await tokenBalance(serverA)).toBe(500_000n);
  });
});

describe("the principal acts between verify and settle", () => {
  it("a lifetime cap cut blocks settlement", async () => {
    const req = requirements(serverA, 1_000_000n);
    expect((await settle(await pay(req, 1n), req, ctx)).success).toBe(true);
    await c.testClient.increaseTime({ seconds: 86400 });
    await c.testClient.mine({ blocks: 1 });
    const p = await pay(req, 2n);
    expect((await verify(p, req, ctx)).isValid).toBe(true);

    const [terms, version] = (await c.publicClient.readContract({
      address: d.registry,
      abi: registryArt.abi,
      functionName: "getGrant",
      args: [grantId],
    })) as [{ assets: { asset: Address }[] }, bigint];
    await mined(
      await principal().writeContract({
        address: d.registry,
        abi: registryArt.abi,
        functionName: "update",
        args: [
          grantId,
          version,
          { ...terms, assets: [{ asset: d.token, maxPerCall: 1e6, maxPerWindow: 1.5e6, maxTotal: 1.5e6 }] },
        ],
      }),
    );

    expect((await settle(p, req, ctx)).errorReason).toBe("invalid_spend_grant_over_cumulative_cap");
    expect(await tokenBalance(serverA)).toBe(1_000_000n);
    expect(await nonceUsed(agentAcct.address, 2n)).toBe(false);
  });

  it("revoking after verify blocks settlement", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    expect((await verify(p, req, ctx)).isValid).toBe(true);
    await mined(
      await principal().writeContract({
        address: d.registry,
        abi: registryArt.abi,
        functionName: "revoke",
        args: [grantId],
      }),
    );
    expect((await settle(p, req, ctx)).errorReason).toBe("invalid_spend_grant_revoked");
    expect(await tokenBalance(serverA)).toBe(0n);
  });

  it("an allowance below the amount is insufficient_funds", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    await mined(
      await principal().writeContract({
        address: d.token,
        abi: tokenArt.abi,
        functionName: "approve",
        args: [d.executor, 100_000n],
      }),
    );
    expect(await verify(p, req, ctx)).toMatchObject({ isValid: false, invalidReason: "insufficient_funds" });
  });

  it("a balance below the amount is insufficient_funds", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    await mined(
      await principal().writeContract({
        address: d.token,
        abi: tokenArt.abi,
        functionName: "transfer",
        args: [serverB, 1_000_000_000n - 100_000n],
      }),
    );
    expect(await verify(p, req, ctx)).toMatchObject({ isValid: false, invalidReason: "insufficient_funds" });
    expect(await settle(p, req, ctx)).toMatchObject({
      success: false,
      errorReason: "insufficient_funds",
      transaction: "",
    });
  });

  it("a token that fails for another reason is not insufficient_funds", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    await c.testClient.setCode({ address: d.token, bytecode: BLOCKING_TOKEN_CODE });
    const sent = await facilitatorTxCount();
    expect(await verify(p, req, ctx)).toMatchObject({ isValid: false, invalidReason: "unexpected_verify_error" });
    expect(await settle(p, req, ctx)).toMatchObject({
      success: false,
      errorReason: "unexpected_settle_error",
      transaction: "",
    });
    expect(await facilitatorTxCount()).toBe(sent);
  });
});

describe("what the signature binds", () => {
  it("deadline is now + maxTimeoutSeconds: settles one second before, never at it", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    expect(BigInt(p.payload.deadline)).toBe((await now()) + BigInt(MAX_TIMEOUT));
    const deadline = BigInt(p.payload.deadline);

    const before = await c.testClient.snapshot();
    await c.testClient.setNextBlockTimestamp({ timestamp: deadline - 1n });
    expect((await settle(p, req, ctx)).success).toBe(true);
    await c.testClient.revert({ id: before });

    // anvil's eth_call already runs at the pending block's timestamp, so the pre-send simulation sees the
    // expiry and no transaction is sent.
    const sent = await facilitatorTxCount();
    await c.testClient.setNextBlockTimestamp({ timestamp: deadline });
    expect(await settle(p, req, ctx)).toMatchObject({
      success: false,
      errorReason: "invalid_spend_grant_authorization_expired",
      transaction: "",
    });
    expect(await facilitatorTxCount()).toBe(sent);
    expect(await tokenBalance(serverA)).toBe(0n);
  });

  it("the facilitator refuses a deadline beyond maxTimeoutSeconds or inside the slack, and sends nothing", async () => {
    const req = requirements(serverA, 500_000n);
    const t = await now(); // no block is mined below, so the latest block stays at t
    const sentAt = (deadline: bigint, nonce: bigint) =>
      createSpendGrantPayment({
        requirements: req,
        grantId,
        nonce,
        account: agentAcct,
        now: deadline - BigInt(MAX_TIMEOUT),
      });
    const max = t + BigInt(MAX_TIMEOUT);
    const slack = t + MIN_DEADLINE_SLACK_SECONDS;
    const refused = [max + 1n, max + 1_000_000n, slack, slack - 1n, t];
    const sent = await facilitatorTxCount();
    let nonce = 1n;
    for (const deadline of refused) {
      const p = await sentAt(deadline, nonce++);
      expect(await verify(p, req, ctx), `deadline ${deadline}`).toMatchObject({
        isValid: false,
        invalidReason: "invalid_payload",
      });
      expect(await settle(p, req, ctx), `deadline ${deadline}`).toMatchObject({
        success: false,
        errorReason: "invalid_payload",
        transaction: "",
      });
    }
    expect(await facilitatorTxCount()).toBe(sent);
    expect(await tokenBalance(serverA)).toBe(0n);
    // Both ends of the accepted range are accepted.
    for (const deadline of [max, slack + 1n]) {
      expect((await verify(await sentAt(deadline, nonce++), req, ctx)).isValid, `deadline ${deadline}`).toBe(true);
    }
  });

  it("an altered amount surfaces as unauthorized_delegate", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const res = await settle(p, { ...req, amount: "900000" }, ctx);
    expect(res.errorReason).toBe("invalid_spend_grant_unauthorized_delegate");
    expect(await tokenBalance(serverA)).toBe(0n);
  });

  it("an altered payTo surfaces as unauthorized_delegate and gets nothing", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 1n);
    const res = await settle(p, { ...req, payTo: facilitatorAcct.address }, ctx);
    expect(res.errorReason).toBe("invalid_spend_grant_unauthorized_delegate");
    expect(await tokenBalance(facilitatorAcct.address)).toBe(0n);
  });

  it("payTo may not be the principal, zero, the registry, the executor or the token", async () => {
    let i = 0n;
    for (const bad of [principalAcct.address, zeroAddress, d.registry, d.executor, d.token]) {
      const req = requirements(bad, 500_000n);
      expect(await verify(await pay(req, i++), req, ctx)).toMatchObject({
        isValid: false,
        invalidReason: "invalid_spend_grant_wrong_recipient",
      });
    }
  });

  it("an amount over the per-call cap is over_tx_cap", async () => {
    const req = requirements(serverA, 1_000_001n);
    expect((await verify(await pay(req, 1n), req, ctx)).invalidReason).toBe("invalid_spend_grant_over_tx_cap");
  });
});

describe("signing matches the contract", () => {
  it("typed data hash equals authorizationDigest and the domain hash equals domainSeparator", async () => {
    const req = requirements(serverA, 500_000n);
    const p = await pay(req, 7n);
    const domain = spendAuthorizationDomain(CHAIN_ID, d.executor);
    const message = {
      grantId,
      asset: d.token,
      amount: 500_000n,
      recipient: serverA,
      nonce: 7n,
      deadline: BigInt(p.payload.deadline),
    };
    const digest = hashTypedData({ domain, types: spendAuthorizationTypes, primaryType: "SpendAuthorization", message });
    expect(digest).toBe(
      await c.publicClient.readContract({
        address: d.executor,
        abi: spendGrantExecutorAbi,
        functionName: "authorizationDigest",
        args: [grantId, d.token, 500_000n, serverA, 7n, message.deadline],
      }),
    );
    expect(
      hashDomain({
        domain: { ...domain, chainId: BigInt(domain.chainId) },
        types: {
          EIP712Domain: [
            { name: "name", type: "string" },
            { name: "version", type: "string" },
            { name: "chainId", type: "uint256" },
            { name: "verifyingContract", type: "address" },
          ],
        },
      }),
    ).toBe(
      await c.publicClient.readContract({
        address: d.executor,
        abi: spendGrantExecutorAbi,
        functionName: "domainSeparator",
      }),
    );
  });

  it("the type string matches the executor's AUTHORIZATION_TYPEHASH", () => {
    const fields = spendAuthorizationTypes.SpendAuthorization.map((f) => `${f.type} ${f.name}`).join(",");
    expect(`SpendAuthorization(${fields})`).toBe(
      "SpendAuthorization(bytes32 grantId,address asset,uint256 amount,address recipient,uint256 nonce,uint256 deadline)",
    );
  });
});

describe("pre-checks", () => {
  const code = async (p: PaymentPayload, r: PaymentRequirements) => (await verify(p, r, ctx)).invalidReason;
  let req: PaymentRequirements;
  let p: PaymentPayload;
  beforeEach(async () => {
    req = requirements(serverA, 500_000n);
    p = await pay(req, 1n);
  });

  it("rejects the wrong x402 version", async () => {
    expect(await code({ ...p, x402Version: 1 as unknown as 2 }, req)).toBe("invalid_x402_version");
  });
  it("rejects another scheme", async () => {
    expect(await code(p, { ...req, scheme: "exact" })).toBe("unsupported_scheme");
    expect(await code({ ...p, accepted: { ...p.accepted, scheme: "exact" } }, req)).toBe("unsupported_scheme");
  });
  it("rejects another network", async () => {
    expect(await code(p, { ...req, network: "eip155:1" })).toBe("invalid_network");
  });
  it("rejects another executor, accepting any address case", async () => {
    expect(await code(p, { ...req, extra: { executor: serverA } })).toBe("invalid_payment_requirements");
    expect(await code(p, { ...req, extra: {} })).toBe("invalid_payment_requirements");
    const { extra: _extra, ...bare } = req;
    expect(await code(p, bare)).toBe("invalid_payment_requirements");
    expect(
      (await verify(p, { ...req, extra: { executor: getAddress(d.executor).toLowerCase() } }, ctx)).isValid,
    ).toBe(true);
    const checksummed: string = getAddress(d.executor);
    const swapped = checksummed.replace(/[a-fA-F]/g, (ch) => (ch === ch.toLowerCase() ? ch.toUpperCase() : ch.toLowerCase()));
    expect(swapped).not.toBe(checksummed.toLowerCase());
    expect(await code(p, { ...req, extra: { executor: swapped } })).toBe("invalid_payment_requirements");
  });
  it("rejects a malformed payload", async () => {
    const bad = (patch: Partial<PaymentPayload["payload"]>) => ({ ...p, payload: { ...p.payload, ...patch } });
    expect(await code(bad({ grantId: "0x1234" }), req)).toBe("invalid_payload");
    expect(await code(bad({ nonce: "0x1" }), req)).toBe("invalid_payload");
    expect(await code(bad({ nonce: "-1" }), req)).toBe("invalid_payload");
    expect(await code(bad({ deadline: "1.5" }), req)).toBe("invalid_payload");
    expect(await code(bad({ authorization: "nothex" as Hex }), req)).toBe("invalid_payload");
    expect(await code(p, { ...req, amount: "1e6" })).toBe("invalid_payload");
    expect(await code(p, { ...req, payTo: "0x1234" })).toBe("invalid_payload");
    expect(await code(p, { ...req, asset: "token" })).toBe("invalid_payload");
    expect(await code(bad({ nonce: "01" }), req)).toBe("invalid_payload");
    expect(await code(bad({ nonce: (2n ** 256n).toString() }), req)).toBe("invalid_payload");
    expect(await code(bad({ nonce: 1 as unknown as string }), req)).toBe("invalid_payload");
    expect(await code(bad({ authorization: "0x123" }), req)).toBe("invalid_payload");
  });
  it("rejects the native asset as invalid_payment_requirements, from verify and settle", async () => {
    for (const asset of [NATIVE, NATIVE.toLowerCase()]) {
      const nativeReq = requirements(serverA, 500_000n, asset as Address);
      const nativePayment = await pay(nativeReq, 1n);
      expect(await code(nativePayment, nativeReq)).toBe("invalid_payment_requirements");
      expect(await settle(nativePayment, nativeReq, ctx)).toMatchObject({
        success: false,
        errorReason: "invalid_payment_requirements",
        transaction: "",
      });
    }
  });
  it("reports a malformed authorization as invalid_spend_grant_signature", async () => {
    for (const authorization of [`0x${"00".repeat(64)}`, `0x${"00".repeat(65)}`] as Hex[]) {
      const bad = { ...p, payload: { ...p.payload, authorization } };
      expect(await code(bad, req)).toBe("invalid_spend_grant_signature");
    }
  });
  it("rejects a payTo with a wrong checksum, accepts it in lower case", async () => {
    const checksummed: string = getAddress(serverA);
    const swapped = checksummed.replace(/[a-fA-F]/g, (ch) => (ch === ch.toLowerCase() ? ch.toUpperCase() : ch.toLowerCase()));
    expect(swapped).not.toBe(checksummed.toLowerCase());
    expect(await code(p, { ...req, payTo: swapped })).toBe("invalid_payload");
    expect((await verify(p, { ...req, payTo: checksummed.toLowerCase() }, ctx)).isValid).toBe(true);
  });
  it("rejects a maxTimeoutSeconds that is not a positive integer", async () => {
    expect(await code(p, { ...req, maxTimeoutSeconds: 0 })).toBe("invalid_payment_requirements");
    expect(await code(p, { ...req, maxTimeoutSeconds: -1 })).toBe("invalid_payment_requirements");
    expect(await code(p, { ...req, maxTimeoutSeconds: 1.5 })).toBe("invalid_payment_requirements");
  });
  it("reports pre-check failures from settle with an empty transaction", async () => {
    expect(await settle(p, { ...req, network: "eip155:1" }, ctx)).toEqual({
      success: false,
      errorReason: "invalid_network",
      transaction: "",
      network: "eip155:1",
    });
  });
  it("omits payer when the grant is unknown", async () => {
    const unknown = { ...p, payload: { ...p.payload, grantId: `0x${"11".repeat(32)}` as Hex } };
    const res = await verify(unknown, req, ctx);
    expect(res.isValid).toBe(false);
    expect(res.invalidReason).toBe("invalid_spend_grant_nonexistent");
    expect(res).not.toHaveProperty("payer");
  });
});

describe("supported", () => {
  it("lists the scheme on the client's chain and the facilitator signer", async () => {
    expect(await supported(ctx)).toEqual({
      kinds: [{ x402Version: 2, scheme: "spend-grant", network: `eip155:${CHAIN_ID}` }],
      extensions: [],
      signers: { "eip155:*": [facilitatorAcct.address] },
    });
  });
});

describe("createSpendGrantPayment", () => {
  it("rejects other schemes and networks", async () => {
    const req = requirements(serverA, 1n);
    const args = { grantId, nonce: 1n, account: agentAcct };
    await expect(createSpendGrantPayment({ ...args, requirements: { ...req, scheme: "exact" } })).rejects.toThrow();
    await expect(createSpendGrantPayment({ ...args, requirements: { ...req, network: "solana:1" } })).rejects.toThrow();
    await expect(createSpendGrantPayment({ ...args, requirements: { ...req, extra: {} } })).rejects.toThrow();
  });

  it("draws a random 256-bit nonce when none is given", async () => {
    const req = requirements(serverA, 1n);
    const args = { requirements: req, grantId, account: agentAcct, now: await now() };
    const nonces = new Set<string>();
    for (let i = 0; i < 4; i++) {
      const p = await createSpendGrantPayment(args);
      nonces.add(p.payload.nonce);
      expect((await verify(p, req, ctx)).isValid).toBe(true);
    }
    expect(nonces.size).toBe(4);
    for (const n of nonces) expect(BigInt(n)).toBeGreaterThan(2n ** 128n);
  });

  it("rejects input the facilitator would refuse", async () => {
    const req = requirements(serverA, 1n);
    const args = { grantId, nonce: 1n, account: agentAcct };
    const rejects = (patch: Partial<PaymentRequirements>, over: Partial<typeof args> = {}) =>
      expect(createSpendGrantPayment({ ...args, ...over, requirements: { ...req, ...patch } })).rejects.toThrow();
    for (const amount of ["", "0x10", " 5 ", "05", "-1", (2n ** 256n).toString()]) await rejects({ amount });
    for (const maxTimeoutSeconds of [0, -1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER + 1]) {
      await rejects({ maxTimeoutSeconds });
    }
    const checksummed: string = getAddress(serverA);
    const swapped = checksummed.replace(/[a-fA-F]/g, (ch) => (ch === ch.toLowerCase() ? ch.toUpperCase() : ch.toLowerCase()));
    await rejects({ payTo: swapped });
    await rejects({}, { nonce: -1n });
    await rejects({}, { nonce: 2n ** 256n });
    await rejects({}, { grantId: "0x1234" });
  });
});
