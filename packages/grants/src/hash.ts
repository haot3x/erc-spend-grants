import {
  concatHex,
  domainSeparator,
  hashStruct,
  hashTypedData,
  keccak256,
  toBytes,
  type Address,
  type Hex,
} from "viem";

import type { AssetLimit, SpendGrant, SpendGrantInterchange } from "./types.js";

export const SPEND_GRANT_DOMAIN_NAME = "SpendGrant";
export const SPEND_GRANT_DOMAIN_VERSION = "1";

/** Exact EIP-712 encodeType from the ERC. */
export const SPEND_GRANT_ENCODE_TYPE =
  "SpendGrant(address principal,address delegate,uint8 recipientMode,address recipient,uint8 assetCombine,uint64 windowSeconds,AssetLimit[] assets,uint64 validAfter,uint64 validUntil,uint256 salt)AssetLimit(address asset,uint256 maxPerCall,uint256 maxPerWindow,uint256 maxTotal)";

export const ASSET_LIMIT_ENCODE_TYPE =
  "AssetLimit(address asset,uint256 maxPerCall,uint256 maxPerWindow,uint256 maxTotal)";

export const SPEND_GRANT_TYPEHASH = keccak256(toBytes(SPEND_GRANT_ENCODE_TYPE));
export const ASSET_LIMIT_TYPEHASH = keccak256(toBytes(ASSET_LIMIT_ENCODE_TYPE));

export const spendGrantTypes = {
  AssetLimit: [
    { name: "asset", type: "address" },
    { name: "maxPerCall", type: "uint256" },
    { name: "maxPerWindow", type: "uint256" },
    { name: "maxTotal", type: "uint256" },
  ],
  SpendGrant: [
    { name: "principal", type: "address" },
    { name: "delegate", type: "address" },
    { name: "recipientMode", type: "uint8" },
    { name: "recipient", type: "address" },
    { name: "assetCombine", type: "uint8" },
    { name: "windowSeconds", type: "uint64" },
    { name: "assets", type: "AssetLimit[]" },
    { name: "validAfter", type: "uint64" },
    { name: "validUntil", type: "uint64" },
    { name: "salt", type: "uint256" },
  ],
} as const;

export interface SpendGrantDomain {
  name: typeof SPEND_GRANT_DOMAIN_NAME;
  version: typeof SPEND_GRANT_DOMAIN_VERSION;
  chainId: bigint;
  verifyingContract: Address;
}

export interface SpendGrantHashes {
  domainSeparator: Hex;
  structHash: Hex;
  digest: Hex;
}

export function spendGrantDomain(input: {
  chainId: bigint;
  registry: Address;
}): SpendGrantDomain {
  return {
    name: SPEND_GRANT_DOMAIN_NAME,
    version: SPEND_GRANT_DOMAIN_VERSION,
    chainId: input.chainId,
    verifyingContract: input.registry,
  };
}

export function toSpendGrantTypedData(grant: SpendGrant) {
  return {
    principal: grant.principal,
    delegate: grant.delegate,
    recipientMode: grant.recipientMode,
    recipient: grant.recipient,
    assetCombine: grant.assetCombine,
    windowSeconds: grant.windowSeconds,
    assets: grant.assets.map((asset) => ({
      asset: asset.asset,
      maxPerCall: asset.maxPerCall,
      maxPerWindow: asset.maxPerWindow,
      maxTotal: asset.maxTotal,
    })),
    validAfter: grant.validAfter,
    validUntil: grant.validUntil,
    salt: grant.salt,
  };
}

export function hashAssetLimit(asset: AssetLimit): Hex {
  return hashStruct({
    types: { AssetLimit: spendGrantTypes.AssetLimit },
    primaryType: "AssetLimit",
    data: {
      asset: asset.asset,
      maxPerCall: asset.maxPerCall,
      maxPerWindow: asset.maxPerWindow,
      maxTotal: asset.maxTotal,
    },
  });
}

/** EIP-712 array of structs: keccak256 of concatenated element hashes, no length. */
export function hashAssetLimitArray(assets: readonly AssetLimit[]): Hex {
  const hashes = assets.map(hashAssetLimit);
  return keccak256(hashes.length === 0 ? "0x" : concatHex(hashes));
}

export function hashSpendGrantDomain(input: {
  chainId: bigint;
  registry: Address;
}): Hex {
  return domainSeparator({ domain: spendGrantDomain(input) });
}

export function hashSpendGrantStruct(grant: SpendGrant): Hex {
  return hashStruct({
    types: spendGrantTypes,
    primaryType: "SpendGrant",
    data: toSpendGrantTypedData(grant),
  });
}

export function hashSpendGrantTypedData(
  interchange: SpendGrantInterchange,
): SpendGrantHashes {
  const domain = spendGrantDomain(interchange);
  const message = toSpendGrantTypedData(interchange.grant);
  const domainSeparatorValue = domainSeparator({ domain });
  const structHash = hashStruct({
    types: spendGrantTypes,
    primaryType: "SpendGrant",
    data: message,
  });
  const digest = hashTypedData({
    domain,
    types: spendGrantTypes,
    primaryType: "SpendGrant",
    message,
  });
  const reconstructed = keccak256(
    concatHex(["0x1901", domainSeparatorValue, structHash]),
  );
  if (digest !== reconstructed) {
    throw new Error("digest reconstruction does not match hashTypedData");
  }
  return {
    domainSeparator: domainSeparatorValue,
    structHash,
    digest,
  };
}

/**
 * The digest of the terms: the `grantId` that registering them on `registry` would assign. After an `update`, a
 * grant's id can differ from the digest of its current terms, which can even equal another grant's id, so do not
 * derive a registered grant's id from them.
 */
export function hashSpendGrant(interchange: SpendGrantInterchange): Hex {
  return hashSpendGrantTypedData(interchange).digest;
}

// ---------------------------------------------------------------------------
// SpendAuthorization: what a delegate signs for the reference authorization executor.
// The executor is the verifying contract, so the domain is per executor deployment.

export const SPEND_AUTHORIZATION_DOMAIN_NAME = "SpendAuthorization";
export const SPEND_AUTHORIZATION_DOMAIN_VERSION = "1";

export const SPEND_AUTHORIZATION_ENCODE_TYPE =
  "SpendAuthorization(bytes32 grantId,address asset,uint256 amount,address recipient,uint256 nonce,uint256 deadline)";

export const SPEND_AUTHORIZATION_TYPEHASH = keccak256(
  toBytes(SPEND_AUTHORIZATION_ENCODE_TYPE),
);

export const spendAuthorizationTypes = {
  SpendAuthorization: [
    { name: "grantId", type: "bytes32" },
    { name: "asset", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "recipient", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export interface SpendAuthorization {
  grantId: Hex;
  asset: Address;
  amount: bigint;
  recipient: Address;
  nonce: bigint;
  deadline: bigint;
}

export interface SpendAuthorizationDomain {
  name: typeof SPEND_AUTHORIZATION_DOMAIN_NAME;
  version: typeof SPEND_AUTHORIZATION_DOMAIN_VERSION;
  chainId: bigint;
  verifyingContract: Address;
}

export function spendAuthorizationDomain(input: {
  chainId: bigint;
  executor: Address;
}): SpendAuthorizationDomain {
  return {
    name: SPEND_AUTHORIZATION_DOMAIN_NAME,
    version: SPEND_AUTHORIZATION_DOMAIN_VERSION,
    chainId: input.chainId,
    verifyingContract: input.executor,
  };
}

export function hashSpendAuthorizationTypedData(input: {
  chainId: bigint;
  executor: Address;
  authorization: SpendAuthorization;
}): SpendGrantHashes {
  const domain = spendAuthorizationDomain(input);
  const message = { ...input.authorization };
  const domainSeparatorValue = domainSeparator({ domain });
  const structHash = hashStruct({
    types: spendAuthorizationTypes,
    primaryType: "SpendAuthorization",
    data: message,
  });
  const digest = hashTypedData({
    domain,
    types: spendAuthorizationTypes,
    primaryType: "SpendAuthorization",
    message,
  });
  const reconstructed = keccak256(
    concatHex(["0x1901", domainSeparatorValue, structHash]),
  );
  if (digest !== reconstructed) {
    throw new Error("authorization digest reconstruction does not match hashTypedData");
  }
  return { domainSeparator: domainSeparatorValue, structHash, digest };
}
