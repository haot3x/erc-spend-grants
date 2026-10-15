// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {AssetLimit, IERC1271, Reason, SpendGrant, SpendGrantError} from "../../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../../src/SpendGrantRegistry.sol";
import {SpendGrantAuthorizationExecutor} from "../../../src/SpendGrantAuthorizationExecutor.sol";
import {MockERC20} from "../../MockERC20.sol";

/// @dev The ERC-4337 v0.7 user operation.
struct PackedUserOperation {
    address sender;
    uint256 nonce;
    bytes initCode;
    bytes callData;
    bytes32 accountGasLimits; // verificationGasLimit << 128 | callGasLimit
    uint256 preVerificationGas;
    bytes32 gasFees; // maxPriorityFeePerGas << 128 | maxFeePerGas
    bytes paymasterAndData;
    bytes signature;
}

/// @dev The parts of EntryPoint v0.7 that the tests call.
interface IEntryPoint {
    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );
    event UserOperationRevertReason(
        bytes32 indexed userOpHash, address indexed sender, uint256 nonce, bytes revertReason
    );

    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function depositTo(address account) external payable;
    function balanceOf(address account) external view returns (uint256);
}

interface ISimpleAccountFactory {
    function createAccount(address owner, uint256 salt) external returns (address);
    function getAddress(address owner, uint256 salt) external view returns (address);
    function accountImplementation() external view returns (address);
}

interface ISimpleAccount {
    function execute(address dest, uint256 value, bytes calldata func) external;
    function owner() external view returns (address);
    function entryPoint() external view returns (address);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @dev The smallest paymaster that sponsors every operation: it validates nothing and returns no context, so the
/// EntryPoint never calls `postOp`, which it does not define. Its gas is paid from its deposit at the EntryPoint.
contract TestPaymaster {
    address internal immutable ENTRY_POINT;

    constructor(address entryPoint_) {
        ENTRY_POINT = entryPoint_;
    }

    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external
        view
        returns (bytes memory context, uint256 validationData)
    {
        require(msg.sender == ENTRY_POINT, "not the entry point");
        return ("", 0);
    }
}

/// @dev An eth-infinitism SimpleAccount v0.7 as the delegate of an ERC-8427 grant, through the EntryPoint, the
/// factory, and the ERC-8427 registry and executor deployed on Arc testnet. The account spends through its own
/// UserOperation, which a paymaster may sponsor even before the account exists. SimpleAccount v0.7 has no ERC-1271,
/// so a relayed spendWithAuthorization for it is rejected, whichever form its owner signs.
///
/// Needs a network. Run with `pnpm test:fork`; without FORK_TESTS=true the suite is skipped so `pnpm check` stays
/// offline. Under test/integrations, so the ERC bundle omits it. See README.md beside this file.
contract SpendGrant4337ForkTest is Test {
    IEntryPoint internal constant ENTRY_POINT = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032);
    ISimpleAccountFactory internal constant FACTORY = ISimpleAccountFactory(0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985);
    address internal constant ACCOUNT_IMPLEMENTATION = 0x68641DE71cfEa5a5d0D29712449Ee254bb1400C2;
    SpendGrantRegistry internal constant REGISTRY = SpendGrantRegistry(0xe8987A22a1e3fd4a63cB517A9476B9d214388287);
    SpendGrantAuthorizationExecutor internal constant EXECUTOR =
        SpendGrantAuthorizationExecutor(0xB99785329AbEc9936b6EF6350015be39D3392646);

    uint256 internal constant OWNER_PK = 0xB0B;
    uint256 internal constant ACCOUNT_SALT = 1;
    uint256 internal constant NEW_ACCOUNT_SALT = 2;
    uint128 internal constant VERIFICATION_GAS = 500_000;
    uint128 internal constant DEPLOY_VERIFICATION_GAS = 1_000_000;
    uint128 internal constant CALL_GAS = 500_000;
    uint256 internal constant PRE_VERIFICATION_GAS = 100_000;
    uint128 internal constant MAX_PRIORITY_FEE = 1 gwei;
    uint128 internal constant MAX_FEE = 10 gwei;
    uint128 internal constant PAYMASTER_VERIFICATION_GAS = 100_000;
    uint128 internal constant PAYMASTER_POST_OP_GAS = 50_000;
    uint256 internal constant AMOUNT = 3e6;

    MockERC20 internal usdc;
    TestPaymaster internal paymaster;
    ISimpleAccount internal account;
    address internal owner;
    address internal principal;
    address internal vendor;
    address internal bundler;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("arc_testnet");
        assertGt(address(ENTRY_POINT).code.length, 0, "no EntryPoint v0.7 on this chain");
        assertGt(address(FACTORY).code.length, 0, "no SimpleAccountFactory on this chain");
        assertEq(FACTORY.accountImplementation(), ACCOUNT_IMPLEMENTATION, "unexpected SimpleAccount implementation");
        assertEq(
            ISimpleAccount(ACCOUNT_IMPLEMENTATION).entryPoint(),
            address(ENTRY_POINT),
            "factory is not bound to EntryPoint v0.7"
        );
        assertEq(REGISTRY.executor(), address(EXECUTOR), "registry and executor do not match");

        owner = vm.addr(OWNER_PK);
        principal = makeAddr("principal");
        vendor = makeAddr("vendor");
        bundler = makeAddr("bundler");

        usdc = new MockERC20();
        usdc.mint(principal, 1_000e6);
        vm.prank(principal);
        usdc.approve(address(EXECUTOR), type(uint256).max);

        paymaster = new TestPaymaster(address(ENTRY_POINT));
        vm.deal(address(this), 10 ether);
        ENTRY_POINT.depositTo{value: 1 ether}(address(paymaster));

        account = ISimpleAccount(FACTORY.createAccount(owner, ACCOUNT_SALT));
        usdc.mint(address(account), 7e6);
    }

    // ---------------------------------------------------------------- the account spends

    /// A SimpleAccount that is the grant's delegate spends through its own UserOperation, and the principal pays.
    function test_accountSpendsThroughUserOperation() public {
        bytes32 id = _register(_grant(address(account), 1));
        vm.deal(address(account), 1 ether);
        assertEq(ENTRY_POINT.balanceOf(address(account)), 0);

        PackedUserOperation memory op = _signedOp(address(account), "", _spendCall(id), false, VERIFICATION_GAS);
        Outcome memory out = _handle(op);

        assertTrue(out.success);
        assertEq(out.paymaster, address(0));
        assertGt(out.actualGasCost, 0);
        // The account paid the prefund; the EntryPoint keeps the unused part as the account's deposit.
        assertEq(1 ether - address(account).balance - ENTRY_POINT.balanceOf(address(account)), out.actualGasCost);
        assertEq(usdc.balanceOf(vendor), AMOUNT);
        assertEq(usdc.balanceOf(principal), 1_000e6 - AMOUNT);
        assertEq(usdc.balanceOf(address(account)), 7e6);
        (uint256 spent,) = REGISTRY.usage(id, address(usdc));
        assertEq(spent, AMOUNT);
    }

    /// A paymaster sponsors an account that does not exist yet: the operation deploys it, spends, and the account
    /// holds neither gas, tokens, nor an EntryPoint deposit.
    function test_paymasterSponsorsCounterfactualAccount() public {
        address sender = FACTORY.getAddress(owner, NEW_ACCOUNT_SALT);
        bytes32 id = _register(_grant(sender, 1));
        bytes memory initCode =
            abi.encodePacked(address(FACTORY), abi.encodeCall(FACTORY.createAccount, (owner, NEW_ACCOUNT_SALT)));

        assertEq(sender.code.length, 0);
        assertEq(sender.balance, 0);
        assertEq(usdc.balanceOf(sender), 0);
        assertEq(ENTRY_POINT.balanceOf(sender), 0);
        uint256 depositBefore = ENTRY_POINT.balanceOf(address(paymaster));

        PackedUserOperation memory op = _signedOp(sender, initCode, _spendCall(id), true, DEPLOY_VERIFICATION_GAS);
        Outcome memory out = _handle(op);

        assertTrue(out.success);
        assertEq(out.paymaster, address(paymaster));
        assertGt(sender.code.length, 0);
        assertEq(ISimpleAccount(sender).owner(), owner);
        assertEq(usdc.balanceOf(vendor), AMOUNT);
        assertEq(usdc.balanceOf(principal), 1_000e6 - AMOUNT);
        assertEq(sender.balance, 0);
        assertEq(usdc.balanceOf(sender), 0);
        assertEq(ENTRY_POINT.balanceOf(sender), 0);
        assertGt(out.actualGasCost, 0);
        assertEq(depositBefore - ENTRY_POINT.balanceOf(address(paymaster)), out.actualGasCost);
    }

    // ---------------------------------------------------------------- the grant fails in execution

    /// A grant revoked after the operation was signed still passes validation, so the EntryPoint includes the
    /// operation, the spend reverts with the registry's reason, and the paymaster pays for it.
    function test_revokedGrantFailsInExecutionAndPaymasterPays() public {
        bytes32 id = _register(_grant(address(account), 1));
        PackedUserOperation memory op = _signedOp(address(account), "", _spendCall(id), true, VERIFICATION_GAS);

        vm.prank(principal);
        REGISTRY.revoke(id);

        _assertFailsInExecution(op, id, Reason.REVOKED);
    }

    /// A cap lowered after the operation was signed fails the same way, with the registry's cap reason.
    function test_cutCapFailsInExecutionAndPaymasterPays() public {
        SpendGrant memory terms = _grant(address(account), 1);
        bytes32 id = _register(terms);
        PackedUserOperation memory op = _signedOp(address(account), "", _spendCall(id), true, VERIFICATION_GAS);

        (, uint256 version,,,) = REGISTRY.getGrant(id);
        terms.assets[0] = AssetLimit(address(usdc), 2e6, 6e6, 100e6);
        vm.prank(principal);
        REGISTRY.update(id, version, terms);

        _assertFailsInExecution(op, id, Reason.OVER_TX_CAP);
    }

    /// A grant to the owner's key is not a grant to the account: the account's spend under it fails in execution.
    function test_grantToOwnerKeyFailsInExecution() public {
        bytes32 id = _register(_grant(owner, 1));
        PackedUserOperation memory op = _signedOp(address(account), "", _spendCall(id), true, VERIFICATION_GAS);
        _assertFailsInExecution(op, id, Reason.UNAUTHORIZED_DELEGATE);
    }

    /// `check` reports the reason a spend would revert with, so a delegate can ask before it sends.
    function test_checkReportsTheFailureBeforeSending() public {
        bytes32 id = _register(_grant(address(account), 1));
        (bool ok, Reason reason) = REGISTRY.check(id, address(account), address(usdc), AMOUNT, vendor);
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.OK));

        vm.prank(principal);
        REGISTRY.revoke(id);

        (ok, reason) = REGISTRY.check(id, address(account), address(usdc), AMOUNT, vendor);
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.REVOKED));
    }

    // ---------------------------------------------------------------- the account as a relayed delegate

    /// SimpleAccount v0.7 does not implement ERC-1271: it has no isValidSignature and no fallback, so the call
    /// reverts with no data.
    function test_simpleAccountHasNoErc1271() public {
        assertGt(address(account).code.length, 0);
        (bool ok, bytes memory ret) =
            address(account).staticcall(abi.encodeCall(IERC1271.isValidSignature, (keccak256("digest"), new bytes(65))));
        assertFalse(ok);
        assertEq(ret.length, 0);
        assertFalse(account.supportsInterface(IERC1271.isValidSignature.selector));
    }

    /// The owner's signature over the raw authorization digest does not authorize a relayed spend: the account has
    /// no ERC-1271 to vouch for it.
    function test_ownerSignedAuthorizationIsRejected() public {
        bytes32 id = _register(_grant(address(account), 1));
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 digest = EXECUTOR.authorizationDigest(id, address(usdc), AMOUNT, vendor, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        vm.prank(makeAddr("relayer"));
        vm.expectRevert(SpendGrantAuthorizationExecutor.BadAuthorization.selector);
        EXECUTOR.spendWithAuthorization(id, address(usdc), AMOUNT, vendor, 1, deadline, abi.encodePacked(r, s, v));
    }

    /// The owner's signature over the eth-signed-message form, which SimpleAccount accepts for a UserOperation,
    /// is rejected as well.
    function test_ownerSignedPrefixedAuthorizationIsRejected() public {
        bytes32 id = _register(_grant(address(account), 1));
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 digest = EXECUTOR.authorizationDigest(id, address(usdc), AMOUNT, vendor, 1, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, _ethSigned(digest));

        vm.prank(makeAddr("relayer"));
        vm.expectRevert(SpendGrantAuthorizationExecutor.BadAuthorization.selector);
        EXECUTOR.spendWithAuthorization(id, address(usdc), AMOUNT, vendor, 1, deadline, abi.encodePacked(r, s, v));
    }

    // ---------------------------------------------------------------- helpers

    struct Outcome {
        address paymaster;
        bool success;
        uint256 actualGasCost;
        bytes revertReason;
    }

    function _grant(address delegate, uint256 salt) internal view returns (SpendGrant memory m) {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        m.principal = principal;
        m.delegate = delegate;
        m.recipientMode = 0;
        m.recipient = vendor;
        m.assetCombine = 0;
        m.windowSeconds = 86400;
        m.validAfter = now_ - 60;
        m.validUntil = now_ + 30 days;
        m.salt = salt;
        m.assets = new AssetLimit[](1);
        m.assets[0] = AssetLimit(address(usdc), 5e6, 10e6, 100e6);
    }

    function _register(SpendGrant memory terms) internal returns (bytes32) {
        vm.prank(principal);
        return REGISTRY.register(terms);
    }

    /// The account's call into the executor, as the UserOperation's callData.
    function _spendCall(bytes32 id) internal view returns (bytes memory) {
        return abi.encodeCall(
            ISimpleAccount.execute,
            (address(EXECUTOR), 0, abi.encodeCall(EXECUTOR.spend, (id, address(usdc), AMOUNT, vendor)))
        );
    }

    /// A user operation signed by the owner over the eth-signed-message form of the EntryPoint's hash.
    function _signedOp(
        address sender,
        bytes memory initCode,
        bytes memory callData,
        bool sponsored,
        uint128 verificationGas
    ) internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = ENTRY_POINT.getNonce(sender, 0);
        op.initCode = initCode;
        op.callData = callData;
        op.accountGasLimits = bytes32((uint256(verificationGas) << 128) | CALL_GAS);
        op.preVerificationGas = PRE_VERIFICATION_GAS;
        op.gasFees = bytes32((uint256(MAX_PRIORITY_FEE) << 128) | MAX_FEE);
        if (sponsored) {
            op.paymasterAndData =
                abi.encodePacked(address(paymaster), PAYMASTER_VERIFICATION_GAS, PAYMASTER_POST_OP_GAS);
        }
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, _ethSigned(ENTRY_POINT.getUserOpHash(op)));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _ethSigned(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /// Submits `op` as a bundler would and reads the EntryPoint's events for it.
    function _handle(PackedUserOperation memory op) internal returns (Outcome memory out) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.recordLogs();
        vm.prank(bundler, bundler);
        ENTRY_POINT.handleOps(ops, payable(bundler));

        bytes32 opHash = ENTRY_POINT.getUserOpHash(op);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(ENTRY_POINT) || logs[i].topics.length < 3) continue;
            if (logs[i].topics[1] != opHash || logs[i].topics[2] != bytes32(uint256(uint160(op.sender)))) continue;
            uint256 nonce;
            if (logs[i].topics[0] == IEntryPoint.UserOperationEvent.selector) {
                out.paymaster = address(uint160(uint256(logs[i].topics[3])));
                (nonce, out.success, out.actualGasCost,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                found = true;
            } else if (logs[i].topics[0] == IEntryPoint.UserOperationRevertReason.selector) {
                (nonce, out.revertReason) = abi.decode(logs[i].data, (uint256, bytes));
            } else {
                continue;
            }
            assertEq(nonce, op.nonce);
        }
        assertTrue(found, "no UserOperationEvent");
    }

    /// `check` names `reason` beforehand; the sponsored `op` is then included, its spend reverts with that reason,
    /// nothing moves, and the paymaster pays.
    function _assertFailsInExecution(PackedUserOperation memory op, bytes32 id, Reason reason) internal {
        uint256 nonceBefore = ENTRY_POINT.getNonce(op.sender, 0);
        uint256 depositBefore = ENTRY_POINT.balanceOf(address(paymaster));
        (uint256 spentBefore, uint256 callsBefore) = REGISTRY.usage(id, address(usdc));
        (bool ok, Reason checked) = REGISTRY.check(id, op.sender, address(usdc), AMOUNT, vendor);
        assertFalse(ok);
        assertEq(uint8(checked), uint8(reason));

        Outcome memory out = _handle(op);

        assertFalse(out.success);
        assertEq(ENTRY_POINT.getNonce(op.sender, 0), nonceBefore + 1);
        assertEq(out.revertReason, abi.encodeWithSelector(SpendGrantError.selector, reason));
        assertEq(usdc.balanceOf(vendor), 0);
        assertEq(usdc.balanceOf(principal), 1_000e6);
        assertEq(usdc.balanceOf(address(account)), 7e6);
        (uint256 spent, uint256 calls) = REGISTRY.usage(id, address(usdc));
        assertEq(spent, spentBefore);
        assertEq(calls, callsBefore);
        assertGt(out.actualGasCost, 0);
        assertEq(depositBefore - ENTRY_POINT.balanceOf(address(paymaster)), out.actualGasCost);
    }
}
