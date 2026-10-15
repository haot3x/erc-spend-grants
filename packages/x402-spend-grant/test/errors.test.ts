import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { BaseError, ContractFunctionRevertedError, encodeErrorResult } from "viem";
import { errorCodeFromRevert, spendGrantExecutorAbi } from "../src/index.js";

/** The `Reason` enum in src/SpendGrantTypes.sol, as lower snake case names in declaration order. */
function reasonNames(): string[] {
  const source = readFileSync(fileURLToPath(new URL("../../../src/SpendGrantTypes.sol", import.meta.url)), "utf8");
  const body = /enum\s+Reason\s*\{([^}]*)\}/.exec(source)?.[1];
  if (body === undefined) throw new Error("enum Reason not found in SpendGrantTypes.sol");
  return body
    .replace(/\/\/.*$/gm, "")
    .split(",")
    .map((n) => n.trim())
    .filter((n) => n !== "")
    .map((n) => n.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase());
}

const NAMES = reasonNames();

type PlainError =
  | "NonceAlreadyUsed"
  | "AuthorizationExpired"
  | "BadAuthorization"
  | "TransferFailed"
  | "NativeRequiresAccountAdapter";

/** A viem error whose cause carries only raw revert data, as when the client could not decode it. */
function rawRevert(data: `0x${string}`) {
  return new BaseError("reverted", { cause: Object.assign(new Error("rpc"), { data }) });
}

describe("errorCodeFromRevert", () => {
  it("maps every SpendGrantError reason, from raw data", () => {
    NAMES.forEach((name, i) => {
      const data = encodeErrorResult({ abi: spendGrantExecutorAbi, errorName: "SpendGrantError", args: [i] });
      expect(errorCodeFromRevert(rawRevert(data))).toBe(`invalid_spend_grant_${name}`);
    });
    expect(NAMES.length).toBeGreaterThan(1);
    // A reason past the end of the enum has no name: the package list must not be longer than the contract's.
    const past = encodeErrorResult({ abi: spendGrantExecutorAbi, errorName: "SpendGrantError", args: [NAMES.length] });
    expect(errorCodeFromRevert(rawRevert(past))).toBeUndefined();
  });

  it("maps the executor errors", () => {
    const code = (errorName: PlainError) =>
      errorCodeFromRevert(rawRevert(encodeErrorResult({ abi: spendGrantExecutorAbi, errorName })));
    expect(code("NonceAlreadyUsed")).toBe("invalid_spend_grant_nonce_used");
    expect(code("AuthorizationExpired")).toBe("invalid_spend_grant_authorization_expired");
    expect(code("BadAuthorization")).toBe("invalid_spend_grant_signature");
    expect(code("TransferFailed")).toBe("insufficient_funds");
    expect(code("NativeRequiresAccountAdapter")).toBe("invalid_payload");
  });

  it("maps a decoded ContractFunctionRevertedError", () => {
    const err = new ContractFunctionRevertedError({
      abi: spendGrantExecutorAbi,
      data: encodeErrorResult({ abi: spendGrantExecutorAbi, errorName: "NonceAlreadyUsed" }),
      functionName: "spendWithAuthorization",
    });
    expect(errorCodeFromRevert(new BaseError("wrapped", { cause: err }))).toBe("invalid_spend_grant_nonce_used");
  });

  it("returns undefined for anything else", () => {
    expect(errorCodeFromRevert(new Error("boom"))).toBeUndefined();
    expect(errorCodeFromRevert(undefined)).toBeUndefined();
    expect(errorCodeFromRevert(rawRevert("0xdeadbeef"))).toBeUndefined();
    expect(errorCodeFromRevert(new BaseError("plain"))).toBeUndefined();
  });
});
