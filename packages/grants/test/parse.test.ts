import { describe, expect, it } from "vitest";
import type { Address } from "viem";

import {
  ASSET_COMBINE_AND,
  defineSpendGrant,
  SpendGrantError,
  parseSpendGrant,
  RECIPIENT_MODE_LOCKED,
  stringifySpendGrant,
  toSpendGrantJson,
  NATIVE_ADDRESS,
  ZERO_ADDRESS,
  type SpendGrantInterchange,
} from "../src/index.js";

/** A plain literal: the first test validates it, so a parsing change fails tests rather than the module load. */
const SAMPLE: SpendGrantInterchange = {
  chainId: 31337n,
  registry: "0x4444444444444444444444444444444444444444" as Address,
  grant: {
    principal: "0x1111111111111111111111111111111111111111" as Address,
    delegate: "0x2222222222222222222222222222222222222222" as Address,
    recipientMode: RECIPIENT_MODE_LOCKED,
    recipient: "0x3333333333333333333333333333333333333333" as Address,
    assetCombine: ASSET_COMBINE_AND,
    windowSeconds: 86400n,
    assets: [
      {
        asset: "0x00000000000000000000000000000000000000a0" as Address,
        maxPerCall: 10n,
        maxPerWindow: 100n,
        maxTotal: 1000n,
      },
      {
        asset: NATIVE_ADDRESS,
        maxPerCall: 1n,
        maxPerWindow: 5n,
        maxTotal: 20n,
      },
    ],
    validAfter: 1_700_000_000n,
    validUntil: 1_800_000_000n,
    salt: 1n,
  },
};

function asJson(value: SpendGrantInterchange) {
  return JSON.parse(JSON.stringify(toSpendGrantJson(value))) as ReturnType<
    typeof toSpendGrantJson
  >;
}

describe("spend grant JSON parse", () => {
  it("round-trips canonical interchange JSON", () => {
    expect(defineSpendGrant(SAMPLE)).toEqual(SAMPLE);
    const text = stringifySpendGrant(SAMPLE);
    const parsed = parseSpendGrant(text);
    expect(parsed).toEqual(SAMPLE);
    expect(parseSpendGrant(toSpendGrantJson(SAMPLE))).toEqual(SAMPLE);
  });

  it("names the registry member registry and rejects revocationRegistry", () => {
    const json = asJson(SAMPLE);
    expect(Object.keys(json)).toEqual(["chainId", "registry", "grant"]);
    expect(parseSpendGrant(JSON.stringify(json)).registry).toBe(SAMPLE.registry);

    const { registry, ...rest } = json;
    expect(() =>
      parseSpendGrant(JSON.stringify({ ...rest, revocationRegistry: registry })),
    ).toThrow(/expected exactly chainId, grant, registry;/);
    expect(() =>
      parseSpendGrant(JSON.stringify({ ...json, revocationRegistry: registry })),
    ).toThrow(SpendGrantError);
    expect(() =>
      defineSpendGrant({
        chainId: SAMPLE.chainId,
        revocationRegistry: SAMPLE.registry,
        grant: SAMPLE.grant,
      } as unknown as SpendGrantInterchange),
    ).toThrow(/expected exactly chainId, grant, registry;/);
  });

  it("rejects extra fields", () => {
    const json = asJson(SAMPLE);
    expect(() =>
      parseSpendGrant(JSON.stringify({ ...json, extra: true })),
    ).toThrow(SpendGrantError);
    expect(() =>
      parseSpendGrant(
        JSON.stringify({
          ...json,
          grant: { ...json.grant, extra: "nope" },
        }),
      ),
    ).toThrow(SpendGrantError);
    const asset = json.grant.assets[0];
    expect(asset).toBeDefined();
    expect(() =>
      parseSpendGrant(
        JSON.stringify({
          ...json,
          grant: {
            ...json.grant,
            assets: [{ ...asset, extra: 1 }, json.grant.assets[1]],
          },
        }),
      ),
    ).toThrow(SpendGrantError);
  });

  it("rejects unsorted assets", () => {
    const first = SAMPLE.grant.assets[0];
    const second = SAMPLE.grant.assets[1];
    expect(first).toBeDefined();
    expect(second).toBeDefined();
    const reversed: SpendGrantInterchange = {
      ...SAMPLE,
      grant: {
        ...SAMPLE.grant,
        assets: [second!, first!],
      },
    };
    expect(() => parseSpendGrant(JSON.stringify(toSpendGrantJson(reversed)))).toThrow(
      /ascending|sorted|unique/i,
    );
  });

  it("rejects zero max", () => {
    const json = asJson(SAMPLE);
    const asset = json.grant.assets[0];
    expect(asset).toBeDefined();
    asset!.maxPerCall = "0";
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/positive/i);
    asset!.maxPerCall = "1";
    asset!.maxPerWindow = "0";
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/positive/i);
    asset!.maxPerWindow = "5";
    asset!.maxTotal = "0";
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/positive/i);
  });

  it("rejects zero-address asset but allows NATIVE_ADDRESS", () => {
    const json = asJson(SAMPLE);
    const asset = json.grant.assets[0];
    expect(asset).toBeDefined();
    asset!.asset = ZERO_ADDRESS;
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/nonzero/i);

    expect(SAMPLE.grant.assets[1]?.asset).toBe(NATIVE_ADDRESS);
    expect(() => parseSpendGrant(toSpendGrantJson(SAMPLE))).not.toThrow();
  });

  it("rejects bad recipientMode", () => {
    const json = asJson(SAMPLE);
    json.grant.recipientMode = "2";
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/0 or 1/i);
    json.grant.recipientMode = "3";
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/0 or 1/i);
  });

  it("rejects nonzero assetCombine", () => {
    const json = asJson(SAMPLE);
    json.grant.assetCombine = "1";
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/must be 0/i);
    json.grant.assetCombine = "2";
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/must be 0/i);
  });

  it("rejects duplicate JSON keys", () => {
    const compact = JSON.stringify(toSpendGrantJson(SAMPLE));
    const duplicate = compact.replace(
      '"salt":"1"',
      '"salt":"1","salt":"1"',
    );
    expect(() => parseSpendGrant(duplicate)).toThrow(/duplicate/i);
  });

  it("rejects JSON numbers, leading zeros, and mixed-case hex", () => {
    const numbered = stringifySpendGrant(SAMPLE).replace(
      '"chainId": "31337"',
      '"chainId": 31337',
    );
    expect(() => parseSpendGrant(numbered)).toThrow(/canonical unsigned decimal/i);

    const json = asJson(SAMPLE);
    json.grant.windowSeconds = "086400";
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(
      /canonical unsigned decimal/i,
    );

    json.grant.windowSeconds = "86400";
    json.grant.principal = "0x1111111111111111111111111111111111111111".replace(
      "1111",
      "1111",
    );
    json.registry = "0x4444444444444444444444444444444444444444".toUpperCase();
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(/lowercase/i);
  });

  it("rejects missing fields, a renderingHash member, and asset count", () => {
    const json = asJson(SAMPLE);
    const grant = json.grant as Record<string, unknown>;
    delete grant.salt;
    expect(() => parseSpendGrant(JSON.stringify(json))).toThrow(SpendGrantError);

    const extra = asJson(SAMPLE) as { grant: Record<string, unknown> };
    extra.grant.renderingHash =
      "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    expect(() => parseSpendGrant(JSON.stringify(extra))).toThrow(SpendGrantError);

    const empty = asJson(SAMPLE);
    empty.grant.assets = [];
    expect(() => parseSpendGrant(JSON.stringify(empty))).toThrow(/1 to 16/i);

    const tooMany = asJson(SAMPLE);
    tooMany.grant.assets = Array.from({ length: 17 }, (_, i) => ({
      asset: `0x${(i + 1).toString(16).padStart(40, "0")}`,
      maxPerCall: "1",
      maxPerWindow: "1",
      maxTotal: "1",
    }));
    expect(() => parseSpendGrant(JSON.stringify(tooMany))).toThrow(/1 to 16/i);
  });
});
