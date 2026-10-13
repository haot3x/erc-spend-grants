#!/usr/bin/env node
// SPDX-License-Identifier: CC0-1.0
//
// Promotes this repo's core Solidity reference into the ethereum/ERCs layout
// (ERCS/<slug>.md + assets/<slug>/{src,test,vectors,clear-signing}).
//
// Usage:
//   node scripts/erc-promote.mjs --to <dir>   (default: ../ERCs)
//   node scripts/erc-promote.mjs --check      (assemble in a temp dir and run forge test there)

import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SRC_DIR = join(REPO_ROOT, "src");
const TEST_DIR = join(REPO_ROOT, "test");
const VECTOR_PATH = join(REPO_ROOT, "vectors", "v1.json");
const AUTHORIZATION_VECTOR_PATH = join(REPO_ROOT, "vectors", "authorization-v1.json");
const DESCRIPTOR_PATH = join(REPO_ROOT, "descriptors", "spend-grant.erc7730.json");
/// @dev ERC file slug, `erc-<N>` for the number the ERCs editors assigned.
const ERC_SLUG = "erc-8427";
const ERC_DOC_PATH = join(REPO_ROOT, "ERCS", `${ERC_SLUG}.md`);
const FORGE_STD_LIB = join(REPO_ROOT, "lib", "forge-std");

const ASSETS_VECTOR_REL = `assets/${ERC_SLUG}/vectors/v1.json`;
const ASSETS_AUTHORIZATION_VECTOR_REL = `assets/${ERC_SLUG}/vectors/authorization-v1.json`;

function parseArgs(argv) {
  const args = { to: null, check: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--check") args.check = true;
    else if (a === "--to") args.to = argv[++i];
  }
  return args;
}

function listSolFiles(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".sol"))
    .sort();
}

/// @dev Rewrites the vm.readFile vector path used inside the repo (vectors/v1.json)
/// to the path a promoted test would see when run from an ethereum/ERCs checkout root.
function rewriteVectorPath(source) {
  return source
    .replaceAll('vm.readFile("vectors/v1.json")', `vm.readFile("${ASSETS_VECTOR_REL}")`)
    .replaceAll(
      'vm.readFile("vectors/authorization-v1.json")',
      `vm.readFile("${ASSETS_AUTHORIZATION_VECTOR_REL}")`,
    );
}

function assetsReadme(srcFiles, testFiles) {
  return (
    "# Assets for Portable Spend Grants\n\n" +
    "- `vectors/v1.json` — golden domain separator, struct hash, digest (the `grantId`), and canonical rendering of each grant\n" +
    "- `vectors/authorization-v1.json` — golden digest and signature for the reference executor's SpendAuthorization\n" +
    "- `clear-signing/spend-grant.json` — non-normative ERC-7730 calldata descriptor for the registry's `register` and `update`; " +
    "it lists the Arc testnet registry\n" +
    `- \`src/\` — compact Solidity reference (CC0): ${srcFiles.join(", ")}\n` +
    `- \`test/\` — Foundry tests for the reference (${testFiles.join(", ")}). They import ` +
    `\`../src/\` and read vectors at \`${ASSETS_VECTOR_REL}\` when run ` +
    "from a Foundry project that has this directory at that path, with the reference's compiler settings: " +
    "solc 0.8.28, `via_ir = true`, the optimizer at 200 runs, `evm_version = \"cancun\"`, and read access to " +
    "`./assets` in `fs_permissions`. Without via-IR some tests do not compile.\n\n" +
    "The full reference repository, with the TypeScript package, Halmos properties, deploy script, " +
    "and Arc testnet deployment record, is https://github.com/tankcdr/erc-spend-grants.\n"
  );
}

/// @dev Builds the promoted assets/<slug> payload in memory: relative path -> content (string or Buffer).
function buildAssetsPayload() {
  const srcFiles = listSolFiles(SRC_DIR);
  const testFiles = listSolFiles(TEST_DIR);
  const payload = new Map();

  for (const f of srcFiles) {
    payload.set(`src/${f}`, readFileSync(join(SRC_DIR, f)));
  }
  for (const f of testFiles) {
    payload.set(`test/${f}`, rewriteVectorPath(readFileSync(join(TEST_DIR, f), "utf8")));
  }
  payload.set("vectors/v1.json", readFileSync(VECTOR_PATH));
  payload.set("vectors/authorization-v1.json", readFileSync(AUTHORIZATION_VECTOR_PATH));
  payload.set("clear-signing/spend-grant.json", readFileSync(DESCRIPTOR_PATH));
  payload.set("README.md", assetsReadme(srcFiles, testFiles));

  return payload;
}

function writePayload(assetsDir, payload) {
  const written = [];
  for (const [relPath, content] of payload) {
    const full = join(assetsDir, relPath);
    mkdirSync(dirname(full), { recursive: true });
    writeFileSync(full, content);
    written.push(relPath);
  }
  return written;
}

function removeStaleFiles(assetsDir, payload) {
  const removed = [];
  const walk = (dir, prefix) => {
    if (!existsSync(dir)) return;
    for (const entry of readdirSync(dir)) {
      const full = join(dir, entry);
      const rel = prefix ? `${prefix}/${entry}` : entry;
      if (statSync(full).isDirectory()) {
        walk(full, rel);
      } else if (!payload.has(rel)) {
        rmSync(full);
        removed.push(rel);
      }
    }
  };
  walk(assetsDir, "");
  return removed;
}

/// @dev Fails --check if any src/*.sol imports a path outside src/ (i.e. anything not "./").
function checkSrcImportsAreSelfContained() {
  const offenders = [];
  for (const f of listSolFiles(SRC_DIR)) {
    const text = readFileSync(join(SRC_DIR, f), "utf8");
    const importRe = /import\s+(?:\{[^}]*\}\s+from\s+)?"([^"]+)"/g;
    let m;
    while ((m = importRe.exec(text))) {
      const spec = m[1];
      if (!spec.startsWith("./")) offenders.push(`${f}: ${spec}`);
    }
  }
  return offenders;
}

function promote(toDir) {
  const target = resolve(toDir);
  const targetErcsDir = join(target, "ERCS");
  if (!existsSync(targetErcsDir)) {
    console.error(`Refusing: ${targetErcsDir} does not exist (--to must point at an ERCs fork checkout).`);
    process.exit(1);
  }

  const payload = buildAssetsPayload();
  const assetsDir = join(target, "assets", ERC_SLUG);
  mkdirSync(assetsDir, { recursive: true });

  const removed = removeStaleFiles(assetsDir, payload);
  const written = writePayload(assetsDir, payload);

  const ercDocTarget = join(targetErcsDir, basename(ERC_DOC_PATH));
  cpSync(ERC_DOC_PATH, ercDocTarget);

  console.log(`Promoted to ${target}`);
  console.log(`Wrote ERCS/${basename(ERC_DOC_PATH)}`);
  console.log(`Wrote ${written.length} file(s) under assets/${ERC_SLUG}/:`);
  for (const f of written) console.log(`  ${f}`);
  if (removed.length) {
    console.log(`Removed ${removed.length} stale file(s):`);
    for (const f of removed) console.log(`  ${f}`);
  }
}

function check() {
  const offenders = checkSrcImportsAreSelfContained();
  if (offenders.length) {
    console.error("src/*.sol has imports outside src/:");
    for (const o of offenders) console.error(`  ${o}`);
    process.exit(1);
  }

  const tmp = mkdtempSync(join(tmpdir(), "erc-promote-"));
  try {
    const payload = buildAssetsPayload();
    const assetsDir = join(tmp, "assets", ERC_SLUG);
    mkdirSync(assetsDir, { recursive: true });
    writePayload(assetsDir, payload);

    const foundryToml =
      "[profile.default]\n" +
      `src = "assets/${ERC_SLUG}/src"\n` +
      `test = "assets/${ERC_SLUG}/test"\n` +
      'out = "out"\n' +
      `libs = ["${dirname(FORGE_STD_LIB).replace(/\\/g, "/")}"]\n` +
      'solc_version = "0.8.28"\n' +
      'evm_version = "cancun"\n' +
      "optimizer = true\n" +
      "optimizer_runs = 200\n" +
      "via_ir = true\n" +
      `fs_permissions = [{ access = "read", path = "./assets" }]\n`;
    writeFileSync(join(tmp, "foundry.toml"), foundryToml);
    writeFileSync(join(tmp, "remappings.txt"), `forge-std/=${FORGE_STD_LIB.replace(/\\/g, "/")}/src/\n`);

    console.log(`Checking promoted assets in ${tmp}`);
    execFileSync("forge", ["test", "--root", tmp], {
      cwd: tmp,
      stdio: "inherit",
    });
    console.log("erc:check passed.");
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

const args = parseArgs(process.argv.slice(2));
if (args.check) {
  check();
} else {
  promote(args.to ?? join(REPO_ROOT, "..", "ERCs"));
}
