import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  getAddress,
  getContractAddress,
  http,
  type Abi,
  type Address,
  type Hex,
  type LocalAccount,
} from "viem";
import { mnemonicToAccount } from "viem/accounts";

const repoRoot = fileURLToPath(new URL("../../../", import.meta.url));
const MNEMONIC = "test test test test test test test test test test test junk";

export interface Artifact {
  abi: Abi;
  bytecode: { object: Hex };
}

export function artifact(file: string, name: string): Artifact {
  const path = `${repoRoot}out/${file}/${name}.json`;
  if (!existsSync(path)) throw new Error(`${path} is missing: run \`forge build\` first`);
  return JSON.parse(readFileSync(path, "utf8")) as Artifact;
}

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address() as { port: number };
      s.close(() => resolve(port));
    });
  });
}

const ANVIL_CHAIN_ID = 31337;

/** `ANVIL_BIN`, else Foundry's default install, else `anvil` on PATH. */
function anvilBin(): string {
  const foundry = `${homedir()}/.foundry/bin/anvil`;
  return process.env["ANVIL_BIN"] || (existsSync(foundry) ? foundry : "anvil");
}

async function chainIdAt(url: string): Promise<string | undefined> {
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
    });
    return ((await res.json()) as { result?: string }).result;
  } catch {
    return undefined; // not listening yet
  }
}

export async function startAnvil(): Promise<{ url: string; stop: () => void }> {
  const bin = anvilBin();
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;
  const child: ChildProcess = spawn(bin, ["--port", String(port), "--chain-id", String(ANVIL_CHAIN_ID), "--silent"], {
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr?.on("data", (b: Buffer) => (stderr = (stderr + b.toString()).slice(-4096)));
  let failed: Error | undefined;
  child.once("error", (e) => (failed = e));
  child.once("exit", (code, signal) => {
    failed ??= new Error(`anvil (${bin}) exited with ${code ?? signal} before it was ready: ${stderr.trim()}`);
  });
  for (let i = 0; i < 200; i++) {
    if (failed !== undefined) throw failed;
    const chainId = await chainIdAt(url);
    if (chainId !== undefined) {
      // Something answers; it is ours only if our child is still alive and reports the chain id it was given.
      if (failed !== undefined) throw failed;
      if (chainId === `0x${ANVIL_CHAIN_ID.toString(16)}`) return { url, stop: () => void child.kill() };
      child.kill();
      throw new Error(`the node at ${url} reports chain id ${chainId}, not the anvil this harness started`);
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  child.kill();
  throw new Error(`anvil did not start at ${bin}: ${stderr.trim()}`);
}

export const anvilChain = defineChain({
  id: ANVIL_CHAIN_ID,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

export function account(index: number): LocalAccount {
  return mnemonicToAccount(MNEMONIC, { addressIndex: index });
}

export function clients(url: string) {
  const chain = { ...anvilChain, rpcUrls: { default: { http: [url] } } };
  const publicClient = createPublicClient({ chain, transport: http(url), pollingInterval: 100 });
  const testClient = createTestClient({ chain, mode: "anvil", transport: http(url) });
  const wallet = (acct: LocalAccount) => createWalletClient({ account: acct, chain, transport: http(url) });
  return { publicClient, testClient, wallet };
}

export interface Deployment {
  registry: Address;
  executor: Address;
  token: Address;
}

type Wallet = ReturnType<ReturnType<typeof clients>["wallet"]>;
type Public = ReturnType<typeof clients>["publicClient"];

/** The registry takes the future executor address, so the executor is deployed at deployer nonce + 1. */
export async function deploy(publicClient: Public, deployer: Wallet): Promise<Deployment> {
  const reg = artifact("SpendGrantRegistry.sol", "SpendGrantRegistry");
  const exe = artifact("SpendGrantAuthorizationExecutor.sol", "SpendGrantAuthorizationExecutor");
  const tok = artifact("MockERC20.sol", "MockERC20");
  const from = deployer.account.address;

  const send = async (hash: Hex) => {
    const r = await publicClient.waitForTransactionReceipt({ hash });
    if (r.status !== "success" || r.contractAddress == null) throw new Error("deploy failed");
    return getAddress(r.contractAddress);
  };

  const token = await send(await deployer.deployContract({ abi: tok.abi, bytecode: tok.bytecode.object }));
  const nonce = await publicClient.getTransactionCount({ address: from });
  const executorAddress = getContractAddress({ from, nonce: BigInt(nonce + 1) });
  const registry = await send(
    await deployer.deployContract({ abi: reg.abi, bytecode: reg.bytecode.object, args: [executorAddress] }),
  );
  const executor = await send(
    await deployer.deployContract({ abi: exe.abi, bytecode: exe.bytecode.object, args: [registry] }),
  );
  if (executor.toLowerCase() !== executorAddress.toLowerCase()) throw new Error("executor address mismatch");
  return { registry, executor, token };
}
