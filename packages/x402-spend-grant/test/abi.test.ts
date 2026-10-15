import { describe, expect, it } from "vitest";
import type { AbiParameter } from "viem";
import { spendGrantExecutorAbi, spendGrantRegistryAbi } from "../src/index.js";
import { revertAbi } from "../src/errors.js";
import { artifact } from "./harness.js";

interface Entry {
  type: string;
  name?: string;
  inputs?: readonly AbiParameter[];
  outputs?: readonly AbiParameter[];
  stateMutability?: string;
}

function typeOf(p: AbiParameter): string {
  return "components" in p && p.components !== undefined
    ? `(${p.components.map(typeOf).join(",")})${p.type.slice("tuple".length)}`
    : p.type;
}

const shape = (e: Entry) => ({
  type: e.type,
  name: e.name,
  inputs: (e.inputs ?? []).map(typeOf),
  outputs: (e.outputs ?? []).map(typeOf),
  stateMutability: e.type === "function" ? e.stateMutability : undefined,
});

function drift(file: string, name: string, fragments: readonly Entry[]) {
  const onChain = artifact(file, name).abi as unknown as Entry[];
  for (const f of fragments) {
    it(`${f.type} ${f.name} matches ${name}`, () => {
      const match = onChain.find((e) => e.type === f.type && e.name === f.name);
      expect(match, `${f.name} is not in out/${file}`).toBeDefined();
      expect(shape(f)).toEqual(shape(match as Entry));
    });
  }
}

describe("hand-written ABI fragments match the compiled contracts", () => {
  drift("SpendGrantAuthorizationExecutor.sol", "SpendGrantAuthorizationExecutor", spendGrantExecutorAbi);
  drift("SpendGrantRegistry.sol", "SpendGrantRegistry", spendGrantRegistryAbi);
});

describe("every compiled custom error can be decoded", () => {
  const files = [
    ["SpendGrantAuthorizationExecutor.sol", "SpendGrantAuthorizationExecutor"],
    ["SpendGrantRegistry.sol", "SpendGrantRegistry"],
  ] as const;
  for (const [file, name] of files) {
    const errors = (artifact(file, name).abi as unknown as Entry[]).filter((e) => e.type === "error");
    for (const e of errors) {
      it(`error ${e.name} of ${name} is in the revert ABI`, () => {
        const match = (revertAbi as readonly Entry[]).find((r) => r.type === "error" && r.name === e.name);
        expect(match, `${e.name} is missing from the revert ABI`).toBeDefined();
        expect(shape(match as Entry)).toEqual(shape(e));
      });
    }
  }
});
