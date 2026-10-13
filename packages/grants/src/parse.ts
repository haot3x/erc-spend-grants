import type { Address } from "viem";

import {
  ASSET_COMBINE_AND,
  MAX_ASSETS,
  RECIPIENT_MODE_ANY,
  RECIPIENT_MODE_LOCKED,
  UINT256_MAX,
  UINT64_MAX,
  ZERO_ADDRESS,
  type AssetCombine,
  type AssetLimit,
  type SpendGrant,
  type SpendGrantInterchange,
  type SpendGrantJson,
  type RecipientMode,
} from "./types.js";

const ADDRESS = /^0x[0-9a-f]{40}$/;
const UINT = /^(0|[1-9][0-9]*)$/;

const ROOT_KEYS = ["chainId", "registry", "grant"] as const;
const GRANT_KEYS = [
  "principal",
  "delegate",
  "recipientMode",
  "recipient",
  "assetCombine",
  "windowSeconds",
  "assets",
  "validAfter",
  "validUntil",
  "salt",
] as const;
const ASSET_KEYS = ["asset", "maxPerCall", "maxPerWindow", "maxTotal"] as const;

export class SpendGrantError extends Error {
  constructor(
    message: string,
    readonly path?: string,
  ) {
    super(path ? `${path}: ${message}` : message);
    this.name = "SpendGrantError";
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function requireExactKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
  path: string,
): void {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new SpendGrantError(
      `expected exactly ${expected.join(", ")}; received ${actual.join(", ")}`,
      path,
    );
  }
}

export function parseAddress(
  value: unknown,
  path: string,
  allowZero = false,
): Address {
  if (typeof value !== "string" || !ADDRESS.test(value)) {
    throw new SpendGrantError("must be a lowercase 20-byte 0x address", path);
  }
  if (!allowZero && value === ZERO_ADDRESS) {
    throw new SpendGrantError("must be nonzero", path);
  }
  return value as Address;
}

export function parseUint(
  value: unknown,
  bits: 8 | 64 | 256,
  path: string,
): bigint {
  if (typeof value !== "string" || !UINT.test(value)) {
    throw new SpendGrantError(
      "must be a canonical unsigned decimal string",
      path,
    );
  }
  const parsed = BigInt(value);
  const max = bits === 8 ? 255n : bits === 64 ? UINT64_MAX : UINT256_MAX;
  if (parsed > max) {
    throw new SpendGrantError(`exceeds uint${bits}`, path);
  }
  return parsed;
}

function parseRecipientMode(value: unknown, path: string): RecipientMode {
  const parsed = parseUint(value, 8, path);
  if (parsed === BigInt(RECIPIENT_MODE_LOCKED)) return RECIPIENT_MODE_LOCKED;
  if (parsed === BigInt(RECIPIENT_MODE_ANY)) return RECIPIENT_MODE_ANY;
  throw new SpendGrantError("must be 0 or 1", path);
}

function parseAssetCombine(value: unknown, path: string): AssetCombine {
  const parsed = parseUint(value, 8, path);
  if (parsed === BigInt(ASSET_COMBINE_AND)) return ASSET_COMBINE_AND;
  throw new SpendGrantError("must be 0", path);
}

export function toSpendGrantJson(value: SpendGrantInterchange): SpendGrantJson {
  return {
    chainId: value.chainId.toString(),
    registry: value.registry,
    grant: {
      principal: value.grant.principal,
      delegate: value.grant.delegate,
      recipientMode: value.grant.recipientMode.toString(),
      recipient: value.grant.recipient,
      assetCombine: value.grant.assetCombine.toString(),
      windowSeconds: value.grant.windowSeconds.toString(),
      assets: value.grant.assets.map((asset) => ({
        asset: asset.asset,
        maxPerCall: asset.maxPerCall.toString(),
        maxPerWindow: asset.maxPerWindow.toString(),
        maxTotal: asset.maxTotal.toString(),
      })),
      validAfter: value.grant.validAfter.toString(),
      validUntil: value.grant.validUntil.toString(),
      salt: value.grant.salt.toString(),
    },
  };
}

export function stringifySpendGrant(value: SpendGrantInterchange): string {
  validateSpendGrant(value);
  return `${JSON.stringify(toSpendGrantJson(value), null, 2)}\n`;
}

export function validateSpendGrant(value: SpendGrantInterchange): void {
  requireExactKeys(value as unknown as Record<string, unknown>, ROOT_KEYS, "$");
  requireExactKeys(
    value.grant as unknown as Record<string, unknown>,
    GRANT_KEYS,
    "grant",
  );
  if (value.chainId < 0n || value.chainId > UINT256_MAX) {
    throw new SpendGrantError("must fit uint256", "chainId");
  }
  parseAddress(value.registry, "registry");
  const m = value.grant;
  parseAddress(m.principal, "grant.principal");
  parseAddress(m.delegate, "grant.delegate");
  if (m.delegate === m.principal) {
    throw new SpendGrantError("must differ from principal", "grant.delegate");
  }
  if (
    m.recipientMode !== RECIPIENT_MODE_LOCKED &&
    m.recipientMode !== RECIPIENT_MODE_ANY
  ) {
    throw new SpendGrantError("must be 0 or 1", "grant.recipientMode");
  }
  parseAddress(m.recipient, "grant.recipient", true);
  if (m.recipientMode === RECIPIENT_MODE_LOCKED) {
    if (m.recipient === ZERO_ADDRESS) {
      throw new SpendGrantError("must be nonzero", "grant.recipient");
    }
    if (m.recipient === m.principal) {
      throw new SpendGrantError("must differ from principal", "grant.recipient");
    }
  } else if (m.recipient !== ZERO_ADDRESS) {
    throw new SpendGrantError(
      "must be address(0) when recipientMode is 1",
      "grant.recipient",
    );
  }
  if (m.assetCombine !== ASSET_COMBINE_AND) {
    throw new SpendGrantError("must be 0", "grant.assetCombine");
  }
  if (m.windowSeconds <= 0n || m.windowSeconds > UINT64_MAX) {
    throw new SpendGrantError(
      "must be a positive uint64",
      "grant.windowSeconds",
    );
  }
  if (m.validAfter < 0n || m.validAfter > UINT64_MAX) {
    throw new SpendGrantError("must fit uint64", "grant.validAfter");
  }
  if (m.validUntil < 0n || m.validUntil > UINT64_MAX) {
    throw new SpendGrantError("must fit uint64", "grant.validUntil");
  }
  if (m.validAfter >= m.validUntil) {
    throw new SpendGrantError(
      "must be less than validUntil",
      "grant.validAfter",
    );
  }
  if (m.salt < 0n || m.salt > UINT256_MAX) {
    throw new SpendGrantError("must fit uint256", "grant.salt");
  }
  if (m.assets.length < 1 || m.assets.length > MAX_ASSETS) {
    throw new SpendGrantError("must contain 1 to 16 items", "grant.assets");
  }
  let previousAsset = -1n;
  for (const [index, asset] of m.assets.entries()) {
    requireExactKeys(
      asset as unknown as Record<string, unknown>,
      ASSET_KEYS,
      `grant.assets[${index}]`,
    );
    parseAddress(asset.asset, `grant.assets[${index}].asset`);
    const numericAsset = BigInt(asset.asset);
    if (numericAsset <= previousAsset) {
      throw new SpendGrantError(
        "must be unique and strictly ascending by address",
        "grant.assets",
      );
    }
    previousAsset = numericAsset;
    for (const key of ["maxPerCall", "maxPerWindow", "maxTotal"] as const) {
      const amount = asset[key];
      if (amount <= 0n || amount > UINT256_MAX) {
        throw new SpendGrantError(
          "must be a positive uint256",
          `grant.assets[${index}].${key}`,
        );
      }
    }
    if (asset.maxPerCall > asset.maxPerWindow) {
      throw new SpendGrantError(
        "must be <= maxPerWindow",
        `grant.assets[${index}].maxPerCall`,
      );
    }
    if (asset.maxPerWindow > asset.maxTotal) {
      throw new SpendGrantError(
        "must be <= maxTotal",
        `grant.assets[${index}].maxPerWindow`,
      );
    }
  }
}

export function defineSpendGrant(input: {
  chainId: bigint;
  registry: Address;
  grant: SpendGrant;
}): SpendGrantInterchange {
  const result: SpendGrantInterchange = { ...input };
  validateSpendGrant(result);
  return result;
}

function parseAsset(value: unknown, path: string): AssetLimit {
  if (!isRecord(value)) {
    throw new SpendGrantError("must be an object", path);
  }
  requireExactKeys(value, ASSET_KEYS, path);
  return {
    asset: parseAddress(value.asset, `${path}.asset`),
    maxPerCall: parseUint(value.maxPerCall, 256, `${path}.maxPerCall`),
    maxPerWindow: parseUint(value.maxPerWindow, 256, `${path}.maxPerWindow`),
    maxTotal: parseUint(value.maxTotal, 256, `${path}.maxTotal`),
  };
}

export function parseSpendGrant(input: string | unknown): SpendGrantInterchange {
  let value: unknown = input;
  if (typeof input === "string") {
    assertNoDuplicateJsonKeys(input);
    try {
      value = JSON.parse(input) as unknown;
    } catch (error) {
      throw new SpendGrantError(
        `invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
  if (!isRecord(value)) {
    throw new SpendGrantError("must be an object", "$");
  }
  requireExactKeys(value, ROOT_KEYS, "$");
  if (!isRecord(value.grant)) {
    throw new SpendGrantError("must be an object", "grant");
  }
  requireExactKeys(value.grant, GRANT_KEYS, "grant");
  const m = value.grant;
  const assetsValue = m.assets;
  if (!Array.isArray(assetsValue)) {
    throw new SpendGrantError("must be an array", "grant.assets");
  }
  const parsed: SpendGrantInterchange = {
    chainId: parseUint(value.chainId, 256, "chainId"),
    registry: parseAddress(value.registry, "registry"),
    grant: {
      principal: parseAddress(m.principal, "grant.principal"),
      delegate: parseAddress(m.delegate, "grant.delegate"),
      recipientMode: parseRecipientMode(m.recipientMode, "grant.recipientMode"),
      recipient: parseAddress(m.recipient, "grant.recipient", true),
      assetCombine: parseAssetCombine(m.assetCombine, "grant.assetCombine"),
      windowSeconds: parseUint(m.windowSeconds, 64, "grant.windowSeconds"),
      assets: assetsValue.map((asset, index) =>
        parseAsset(asset, `grant.assets[${index}]`),
      ),
      validAfter: parseUint(m.validAfter, 64, "grant.validAfter"),
      validUntil: parseUint(m.validUntil, 64, "grant.validUntil"),
      salt: parseUint(m.salt, 256, "grant.salt"),
    },
  };
  validateSpendGrant(parsed);
  return parsed;
}

export function assertNoDuplicateJsonKeys(source: string): void {
  let index = 0;
  const whitespace = /\s/;
  const skipWhitespace = () => {
    while (index < source.length && whitespace.test(source[index] ?? ""))
      index++;
  };
  const readString = (): string => {
    const start = index;
    if (source[index] !== '"') throw new Error(`expected string at ${index}`);
    index++;
    while (index < source.length) {
      const c = source[index++];
      if (c === "\\") index++;
      else if (c === '"') {
        return JSON.parse(source.slice(start, index)) as string;
      }
    }
    throw new Error("unterminated string");
  };
  const parseValue = (): void => {
    skipWhitespace();
    const c = source[index];
    if (c === "{") {
      index++;
      const keys = new Set<string>();
      skipWhitespace();
      if (source[index] === "}") {
        index++;
        return;
      }
      while (true) {
        skipWhitespace();
        const key = readString();
        if (keys.has(key)) {
          throw new SpendGrantError(`duplicate JSON member ${JSON.stringify(key)}`);
        }
        keys.add(key);
        skipWhitespace();
        if (source[index++] !== ":")
          throw new Error(`expected colon at ${index - 1}`);
        parseValue();
        skipWhitespace();
        const next = source[index++];
        if (next === "}") return;
        if (next !== ",") throw new Error(`expected comma at ${index - 1}`);
      }
    }
    if (c === "[") {
      index++;
      skipWhitespace();
      if (source[index] === "]") {
        index++;
        return;
      }
      while (true) {
        parseValue();
        skipWhitespace();
        const next = source[index++];
        if (next === "]") return;
        if (next !== ",") throw new Error(`expected comma at ${index - 1}`);
      }
    }
    if (c === '"') {
      readString();
      return;
    }
    while (index < source.length && !/[\s,}\]]/.test(source[index] ?? ""))
      index++;
  };
  try {
    parseValue();
    skipWhitespace();
    if (index !== source.length) throw new Error(`trailing data at ${index}`);
  } catch (error) {
    if (error instanceof SpendGrantError) throw error;
    throw new SpendGrantError(
      `invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}
