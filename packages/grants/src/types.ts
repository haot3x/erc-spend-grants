import type { Address, Hex } from "viem";

export const ZERO_ADDRESS =
  "0x0000000000000000000000000000000000000000" as const;
/** ERC-7528 sentinel for the native currency. */
export const NATIVE_ADDRESS =
  "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" as const;
export const UINT64_MAX = (1n << 64n) - 1n;
export const UINT256_MAX = (1n << 256n) - 1n;
export const MAX_ASSETS = 16;

export const RECIPIENT_MODE_LOCKED = 0;
export const RECIPIENT_MODE_ANY = 1;
export const ASSET_COMBINE_AND = 0;

export type RecipientMode =
  | typeof RECIPIENT_MODE_LOCKED
  | typeof RECIPIENT_MODE_ANY;
export type AssetCombine = typeof ASSET_COMBINE_AND;

export interface AssetLimit {
  asset: Address;
  maxPerCall: bigint;
  maxPerWindow: bigint;
  maxTotal: bigint;
}

export interface SpendGrant {
  principal: Address;
  delegate: Address;
  recipientMode: RecipientMode;
  recipient: Address;
  assetCombine: AssetCombine;
  windowSeconds: bigint;
  assets: readonly AssetLimit[];
  validAfter: bigint;
  validUntil: bigint;
  salt: bigint;
}

export interface SpendGrantInterchange {
  chainId: bigint;
  registry: Address;
  grant: SpendGrant;
}

export interface AssetLimitJson {
  asset: string;
  maxPerCall: string;
  maxPerWindow: string;
  maxTotal: string;
}

export interface SpendGrantJson {
  chainId: string;
  registry: string;
  grant: {
    principal: string;
    delegate: string;
    recipientMode: string;
    recipient: string;
    assetCombine: string;
    windowSeconds: string;
    assets: AssetLimitJson[];
    validAfter: string;
    validUntil: string;
    salt: string;
  };
}
