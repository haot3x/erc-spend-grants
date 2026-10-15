import { BaseError, ContractFunctionRevertedError, decodeErrorResult, isHex, type Hex } from "viem";
import { spendGrantExecutorAbi, spendGrantRegistryAbi } from "./abi.js";

/** Both ABIs together, so any revert of a spend decodes. */
export const revertAbi = [...spendGrantExecutorAbi, ...spendGrantRegistryAbi.filter((e) => e.name !== "SpendGrantError")] as const;

/** `Reason` in enum order. */
const REASON_NAMES = [
  "ok",
  "invalid_grant",
  "bad_signature",
  "not_yet_valid",
  "expired",
  "revoked",
  "wrong_asset",
  "wrong_recipient",
  "over_tx_cap",
  "over_window_cap",
  "over_cumulative_cap",
  "window_full",
  "unauthorized_executor",
  "unauthorized_delegate",
  "nonexistent",
] as const;

interface Decoded {
  errorName: string;
  args: readonly unknown[] | undefined;
}

function codeFor({ errorName, args }: Decoded): string | undefined {
  switch (errorName) {
    case "SpendGrantError": {
      const reason = args?.[0];
      const name = typeof reason === "number" || typeof reason === "bigint" ? REASON_NAMES[Number(reason)] : undefined;
      return name === undefined ? undefined : `invalid_spend_grant_${name}`;
    }
    case "NonceAlreadyUsed":
      return "invalid_spend_grant_nonce_used";
    case "AuthorizationExpired":
      return "invalid_spend_grant_authorization_expired";
    case "BadAuthorization":
      return "invalid_spend_grant_signature";
    case "NativeRequiresAccountAdapter":
      // The facilitator refuses the native asset before it simulates, so this is only a fallback.
      return "invalid_payment_requirements";
    default:
      // TransferFailed has no code of its own: the facilitator reads the grant's balance and allowance to tell a
      // shortfall (`insufficient_funds`) from any other token failure.
      return undefined;
  }
}

/** Revert to the x402 errorCode in the mapping's table; undefined when the error is not a known revert. */
export function errorCodeFromRevert(error: unknown): string | undefined {
  const decoded = decodeRevert(error);
  return decoded === undefined ? undefined : codeFor(decoded);
}

/** Whether the error is the executor's `TransferFailed()` revert. */
export function isTransferFailed(error: unknown): boolean {
  return decodeRevert(error)?.errorName === "TransferFailed";
}

function decodeRevert(error: unknown): Decoded | undefined {
  if (!(error instanceof BaseError)) return undefined;

  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
  if (reverted instanceof ContractFunctionRevertedError) {
    if (reverted.data !== undefined) return reverted.data;
    if (reverted.raw !== undefined) {
      const decoded = fromRaw(reverted.raw);
      if (decoded !== undefined) return decoded;
    }
  }

  // The client could not decode it as a contract revert: look for raw revert data anywhere in the chain.
  const withData = error.walk((e) => isHex((e as { data?: unknown }).data));
  const data = (withData as { data?: unknown } | null)?.data;
  return isHex(data) ? fromRaw(data) : undefined;
}

function fromRaw(data: Hex): Decoded | undefined {
  try {
    const { errorName, args } = decodeErrorResult({ abi: revertAbi, data });
    return { errorName, args };
  } catch {
    return undefined;
  }
}
