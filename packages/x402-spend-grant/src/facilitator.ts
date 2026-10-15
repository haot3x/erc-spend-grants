import { encodeFunctionData, isHex, keccak256, zeroAddress, type Address, type Hex, type TransactionReceipt } from "viem";
import { spendGrantExecutorAbi, spendGrantRegistryAbi } from "./abi.js";
import { errorCodeFromRevert, isTransferFailed, revertAbi } from "./errors.js";
import {
  BYTES32,
  MIN_DEADLINE_SLACK_SECONDS,
  NATIVE_ASSET,
  isTimeout,
  isValidAddress,
  parseUint,
} from "./validate.js";
import {
  SPEND_GRANT_SCHEME,
  type FacilitatorContext,
  type PaymentPayload,
  type PaymentRequirements,
  type SettlementResponse,
  type SupportedResponse,
  type VerifyResponse,
} from "./types.js";


interface SpendArgs {
  grantId: Hex;
  asset: Address;
  amount: bigint;
  recipient: Address;
  nonce: bigint;
  deadline: bigint;
  authorization: Hex;
}

/** The x402 section 9 checks that need no chain call beyond the chain id and the latest block; returns a code or the call arguments. */
async function precheck(
  paymentPayload: PaymentPayload,
  requirements: PaymentRequirements,
  ctx: FacilitatorContext,
): Promise<{ code: string } | { args: SpendArgs }> {
  if (paymentPayload?.x402Version !== 2) return { code: "invalid_x402_version" };
  if (requirements?.scheme !== SPEND_GRANT_SCHEME || paymentPayload.accepted?.scheme !== SPEND_GRANT_SCHEME) {
    return { code: "unsupported_scheme" };
  }
  const chainId = await ctx.publicClient.getChainId();
  if (requirements.network !== `eip155:${chainId}`) return { code: "invalid_network" };
  const executor = requirements.extra?.["executor"];
  if (!isValidAddress(executor) || executor.toLowerCase() !== ctx.executor.toLowerCase()) {
    return { code: "invalid_payment_requirements" };
  }

  if (!isTimeout(requirements.maxTimeoutSeconds)) return { code: "invalid_payment_requirements" };

  const p = (paymentPayload.payload ?? {}) as unknown as Record<string, unknown>;
  const amount = parseUint(requirements.amount);
  const nonce = parseUint(p["nonce"]);
  const deadline = parseUint(p["deadline"]);
  const { grantId, authorization } = p;
  const { asset, payTo } = requirements;
  if (
    amount === undefined ||
    nonce === undefined ||
    deadline === undefined ||
    typeof grantId !== "string" ||
    !BYTES32.test(grantId) ||
    typeof authorization !== "string" ||
    !isHex(authorization) ||
    authorization.length % 2 !== 0 ||
    !isValidAddress(asset) ||
    !isValidAddress(payTo)
  ) {
    return { code: "invalid_payload" };
  }
  // The reference executors do not move native currency.
  if (asset.toLowerCase() === NATIVE_ASSET) return { code: "invalid_payment_requirements" };

  // The agent picks the deadline, so the facilitator bounds it: a far-future deadline makes the payload a
  // long-lived bearer authorization, and one about to expire would be mined after it and revert at the
  // facilitator's cost.
  const { timestamp } = await ctx.publicClient.getBlock();
  if (deadline > timestamp + BigInt(requirements.maxTimeoutSeconds) || deadline <= timestamp + MIN_DEADLINE_SLACK_SECONDS) {
    return { code: "invalid_payload" };
  }
  // asset, amount and payTo come from the requirements the resource server stated, not from `accepted`: the
  // signature binds them, so a tampered value fails on chain.
  return {
    args: { grantId: grantId as Hex, asset, amount, recipient: payTo, nonce, deadline, authorization },
  };
}

/** The grant's principal and delegate, or undefined when the registry does not know the id. */
async function partiesOf(
  ctx: FacilitatorContext,
  grantId: Hex,
): Promise<{ principal: Address; delegate: Address } | undefined> {
  try {
    const [principal, delegate] = await ctx.publicClient.readContract({
      address: ctx.registry,
      abi: spendGrantRegistryAbi,
      functionName: "parties",
      args: [grantId],
    });
    return principal === zeroAddress ? undefined : { principal, delegate };
  } catch {
    return undefined;
  }
}

function simulate(ctx: FacilitatorContext, a: SpendArgs, blockNumber?: bigint) {
  return ctx.publicClient.simulateContract({
    address: ctx.executor,
    abi: revertAbi,
    functionName: "spendWithAuthorization",
    args: [a.grantId, a.asset, a.amount, a.recipient, a.nonce, a.deadline, a.authorization],
    account: ctx.walletClient.account,
    ...(blockNumber !== undefined ? { blockNumber } : {}),
  });
}

/**
 * The errorCode of a failed simulation. `TransferFailed` is `insufficient_funds` only when the grant's state, read
 * at the same block, shows the principal's balance or allowance below the amount; any other token failure (a
 * blocklist, a pause) is `fallback`.
 */
async function failureCode(
  ctx: FacilitatorContext,
  a: SpendArgs,
  error: unknown,
  fallback: string,
  blockNumber?: bigint,
): Promise<string> {
  const code = errorCodeFromRevert(error);
  if (code !== undefined) return code;
  if (!isTransferFailed(error)) return fallback;
  try {
    const s = await ctx.publicClient.readContract({
      address: ctx.registry,
      abi: spendGrantRegistryAbi,
      functionName: "grantState",
      args: [a.grantId, a.asset],
      ...(blockNumber !== undefined ? { blockNumber } : {}),
    });
    if ((s.balanceKnown && s.balance < a.amount) || (s.allowanceKnown && s.allowance < a.amount)) {
      return "insufficient_funds";
    }
  } catch {
    // The state is unreadable, so the shortfall is not shown.
  }
  return fallback;
}

/** `/verify`: simulate the settlement call from the facilitator's account. */
export async function verify(
  paymentPayload: PaymentPayload,
  requirements: PaymentRequirements,
  ctx: FacilitatorContext,
): Promise<VerifyResponse> {
  try {
    const pre = await precheck(paymentPayload, requirements, ctx);
    if ("code" in pre) return { isValid: false, invalidReason: pre.code };
    const parties = await partiesOf(ctx, pre.args.grantId);
    const who = parties !== undefined ? { payer: parties.principal } : {};
    try {
      await simulate(ctx, pre.args);
      return { isValid: true, ...who };
    } catch (e) {
      return { isValid: false, invalidReason: await failureCode(ctx, pre.args, e, "unexpected_verify_error"), ...who };
    }
  } catch {
    return { isValid: false, invalidReason: "unexpected_verify_error" };
  }
}

/** `/settle`: simulate, then submit `spendWithAuthorization` and wait for the receipt. */
export async function settle(
  paymentPayload: PaymentPayload,
  requirements: PaymentRequirements,
  ctx: FacilitatorContext,
): Promise<SettlementResponse> {
  const network = requirements?.network ?? "";
  try {
    const pre = await precheck(paymentPayload, requirements, ctx);
    if ("code" in pre) return { success: false, errorReason: pre.code, transaction: "", network };
    const parties = await partiesOf(ctx, pre.args.grantId);
    const who = parties !== undefined ? { payer: parties.principal } : {};
    const fail = (errorReason: string): SettlementResponse => ({
      success: false,
      errorReason,
      ...who,
      transaction: "",
      network,
    });
    const { account } = ctx.walletClient;
    // The transaction is signed before it is sent, so its hash exists before the network call: a send that fails
    // after the node accepted the transaction still names it.
    let serialized: Hex;
    let txNonce: number;
    try {
      await simulate(ctx, pre.args);
      const a = pre.args;
      const prepared = (await ctx.walletClient.prepareTransactionRequest({
        account,
        chain: ctx.walletClient.chain,
        to: ctx.executor,
        data: encodeFunctionData({
          abi: spendGrantExecutorAbi,
          functionName: "spendWithAuthorization",
          args: [a.grantId, a.asset, a.amount, a.recipient, a.nonce, a.deadline, a.authorization],
        }),
      } as never)) as unknown as { nonce: number };
      serialized = await account.signTransaction(prepared as never);
      txNonce = prepared.nonce;
    } catch (e) {
      return fail(await failureCode(ctx, pre.args, e, "unexpected_settle_error"));
    }
    const hash = keccak256(serialized);
    // From the send on, a failure still names the hash, so the server can reconcile.
    const unresolved: SettlementResponse = {
      success: false,
      errorReason: "invalid_transaction_state",
      ...who,
      transaction: hash,
      network,
    };
    try {
      await ctx.publicClient.sendRawTransaction({ serializedTransaction: serialized });
    } catch (e) {
      const code = errorCodeFromRevert(e);
      return code !== undefined ? fail(code) : unresolved;
    }

    /** The outcome of a mined receipt for this payment. */
    const fromReceipt = async (receipt: TransactionReceipt): Promise<SettlementResponse> => {
      if (receipt.status === "success") {
        return { success: true, ...who, transaction: receipt.transactionHash, network };
      }
      try {
        await simulate(ctx, pre.args, receipt.blockNumber);
        return fail("invalid_transaction_state");
      } catch (e) {
        return fail(await failureCode(ctx, pre.args, e, "unexpected_settle_error", receipt.blockNumber));
      }
    };

    let receipt: TransactionReceipt;
    let replacement: string | undefined;
    try {
      // viem follows a same-nonce replacement and resolves with the replacing transaction's receipt.
      receipt = await ctx.publicClient.waitForTransactionReceipt({
        hash,
        onReplaced: (r) => (replacement = r.reason),
        ...(ctx.receiptTimeoutMs !== undefined ? { timeout: ctx.receiptTimeoutMs } : {}),
      });
    } catch {
      // The wait failed (timeout, RPC error): read the chain for the outcome before giving up on it.
      try {
        const mined = await ctx.publicClient.getTransactionReceipt({ hash }).catch(() => undefined);
        if (mined !== undefined) return await fromReceipt(mined);
        if (parties !== undefined) {
          const [count, used] = await Promise.all([
            ctx.publicClient.getTransactionCount({ address: account.address }),
            ctx.publicClient.readContract({
              address: ctx.executor,
              abi: spendGrantExecutorAbi,
              functionName: "nonceUsed",
              args: [parties.delegate, pre.args.nonce],
            }),
          ]);
          // The facilitator's nonce was taken by another transaction and the payment is not made: ours is dead.
          // If the payment is made, another transaction paid it and which one is not known here.
          if (count > txNonce && !used) return fail("invalid_transaction_state");
        }
      } catch {
        // Unreadable: the outcome stays unknown.
      }
      return unresolved;
    }
    // A replacement with the same target, value and input (viem's "repriced") carries the same call, so it is the
    // settlement; any other transaction at that nonce means the one we sent was never mined.
    if (receipt.transactionHash !== hash && replacement !== "repriced") return fail("invalid_transaction_state");
    return await fromReceipt(receipt);
  } catch {
    return { success: false, errorReason: "unexpected_settle_error", transaction: "", network };
  }
}

/** `/supported`: the one kind this facilitator settles, on the chain of its client. */
export async function supported(ctx: FacilitatorContext): Promise<SupportedResponse> {
  const chainId = await ctx.publicClient.getChainId();
  return {
    kinds: [{ x402Version: 2, scheme: SPEND_GRANT_SCHEME, network: `eip155:${chainId}` }],
    extensions: [],
    signers: { "eip155:*": [ctx.walletClient.account.address] },
  };
}
