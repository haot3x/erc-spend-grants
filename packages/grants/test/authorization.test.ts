import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  encodeAbiParameters,
  keccak256,
  recoverTypedDataAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

import {
  hashSpendAuthorizationTypedData,
  SPEND_AUTHORIZATION_DOMAIN_NAME,
  SPEND_AUTHORIZATION_DOMAIN_VERSION,
  SPEND_AUTHORIZATION_ENCODE_TYPE,
  SPEND_AUTHORIZATION_TYPEHASH,
  spendAuthorizationDomain,
  spendAuthorizationTypes,
  type SpendAuthorization,
} from "../src/index.js";

const VECTOR_PATH = resolve(
  fileURLToPath(new URL("../../../vectors/authorization-v1.json", import.meta.url)),
);

/** Anvil account 0. Evidence only; not a trusted deployment. */
const EOA_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const EOA = privateKeyToAccount(EOA_KEY);

const CHAIN_ID = 31337n;
const EXECUTOR = "0x5555555555555555555555555555555555555555" as Address;

const AUTHORIZATION: SpendAuthorization = {
  grantId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  asset: "0x00000000000000000000000000000000000000a0",
  amount: 123n,
  recipient: "0x3333333333333333333333333333333333333333",
  nonce: 7n,
  deadline: 1_800_000_000n,
};

interface AuthorizationVectorFile {
  version: number;
  encodeType: string;
  domain: { name: string; version: string };
  vectors: Array<{
    name: string;
    chainId: string;
    executor: string;
    authorization: Record<string, string>;
    domainSeparator: Hex;
    structHash: Hex;
    digest: Hex;
    signature: Hex;
    signer: Address;
  }>;
}

/** The struct hash built from the ERC's words alone, without the typed-data library. */
function independentStructHash(a: SpendAuthorization): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "bytes32" },
        { type: "bytes32" },
        { type: "address" },
        { type: "uint256" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint256" },
      ],
      [SPEND_AUTHORIZATION_TYPEHASH, a.grantId, a.asset, a.amount, a.recipient, a.nonce, a.deadline],
    ),
  );
}

describe("SpendAuthorization", () => {
  it("hashes the ERC's encodeType and reconstructs the digest independently", () => {
    expect(SPEND_AUTHORIZATION_ENCODE_TYPE).toBe(
      "SpendAuthorization(bytes32 grantId,address asset,uint256 amount,address recipient,uint256 nonce,uint256 deadline)",
    );
    // A literal, because the vector file is regenerated from this code.
    expect(SPEND_AUTHORIZATION_TYPEHASH).toBe(
      "0xbdf12719d33aac7ffdc784c8ba01d876726bb83eb404f021efe2df09f1077b4d",
    );
    const hashes = hashSpendAuthorizationTypedData({
      chainId: CHAIN_ID,
      executor: EXECUTOR,
      authorization: AUTHORIZATION,
    });
    expect(hashes.structHash).toBe(independentStructHash(AUTHORIZATION));
  });

  it("matches the golden vector, which it writes once", async () => {
    const domain = spendAuthorizationDomain({ chainId: CHAIN_ID, executor: EXECUTOR });
    const hashes = hashSpendAuthorizationTypedData({
      chainId: CHAIN_ID,
      executor: EXECUTOR,
      authorization: AUTHORIZATION,
    });
    // The domain did not change with the type, so its separator keeps the value the earlier vector recorded.
    expect(hashes.domainSeparator).toBe(
      "0xd7b8a05a0382a9f8cbfa8894f971e75d21d40ef83be94bea1847179acffef701",
    );
    const signature = await EOA.signTypedData({
      domain,
      types: spendAuthorizationTypes,
      primaryType: "SpendAuthorization",
      message: AUTHORIZATION,
    });
    const recovered = await recoverTypedDataAddress({
      domain,
      types: spendAuthorizationTypes,
      primaryType: "SpendAuthorization",
      message: AUTHORIZATION,
      signature,
    });
    expect(recovered.toLowerCase()).toBe(EOA.address.toLowerCase());

    const expected: AuthorizationVectorFile = {
      version: 1,
      encodeType: SPEND_AUTHORIZATION_ENCODE_TYPE,
      domain: { name: SPEND_AUTHORIZATION_DOMAIN_NAME, version: SPEND_AUTHORIZATION_DOMAIN_VERSION },
      vectors: [
        {
          name: "eoa-signed",
          chainId: CHAIN_ID.toString(),
          executor: EXECUTOR,
          authorization: {
            grantId: AUTHORIZATION.grantId,
            asset: AUTHORIZATION.asset,
            amount: AUTHORIZATION.amount.toString(),
            recipient: AUTHORIZATION.recipient,
            nonce: AUTHORIZATION.nonce.toString(),
            deadline: AUTHORIZATION.deadline.toString(),
          },
          domainSeparator: hashes.domainSeparator,
          structHash: hashes.structHash,
          digest: hashes.digest,
          signature,
          signer: EOA.address.toLowerCase() as Address,
        },
      ],
    };

    if (!existsSync(VECTOR_PATH)) {
      writeFileSync(VECTOR_PATH, `${JSON.stringify(expected, null, 2)}\n`);
    }
    const onDisk = JSON.parse(readFileSync(VECTOR_PATH, "utf8")) as AuthorizationVectorFile;
    expect(onDisk).toEqual(expected);
  });
});
