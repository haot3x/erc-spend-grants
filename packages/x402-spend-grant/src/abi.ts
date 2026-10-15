const spendGrantErrorFragment = {
  type: "error",
  name: "SpendGrantError",
  inputs: [{ name: "reason", type: "uint8", internalType: "enum Reason" }],
} as const;

/** SpendGrantAuthorizationExecutor: the functions and errors the facilitator uses. */
export const spendGrantExecutorAbi = [
  {
    type: "function",
    name: "spendWithAuthorization",
    inputs: [
      { name: "grantId", type: "bytes32", internalType: "bytes32" },
      { name: "asset", type: "address", internalType: "address" },
      { name: "amount", type: "uint256", internalType: "uint256" },
      { name: "recipient", type: "address", internalType: "address" },
      { name: "nonce", type: "uint256", internalType: "uint256" },
      { name: "deadline", type: "uint256", internalType: "uint256" },
      { name: "authorization", type: "bytes", internalType: "bytes" },
    ],
    outputs: [],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "authorizationDigest",
    inputs: [
      { name: "grantId", type: "bytes32", internalType: "bytes32" },
      { name: "asset", type: "address", internalType: "address" },
      { name: "amount", type: "uint256", internalType: "uint256" },
      { name: "recipient", type: "address", internalType: "address" },
      { name: "nonce", type: "uint256", internalType: "uint256" },
      { name: "deadline", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "", type: "bytes32", internalType: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "domainSeparator",
    inputs: [],
    outputs: [{ name: "", type: "bytes32", internalType: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "nonceUsed",
    inputs: [
      { name: "authorizer", type: "address", internalType: "address" },
      { name: "nonce", type: "uint256", internalType: "uint256" },
    ],
    outputs: [{ name: "", type: "bool", internalType: "bool" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "cancelNonce",
    inputs: [{ name: "nonce", type: "uint256", internalType: "uint256" }],
    outputs: [],
    stateMutability: "nonpayable",
  },
  { type: "error", name: "AuthorizationExpired", inputs: [] },
  { type: "error", name: "BadAuthorization", inputs: [] },
  { type: "error", name: "NativeRequiresAccountAdapter", inputs: [] },
  { type: "error", name: "NonceAlreadyUsed", inputs: [] },
  { type: "error", name: "TransferFailed", inputs: [] },
  spendGrantErrorFragment,
] as const;

/** SpendGrantRegistry: `parties`, `grantState` and the errors its calls can raise. */
export const spendGrantRegistryAbi = [
  {
    type: "function",
    name: "parties",
    inputs: [{ name: "grantId", type: "bytes32", internalType: "bytes32" }],
    outputs: [
      { name: "principal", type: "address", internalType: "address" },
      { name: "delegate", type: "address", internalType: "address" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "grantState",
    inputs: [
      { name: "grantId", type: "bytes32", internalType: "bytes32" },
      { name: "asset", type: "address", internalType: "address" },
    ],
    outputs: [
      {
        name: "",
        type: "tuple",
        internalType: "struct GrantState",
        components: [
          { name: "status", type: "uint8", internalType: "enum Reason" },
          { name: "maxPerCall", type: "uint256", internalType: "uint256" },
          { name: "maxPerWindow", type: "uint256", internalType: "uint256" },
          { name: "maxTotal", type: "uint256", internalType: "uint256" },
          { name: "spent", type: "uint256", internalType: "uint256" },
          { name: "windowSpent", type: "uint256", internalType: "uint256" },
          { name: "liveDebits", type: "uint256", internalType: "uint256" },
          { name: "nextExpiry", type: "uint256", internalType: "uint256" },
          { name: "balance", type: "uint256", internalType: "uint256" },
          { name: "allowance", type: "uint256", internalType: "uint256" },
          { name: "balanceKnown", type: "bool", internalType: "bool" },
          { name: "allowanceKnown", type: "bool", internalType: "bool" },
          { name: "spendableNow", type: "uint256", internalType: "uint256" },
        ],
      },
    ],
    stateMutability: "view",
  },
  { type: "error", name: "FixedField", inputs: [] },
  {
    type: "error",
    name: "GrantExists",
    inputs: [{ name: "grantId", type: "bytes32", internalType: "bytes32" }],
  },
  {
    type: "error",
    name: "GrantIsRevoked",
    inputs: [{ name: "grantId", type: "bytes32", internalType: "bytes32" }],
  },
  { type: "error", name: "InsufficientGas", inputs: [] },
  { type: "error", name: "NotPrincipal", inputs: [] },
  spendGrantErrorFragment,
  {
    type: "error",
    name: "StaleVersion",
    inputs: [{ name: "currentVersion", type: "uint256", internalType: "uint256" }],
  },
  {
    type: "error",
    name: "UnknownGrant",
    inputs: [{ name: "grantId", type: "bytes32", internalType: "bytes32" }],
  },
  { type: "error", name: "ZeroExecutor", inputs: [] },
] as const;
