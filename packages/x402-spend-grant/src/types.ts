import type { Account, Address, Chain, Hex, PublicClient, Transport, WalletClient } from "viem";

export const SPEND_GRANT_SCHEME = "spend-grant";

/** An x402 v2 `accepts` entry. For this scheme `extra.executor` is the executor address. */
export interface PaymentRequirements {
  scheme: string;
  network: string;
  amount: string;
  asset: string;
  payTo: string;
  maxTimeoutSeconds: number;
  extra?: Record<string, unknown>;
}

/** The scheme payload in PAYMENT-SIGNATURE. `nonce` and `deadline` are decimal strings, like x402's `value`. */
export interface SpendGrantPayload {
  grantId: Hex;
  nonce: string;
  deadline: string;
  authorization: Hex;
}

export interface ResourceInfo {
  url: string;
  description?: string;
  mimeType?: string;
}

export interface PaymentPayload {
  x402Version: 2;
  resource?: ResourceInfo;
  accepted: PaymentRequirements;
  payload: SpendGrantPayload;
  extensions?: Record<string, unknown>;
}

export interface VerifyResponse {
  isValid: boolean;
  invalidReason?: string;
  payer?: string;
}

export interface SettlementResponse {
  success: boolean;
  errorReason?: string;
  payer?: string;
  transaction: string;
  network: string;
}

export interface SupportedResponse {
  kinds: { x402Version: 2; scheme: string; network: string }[];
  extensions: string[];
  signers: Record<string, string[]>;
}

/** What a facilitator needs: a chain to read and simulate on, an account to submit from, and the contracts. */
export interface FacilitatorContext {
  publicClient: PublicClient;
  walletClient: WalletClient<Transport, Chain | undefined, Account>;
  executor: Address;
  registry: Address;
  /** How long `settle` waits for the receipt, in milliseconds; viem's default when unset. */
  receiptTimeoutMs?: number;
}
