import { isAddress, type Address } from "viem";

export const UINT256_MAX = (1n << 256n) - 1n;
export const BYTES32 = /^0x[0-9a-fA-F]{64}$/;
const DECIMAL = /^(0|[1-9][0-9]*)$/;

/** A canonical decimal string (no sign, no leading zeros, no whitespace) that fits in a uint256. */
export function parseUint(value: unknown): bigint | undefined {
  if (typeof value !== "string" || !DECIMAL.test(value)) return undefined;
  const n = BigInt(value);
  return n <= UINT256_MAX ? n : undefined;
}

/** A bigint that fits in a uint256. */
export function isUint256(value: unknown): value is bigint {
  return typeof value === "bigint" && value >= 0n && value <= UINT256_MAX;
}

/** A non-negative safe integer number of seconds. */
export function isTimeout(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

/** An address that is all lower case or carries a correct EIP-55 checksum. */
export function isValidAddress(value: unknown): value is Address {
  return typeof value === "string" && isAddress(value);
}
