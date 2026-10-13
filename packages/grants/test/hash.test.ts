import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  concatHex,
  encodeAbiParameters,
  keccak256,
  toBytes,
  type Address,
  type Hex,
} from "viem";

import {
  ASSET_COMBINE_AND,
  ASSET_LIMIT_ENCODE_TYPE,
  ASSET_LIMIT_TYPEHASH,
  defineSpendGrant,
  hashAssetLimitArray,
  hashSpendGrant,
  hashSpendGrantStruct,
  hashSpendGrantTypedData,
  SPEND_GRANT_ENCODE_TYPE,
  SPEND_GRANT_TYPEHASH,
  parseSpendGrant,
  RECIPIENT_MODE_ANY,
  RECIPIENT_MODE_LOCKED,
  renderSpendGrant,
  toSpendGrantJson,
  NATIVE_ADDRESS,
  ZERO_ADDRESS,
  type SpendGrant,
  type SpendGrantInterchange,
} from "../src/index.js";

const VECTOR_PATH = resolve(fileURLToPath(new URL("../../../vectors/v1.json", import.meta.url)));

const CHAIN_ID = 31337n;
const REGISTRY =
  "0x4444444444444444444444444444444444444444" as Address;
const PRINCIPAL =
  "0x1111111111111111111111111111111111111111" as Address;
const DELEGATE =
  "0x2222222222222222222222222222222222222222" as Address;
const RECIPIENT =
  "0x3333333333333333333333333333333333333333" as Address;
const TOKEN_A =
  "0x00000000000000000000000000000000000000a0" as Address;

const VECTOR_NAMES = [
  "one-asset-locked-recipient",
  "two-asset-and-native-erc20",
  "eoa-principal",
] as const;

/** Anvil account 0's address. */
const EOA_ADDRESS =
  "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266" as Address;

/**
 * Literals, because the vector file is regenerated from this code: these pins are what stop a change to the
 * typed data from passing unnoticed. Renaming the registry member and its rendering label left them unchanged.
 */
const DOMAIN_SEPARATOR =
  "0x1040f75f67e75ef60a477f90720cc26434a4d3c1b0cb792b9acfbb39e591eeae";
const PINNED: Record<
  (typeof VECTOR_NAMES)[number],
  { structHash: Hex; digest: Hex }
> = {
  "one-asset-locked-recipient": {
    structHash:
      "0x17dc908df6dec4fbe8d92184a25919ecbdf0f3bf23161690485d8ab8f4516b9c",
    digest:
      "0x04c4583db88be0bb60d71e9e0ec4b6cc40378ba6dff9f2a58e19b4174fc09139",
  },
  "two-asset-and-native-erc20": {
    structHash:
      "0x3c6e2a0234ae1388d45cf2dc9366a3b90daa55369a60df508c8af27cef425746",
    digest:
      "0x7940d957c8919d08655e7a894510946917e532518a74318d50fbdec066d1347b",
  },
  "eoa-principal": {
    structHash:
      "0xeba170ad875d976128725374770856b70085f42ad64f535bfc0b6e18008f2a64",
    digest:
      "0xdefd61fdb6eed8eeaaae1fa664a787e955aed6a26771426467973ee0ac504890",
  },
};

interface GoldenVector {
  name: string;
  chainId: string;
  registry: string;
  grant: Record<string, unknown>;
  domainSeparator: Hex;
  structHash: Hex;
  digest: Hex;
  rendering: string;
}

/** Every member of a vector, in file order. No grant signature: grants are registered, not signed. */
const VECTOR_KEYS = [
  "name",
  "chainId",
  "registry",
  "grant",
  "domainSeparator",
  "structHash",
  "digest",
  "rendering",
];

interface VectorFile {
  version: number;
  encodeType: string;
  domain: { name: string; version: string };
  vectors: GoldenVector[];
}

function asset(
  token: Address,
  maxPerCall: bigint,
  maxPerWindow: bigint,
  maxTotal: bigint,
) {
  return { asset: token, maxPerCall, maxPerWindow, maxTotal };
}

function fixtures(): Record<(typeof VECTOR_NAMES)[number], SpendGrantInterchange> {
  return {
    "one-asset-locked-recipient": defineSpendGrant({
      chainId: CHAIN_ID,
      registry: REGISTRY,
      grant: {
        principal: PRINCIPAL,
        delegate: DELEGATE,
        recipientMode: RECIPIENT_MODE_LOCKED,
        recipient: RECIPIENT,
        assetCombine: ASSET_COMBINE_AND,
        windowSeconds: 86400n,
        assets: [asset(TOKEN_A, 10n, 100n, 1000n)],
        validAfter: 1_700_000_000n,
        validUntil: 1_800_000_000n,
        salt: 1n,
      },
    }),
    "two-asset-and-native-erc20": defineSpendGrant({
      chainId: CHAIN_ID,
      registry: REGISTRY,
      grant: {
        principal: PRINCIPAL,
        delegate: DELEGATE,
        recipientMode: RECIPIENT_MODE_ANY,
        recipient: ZERO_ADDRESS,
        assetCombine: ASSET_COMBINE_AND,
        windowSeconds: 86400n,
        assets: [
          asset(TOKEN_A, 10n, 100n, 1000n),
          asset(NATIVE_ADDRESS, 1n, 5n, 20n),
        ],
        validAfter: 1_700_000_000n,
        validUntil: 1_800_000_000n,
        salt: 2n,
      },
    }),
    "eoa-principal": defineSpendGrant({
      chainId: CHAIN_ID,
      registry: REGISTRY,
      grant: {
        principal: EOA_ADDRESS,
        delegate: DELEGATE,
        recipientMode: RECIPIENT_MODE_LOCKED,
        recipient: RECIPIENT,
        assetCombine: ASSET_COMBINE_AND,
        windowSeconds: 86400n,
        assets: [asset(TOKEN_A, 10n, 100n, 1000n)],
        validAfter: 1_700_000_000n,
        validUntil: 1_800_000_000n,
        salt: 4n,
      },
    }),
  };
}

function independentStructHash(grant: SpendGrant): Hex {
  const elementHashes = grant.assets.map((item) =>
    keccak256(
      encodeAbiParameters(
        [
          { type: "bytes32" },
          { type: "address" },
          { type: "uint256" },
          { type: "uint256" },
          { type: "uint256" },
        ],
        [
          ASSET_LIMIT_TYPEHASH,
          item.asset,
          item.maxPerCall,
          item.maxPerWindow,
          item.maxTotal,
        ],
      ),
    ),
  );
  const assetsHash = keccak256(concatHex(elementHashes));
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "address" },
        { type: "address" },
        { type: "uint8" },
        { type: "address" },
        { type: "uint8" },
        { type: "uint64" },
        { type: "bytes32" },
        { type: "uint64" },
        { type: "uint64" },
        { type: "uint256" },
      ],
      [
        SPEND_GRANT_TYPEHASH,
        grant.principal,
        grant.delegate,
        grant.recipientMode,
        grant.recipient,
        grant.assetCombine,
        grant.windowSeconds,
        assetsHash,
        grant.validAfter,
        grant.validUntil,
        grant.salt,
      ],
    ),
  );
}

function goldenFromInterchange(
  name: string,
  interchange: SpendGrantInterchange,
): GoldenVector {
  const hashes = hashSpendGrantTypedData(interchange);
  const rendering = renderSpendGrant(interchange);
  const json = toSpendGrantJson(interchange);
  return {
    name,
    chainId: json.chainId,
    registry: json.registry,
    grant: json.grant,
    domainSeparator: hashes.domainSeparator,
    structHash: hashes.structHash,
    digest: hashes.digest,
    rendering,
  };
}

function generateVectorFile(): VectorFile {
  const generated = fixtures();
  return {
    version: 1,
    encodeType: SPEND_GRANT_ENCODE_TYPE,
    domain: { name: "SpendGrant", version: "1" },
    vectors: VECTOR_NAMES.map((name) =>
      goldenFromInterchange(name, generated[name]),
    ),
  };
}

/** Writes vectors/v1.json from this code when the file is absent (delete it to regenerate); otherwise reads it. */
function loadOrWriteVectors(): VectorFile {
  if (!existsSync(VECTOR_PATH)) {
    mkdirSync(dirname(VECTOR_PATH), { recursive: true });
    const generated = generateVectorFile();
    writeFileSync(VECTOR_PATH, `${JSON.stringify(generated, null, 2)}\n`);
    return generated;
  }
  return JSON.parse(readFileSync(VECTOR_PATH, "utf8")) as VectorFile;
}

function findHashHarness(): string | undefined {
  const repoRoot = resolve(fileURLToPath(new URL("../../../", import.meta.url)));
  const candidates = [
    "out/HashHarness.sol/HashHarness.json",
    "out/HashHarness.json",
  ];
  for (const relative of candidates) {
    const path = resolve(repoRoot, relative);
    if (existsSync(path)) return path;
  }
  return undefined;
}

describe("spend grant hashing", () => {
  it("locks the ERC encodeType string", () => {
    expect(SPEND_GRANT_ENCODE_TYPE).toBe(
      "SpendGrant(address principal,address delegate,uint8 recipientMode,address recipient,uint8 assetCombine,uint64 windowSeconds,AssetLimit[] assets,uint64 validAfter,uint64 validUntil,uint256 salt)AssetLimit(address asset,uint256 maxPerCall,uint256 maxPerWindow,uint256 maxTotal)",
    );
    expect(ASSET_LIMIT_ENCODE_TYPE).toBe(
      "AssetLimit(address asset,uint256 maxPerCall,uint256 maxPerWindow,uint256 maxTotal)",
    );
    expect(SPEND_GRANT_TYPEHASH).toBe(keccak256(toBytes(SPEND_GRANT_ENCODE_TYPE)));
  });

  it("renders the ERC's labels exactly", () => {
    expect(renderSpendGrant(fixtures()["one-asset-locked-recipient"])).toBe(
      [
        "Spend grant v1",
        "Chain: 31337",
        "Registry: 0x4444444444444444444444444444444444444444",
        "Principal: 0x1111111111111111111111111111111111111111",
        "Delegate: 0x2222222222222222222222222222222222222222",
        "Recipient mode: 0",
        "Recipient: 0x3333333333333333333333333333333333333333",
        "Asset combine: 0",
        "Window seconds: 86400",
        "Budget count: 1",
        "Budget 0 asset: 0x00000000000000000000000000000000000000a0",
        "Budget 0 maximum per call (raw units): 10",
        "Budget 0 maximum per window (raw units): 100",
        "Budget 0 maximum total (raw units): 1000",
        "Valid after (inclusive Unix seconds): 1700000000",
        "Valid until (exclusive Unix seconds): 1800000000",
        "Salt: 1",
        "",
      ].join("\n"),
    );
  });

  it("matches golden vectors and independent EIP-712 reconstruction", () => {
    const file = loadOrWriteVectors();
    expect(file.encodeType).toBe(SPEND_GRANT_ENCODE_TYPE);
    expect(file.vectors.map((vector) => vector.name)).toEqual([...VECTOR_NAMES]);

    const generated = fixtures();
    for (const vector of file.vectors) {
      expect(Object.keys(vector)).toEqual(VECTOR_KEYS);
      const pinned = PINNED[vector.name as (typeof VECTOR_NAMES)[number]];
      expect(vector.domainSeparator).toBe(DOMAIN_SEPARATOR);
      expect(vector.structHash).toBe(pinned.structHash);
      expect(vector.digest).toBe(pinned.digest);
      const interchange = parseSpendGrant(
        JSON.stringify({
          chainId: vector.chainId,
          registry: vector.registry,
          grant: vector.grant,
        }),
      );
      const hashes = hashSpendGrantTypedData(interchange);
      const rendering = renderSpendGrant(interchange);

      expect(rendering).toBe(vector.rendering);
      expect(rendering.endsWith("\n")).toBe(true);
      expect(rendering.endsWith("\n\n")).toBe(false);
      expect(hashes.domainSeparator).toBe(vector.domainSeparator);
      expect(hashes.structHash).toBe(vector.structHash);
      expect(hashes.digest).toBe(vector.digest);
      expect(hashSpendGrant(interchange)).toBe(vector.digest);
      expect(hashSpendGrantStruct(interchange.grant)).toBe(vector.structHash);
      expect(independentStructHash(interchange.grant)).toBe(vector.structHash);
      expect(hashAssetLimitArray(interchange.grant.assets)).toBe(
        keccak256(
          concatHex(
            interchange.grant.assets.map((item) =>
              keccak256(
                encodeAbiParameters(
                  [
                    { type: "bytes32" },
                    { type: "address" },
                    { type: "uint256" },
                    { type: "uint256" },
                    { type: "uint256" },
                  ],
                  [
                    ASSET_LIMIT_TYPEHASH,
                    item.asset,
                    item.maxPerCall,
                    item.maxPerWindow,
                    item.maxTotal,
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      const local = generated[vector.name as (typeof VECTOR_NAMES)[number]];
      expect(hashSpendGrant(local)).toBe(vector.digest);
      expect(renderSpendGrant(local)).toBe(vector.rendering);
    }
  });

  it("optionally compares HashHarness ABI when the artifact exists", () => {
    const artifactPath = findHashHarness();
    if (!artifactPath) return;
    const artifact = JSON.parse(readFileSync(artifactPath, "utf8")) as {
      abi: Array<{ type: string; name?: string }>;
    };
    const names = new Set(
      artifact.abi
        .filter((item) => item.type === "function")
        .map((item) => item.name),
    );
    expect(
      names.has("digest") || names.has("hashStruct") || names.has("hashSpendGrant"),
    ).toBe(true);
  });
});
