import { getAddress, type Address, type Hex, type LocalAccount } from "viem";
import { SPEND_GRANT_SCHEME, type PaymentPayload, type PaymentRequirements, type ResourceInfo } from "./types.js";
import { BYTES32, isTimeout, isUint256, isValidAddress, parseUint } from "./validate.js";

/** The EIP-712 domain of the executor's `SpendAuthorization`. */
export function spendAuthorizationDomain(chainId: number | bigint, executor: Address) {
  return {
    name: "SpendAuthorization",
    version: "1",
    chainId: Number(chainId),
    verifyingContract: executor,
  } as const;
}

/** Must match the executor's AUTHORIZATION_TYPEHASH string. */
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

export function parseChainId(network: string): number | undefined {
  const m = /^eip155:(0|[1-9][0-9]*)$/.exec(network);
  if (m === null) return undefined;
  const id = Number(m[1]);
  return Number.isSafeInteger(id) ? id : undefined;
}

export interface CreatePaymentParams {
  requirements: PaymentRequirements;
  grantId: Hex;
  nonce: bigint;
  account: LocalAccount;
  /** Unix seconds the deadline counts from; defaults to the local clock. */
  now?: bigint;
  resource?: ResourceInfo;
}

/** The agent's answer to an `accepts` entry: a `SpendAuthorization` for exactly those terms. */
export async function createSpendGrantPayment(params: CreatePaymentParams): Promise<PaymentPayload> {
  const { requirements, grantId, nonce, account } = params;
  if (requirements.scheme !== SPEND_GRANT_SCHEME) {
    throw new Error(`unsupported scheme ${requirements.scheme}`);
  }
  const chainId = parseChainId(requirements.network);
  if (chainId === undefined) throw new Error(`network must be eip155:<id>, got ${requirements.network}`);
  const executor = requirements.extra?.["executor"];
  if (!isValidAddress(executor)) throw new Error("requirements.extra.executor must be the executor address");
  if (!isValidAddress(requirements.asset) || !isValidAddress(requirements.payTo)) {
    throw new Error("requirements.asset and requirements.payTo must be addresses");
  }
  const amount = parseUint(requirements.amount);
  if (amount === undefined) throw new Error("requirements.amount must be a decimal uint256 string");
  if (!isTimeout(requirements.maxTimeoutSeconds)) {
    throw new Error("requirements.maxTimeoutSeconds must be a non-negative safe integer");
  }
  if (!isUint256(nonce)) throw new Error("nonce must be a uint256");
  if (typeof grantId !== "string" || !BYTES32.test(grantId)) {
    throw new Error("grantId must be a 32-byte hex string");
  }
  const now = params.now ?? BigInt(Math.floor(Date.now() / 1000));
  const deadline = now + BigInt(requirements.maxTimeoutSeconds);
  if (!isUint256(deadline)) throw new Error("deadline must be a uint256");

  const authorization = await account.signTypedData({
    domain: spendAuthorizationDomain(chainId, getAddress(executor)),
    types: spendAuthorizationTypes,
    primaryType: "SpendAuthorization",
    message: {
      grantId,
      asset: getAddress(requirements.asset),
      amount,
      recipient: getAddress(requirements.payTo),
      nonce,
      deadline,
    },
  });

  return {
    x402Version: 2,
    ...(params.resource !== undefined ? { resource: params.resource } : {}),
    accepted: requirements,
    payload: { grantId, nonce: nonce.toString(), deadline: deadline.toString(), authorization },
  };
}
