import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Ajv2020 } from "ajv/dist/2020.js";
import {
  parseAbiItem,
  toFunctionSelector,
  type AbiFunction,
  type AbiParameter,
} from "viem";
import { describe, expect, it } from "vitest";

import { spendGrantTypes, ZERO_ADDRESS } from "../src/index.js";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const DESCRIPTOR_DIR = join(REPO_ROOT, "descriptors");

interface Field {
  $id?: string;
  path?: string;
  label?: string;
  format?: string;
  params?: Record<string, unknown>;
  visible?: unknown;
  $ref?: string;
  fields?: Field[];
}

interface Format {
  intent?: unknown;
  fields: Field[];
}

function readJson(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
}

const descriptor = readJson(join(DESCRIPTOR_DIR, "spend-grant.erc7730.json"));
const schema = readJson(join(DESCRIPTOR_DIR, "erc7730-v2.1.0.schema.json"));

/** The SpendGrant tuple as an ERC-7730 key writes it: canonical types, no space after a comma, one before a name. */
const ASSET_LIMIT_TUPLE = `(${spendGrantTypes.AssetLimit.map((m) => `${m.type} ${m.name}`).join(",")})`;
const SPEND_GRANT_TUPLE = `(${spendGrantTypes.SpendGrant.map((m) =>
  m.type === "AssetLimit[]" ? `${ASSET_LIMIT_TUPLE}[] ${m.name}` : `${m.type} ${m.name}`,
).join(",")})`;
const REGISTER_KEY = `register(${SPEND_GRANT_TUPLE} terms)`;
const UPDATE_KEY = `update(bytes32 grantId,uint256 expectedVersion,${SPEND_GRANT_TUPLE} terms)`;

/** The reference registry's selectors, from `forge inspect SpendGrantRegistry methodIdentifiers`. */
const SELECTORS: Array<[string, string]> = [
  [REGISTER_KEY, "0x91613768"],
  [UPDATE_KEY, "0xb871aecb"],
];

function abiFunction(key: string): AbiFunction {
  return parseAbiItem(`function ${key}`) as AbiFunction;
}

/** Every leaf of a function's arguments as an ERC-7730 path (`terms.assets.[].maxTotal`). */
function abiLeaves(params: readonly AbiParameter[], prefix = ""): string[] {
  return params.flatMap((param) => {
    const path = prefix ? `${prefix}.${param.name}` : `${param.name}`;
    const components = (param as { components?: readonly AbiParameter[] }).components;
    if (param.type === "tuple" && components) return abiLeaves(components, path);
    if (param.type === "tuple[]" && components) return abiLeaves(components, `${path}.[]`);
    return [path];
  });
}

/** Flattens a field tree into full paths, keeping the path of the group each field sits in. */
function flatten(
  fields: Field[],
  prefix = "",
): Array<{ path: string; group: string; field: Field }> {
  return fields.flatMap((field) => {
    const path =
      field.path === undefined ? prefix : prefix ? `${prefix}.${field.path}` : field.path;
    return field.fields ? flatten(field.fields, path) : [{ path, group: prefix, field }];
  });
}

/** Resolves a `$.` path inside the descriptor. */
function resolveRoot(path: string): unknown {
  expect(path.startsWith("$.")).toBe(true);
  return path
    .slice(2)
    .split(".")
    .reduce<any>((node, key) => node?.[key], descriptor);
}

/** A field merged with the definition it references, as a wallet would apply it. */
function effective(field: Field): Field {
  const definition = field.$ref ? (resolveRoot(field.$ref) as Field) : {};
  return {
    ...definition,
    ...field,
    params: { ...definition.params, ...field.params },
  };
}

function formats(): Array<[string, Format]> {
  return Object.entries(descriptor.display.formats) as Array<[string, Format]>;
}

describe("ERC-7730 descriptor", () => {
  it("validates against the ERC-7730 v2.1.0 schema", () => {
    const ajv = new Ajv2020({ strict: false, allErrors: true, validateFormats: false });
    const validate = ajv.compile(schema);
    const ok = validate(descriptor);
    expect(validate.errors ?? []).toEqual([]);
    expect(ok).toBe(true);
  });

  it("binds registry calldata to the recorded deployment", () => {
    // The descriptor names exactly the Arc testnet registry recorded in deployments/5042002.json.
    const arc = JSON.parse(readFileSync(join(REPO_ROOT, "deployments", "5042002.json"), "utf8"));
    expect(descriptor.context.eip712).toBeUndefined();
    expect(descriptor.context.contract.deployments).toEqual([{ chainId: arc.chainId, address: arc.registry }]);
  });

  it("keys register and update by their exact ABI fragments", () => {
    expect(Object.keys(descriptor.display.formats)).toEqual([REGISTER_KEY, UPDATE_KEY]);
    for (const [key, selector] of SELECTORS) {
      expect(toFunctionSelector(abiFunction(key))).toBe(selector);
    }
  });

  it("covers every argument exactly once, with paths and references that resolve", () => {
    let checked = 0;
    for (const [key, format] of formats()) {
      const leaves = abiLeaves(abiFunction(key).inputs);
      const flat = flatten(format.fields);
      expect(flat.map((entry) => entry.path).sort()).toEqual([...leaves].sort());
      for (const { group, field } of flat) {
        const applied = effective(field);
        if (field.$ref) expect(resolveRoot(field.$ref)).toBeDefined();
        const tokenPath = applied.params?.tokenPath;
        if (typeof tokenPath === "string") expect(leaves).toContain(`${group}.${tokenPath}`);
        for (const value of Object.values(applied.params ?? {})) {
          if (typeof value === "string" && value.startsWith("$.")) {
            expect(resolveRoot(value)).toBeDefined();
          }
        }
        const hidden =
          applied.visible === "never" ||
          (typeof applied.visible === "object" && applied.visible !== null && "mustMatch" in applied.visible);
        if (!hidden) expect(applied.label).toEqual(expect.any(String));
        checked++;
      }
    }
    // 13 SpendGrant leaves in register; update adds grantId and expectedVersion.
    expect(checked).toBe(13 + 15);
  });

  it("shows the delegate, payee, window, caps in token units, and validity dates", () => {
    for (const [, format] of formats()) {
      expect(format.intent).toEqual(expect.any(String));
      const byPath = new Map(flatten(format.fields).map((entry) => [entry.path, effective(entry.field)]));
      const at = (path: string) => byPath.get(path);

      expect(at("terms.delegate")).toMatchObject({ format: "addressName" });
      expect(at("terms.recipientMode")).toMatchObject({
        format: "enum",
        params: { $ref: "$.metadata.enums.recipientMode" },
      });
      expect(at("terms.recipient")).toMatchObject({
        format: "addressName",
        visible: { ifNotIn: [ZERO_ADDRESS] },
      });
      expect(at("terms.windowSeconds")).toMatchObject({ format: "duration" });
      for (const cap of ["maxPerCall", "maxPerWindow", "maxTotal"]) {
        expect(at(`terms.assets.[].${cap}`)).toMatchObject({
          format: "tokenAmount",
          params: { tokenPath: "asset", nativeCurrencyAddress: "$.metadata.constants.native" },
        });
      }
      for (const date of ["validAfter", "validUntil"]) {
        expect(at(`terms.${date}`)).toMatchObject({
          format: "date",
          params: { encoding: "timestamp" },
        });
      }
      // A wallet must reject terms whose assetCombine is not 0.
      expect(at("terms.assetCombine")?.visible).toEqual({ mustMatch: [0] });
      for (const hidden of ["terms.principal", "terms.salt", "terms.assets.[].asset"]) {
        expect(at(hidden)?.visible).toBe("never");
      }
    }
    expect(descriptor.metadata.enums.recipientMode).toEqual({
      "0": "One recipient",
      "1": "Any recipient",
    });
    expect(descriptor.metadata.constants.native.toLowerCase()).toBe(
      "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    );
  });

  it("shows which grant update changes", () => {
    const fields = descriptor.display.formats[UPDATE_KEY].fields as Field[];
    expect(fields.find((field) => field.path === "grantId")).toMatchObject({
      format: "raw",
      label: expect.any(String),
    });
    expect(fields.find((field) => field.path === "grantId")?.visible).toBeUndefined();
  });

  it("describes the terms identically in register and update", () => {
    const terms = (key: string) =>
      (descriptor.display.formats[key].fields as Field[]).filter((field) =>
        field.path?.startsWith("terms."),
      );
    expect(terms(REGISTER_KEY)).toHaveLength(spendGrantTypes.SpendGrant.length);
    expect(terms(UPDATE_KEY)).toEqual(terms(REGISTER_KEY));
  });
});
