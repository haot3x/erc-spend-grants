import { isHex, zeroAddress, type Address, type Hex } from "viem";
import { spendGrantRegistryAbi } from "./abi.js";
import { errorCodeFromRevert, revertAbi } from "./errors.js";
import { BYTES32, isTimeout, isValidAddress, parseUint } from "./validate.js";
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

/** The x402 section 9 checks that need no chain call beyond the chain id; returns a code or the call arguments. */
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
  // asset, amount and payTo come from the requirements the resource server stated, not from `accepted`: the
  // signature binds them, so a tampered value fails on chain.
  return {
    args: { grantId: grantId as Hex, asset, amount, recipient: payTo, nonce, deadline, authorization },
  };
}

/** The grant's principal, or undefined when the registry does not know the id. */
async function principalOf(ctx: FacilitatorContext, grantId: Hex): Promise<string | undefined> {
  try {
    const [principal] = await ctx.publicClient.readContract({
      address: ctx.registry,
      abi: spendGrantRegistryAbi,
      functionName: "parties",
      args: [grantId],
    });
    return principal === zeroAddress ? undefined : principal;
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

/** `/verify`: simulate the settlement call from the facilitator's account. */
export async function verify(
  paymentPayload: PaymentPayload,
  requirements: PaymentRequirements,
  ctx: FacilitatorContext,
): Promise<VerifyResponse> {
  try {
    const pre = await precheck(paymentPayload, requirements, ctx);
    if ("code" in pre) return { isValid: false, invalidReason: pre.code };
    const payer = await principalOf(ctx, pre.args.grantId);
    const who = payer !== undefined ? { payer } : {};
    try {
      await simulate(ctx, pre.args);
      return { isValid: true, ...who };
    } catch (e) {
      return { isValid: false, invalidReason: errorCodeFromRevert(e) ?? "unexpected_verify_error", ...who };
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
    const payer = await principalOf(ctx, pre.args.grantId);
    const who = payer !== undefined ? { payer } : {};
    const fail = (errorReason: string): SettlementResponse => ({
      success: false,
      errorReason,
      ...who,
      transaction: "",
      network,
    });
    let hash: Hex;
    try {
      const { request } = await simulate(ctx, pre.args);
      hash = await ctx.walletClient.writeContract(request as never);
    } catch (e) {
      return fail(errorCodeFromRevert(e) ?? "unexpected_settle_error");
    }
    // The transaction is broadcast: from here on a failure still names the hash, so the server can reconcile.
    try {
      // viem follows a same-nonce replacement and resolves with the replacing transaction's receipt.
      let replacement: string | undefined;
      const receipt = await ctx.publicClient.waitForTransactionReceipt({
        hash,
        onReplaced: (r) => (replacement = r.reason),
        ...(ctx.receiptTimeoutMs !== undefined ? { timeout: ctx.receiptTimeoutMs } : {}),
      });
      // A repriced replacement carries the same call, so it is the settlement; any other transaction at that nonce
      // means the one we sent was never mined.
      if (receipt.transactionHash !== hash && replacement !== "repriced") return fail("invalid_transaction_state");
      if (receipt.status === "success") {
        return { success: true, ...who, transaction: receipt.transactionHash, network };
      }
      try {
        await simulate(ctx, pre.args, receipt.blockNumber);
        return fail("invalid_transaction_state");
      } catch (e) {
        return fail(errorCodeFromRevert(e) ?? "unexpected_settle_error");
      }
    } catch {
      return { success: false, errorReason: "invalid_transaction_state", ...who, transaction: hash, network };
    }
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
