// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    AssetLimit,
    GrantState,
    IERC1271,
    NotPrincipal,
    Reason,
    SpendGrant,
    SpendGrantError,
    StaleVersion
} from "../../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../../src/SpendGrantRegistry.sol";
import {SpendGrantAuthorizationExecutor} from "../../../src/SpendGrantAuthorizationExecutor.sol";
import {MockERC20} from "../../MockERC20.sol";

/// @dev The parts of Safe v1.4.1 that the tests call.
interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function nonce() external view returns (uint256);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes calldata initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ICompatibilityFallbackHandler {
    function getMessageHashForSafe(address safe, bytes calldata message) external view returns (bytes32);
}

interface ISignMessageLib {
    function signMessage(bytes calldata message) external;
}

interface IMultiSendCallOnly {
    function multiSend(bytes calldata transactions) external payable;
}

/// @dev A Safe as the principal and a Safe as the delegate, using Safe v1.4.1 and the ERC-8427 registry and
/// executor deployed on Arc testnet. A registered grant has no principal signature: the Safe's own transaction,
/// at its threshold, is what registers, updates, and revokes, so the Safe's call policy is the grant policy. ERC-1271
/// matters on the delegate side, where an agent Safe's owners sign the executor's SpendAuthorization.
///
/// Needs a network. Run with `pnpm test:fork`; without FORK_TESTS=true the suite is skipped so `pnpm check` stays
/// offline. Under test/integrations, so the ERC bundle omits it. See README.md beside this file.
contract SpendGrantSafeForkTest is Test {
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    ISafeProxyFactory internal constant SAFE_FACTORY = ISafeProxyFactory(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67);
    ICompatibilityFallbackHandler internal constant FALLBACK_HANDLER =
        ICompatibilityFallbackHandler(0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99);
    ISignMessageLib internal constant SIGN_MESSAGE_LIB = ISignMessageLib(0xd53cd0aB83D845Ac265BE939c57F53AD838012c9);
    IMultiSendCallOnly internal constant MULTI_SEND = IMultiSendCallOnly(0x9641d764fc13c8B624c04430C7356C1C7C8102e2);
    SpendGrantRegistry internal constant REGISTRY = SpendGrantRegistry(0xe8987A22a1e3fd4a63cB517A9476B9d214388287);
    SpendGrantAuthorizationExecutor internal constant EXECUTOR =
        SpendGrantAuthorizationExecutor(0xB99785329AbEc9936b6EF6350015be39D3392646);

    uint8 internal constant CALL = 0;
    uint8 internal constant DELEGATECALL = 1;
    uint256 internal constant AGENT_PK = 0xA6E;

    uint256[] internal treasuryKeys;
    uint256[] internal agentSafeKeys;

    MockERC20 internal usdc;
    ISafe internal treasury;
    ISafe internal agentSafe;
    address internal agent;
    address internal vendor;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("arc_testnet");
        assertGt(SAFE_SINGLETON.code.length, 0, "no Safe v1.4.1 singleton on this chain");
        assertEq(REGISTRY.executor(), address(EXECUTOR), "registry and executor do not match");

        treasuryKeys = [uint256(0x7E1), 0x7E2, 0x7E3];
        agentSafeKeys = [uint256(0xA51), 0xA52];
        // Per-run salts give each run fresh Safe addresses that nobody can pre-deploy on Arc.
        treasury = _deploySafe(treasuryKeys, 2, vm.randomUint(), address(FALLBACK_HANDLER));
        agentSafe = _deploySafe(agentSafeKeys, 2, vm.randomUint(), address(FALLBACK_HANDLER));
        agent = vm.addr(AGENT_PK);
        vendor = makeAddr("vendor");

        usdc = new MockERC20();
        usdc.mint(address(treasury), 1_000e6);
    }

    // ---------------------------------------------------------------- the Safe as principal

    /// One Safe transaction, batched through MultiSendCallOnly, approves the executor and registers the grant.
    function test_safeApprovesAndRegistersInOneTransaction() public {
        SpendGrant memory terms = _grant(agent, 1);
        bytes32 id = _approveAndRegister(terms);

        assertEq(id, REGISTRY.hashGrant(terms));
        (address principal, address delegate) = REGISTRY.parties(id);
        assertEq(principal, address(treasury));
        assertEq(delegate, agent);
        (bytes32[] memory ids, uint256 total) = REGISTRY.grantsOf(address(treasury), 0, 10);
        // The treasury address is fresh per run, so it has no other grants.
        assertEq(total, 1);
        assertEq(ids[0], id);

        GrantState memory s = REGISTRY.grantState(id, address(usdc));
        assertEq(uint8(s.status), uint8(Reason.OK));
        assertTrue(s.balanceKnown && s.allowanceKnown);
        assertEq(s.balance, 1_000e6);
        assertEq(s.spendableNow, 10e6);
    }

    /// The agent spends from the Safe directly, with no Safe transaction and no owner signature.
    function test_agentSpendsFromSafe() public {
        bytes32 id = _approveAndRegister(_grant(agent, 1));
        vm.prank(agent);
        EXECUTOR.spend(id, address(usdc), 4e6, vendor);
        assertEq(usdc.balanceOf(vendor), 4e6);
        assertEq(usdc.balanceOf(address(treasury)), 1_000e6 - 4e6);
    }

    /// An owner is not the principal: calling the registry from its own key fails, whatever the Safe's threshold.
    function test_ownerCannotRegisterForSafe() public {
        vm.prank(vm.addr(treasuryKeys[0]));
        vm.expectRevert(NotPrincipal.selector);
        REGISTRY.register(_grant(agent, 1));
    }

    /// Below the threshold the Safe does not call, so nothing is registered.
    function test_oneOwnerBelowThresholdRegistersNothing() public {
        SpendGrant memory terms = _grant(agent, 1);
        bytes memory data = abi.encodeCall(REGISTRY.register, (terms));
        uint256[] memory one = new uint256[](1);
        one[0] = treasuryKeys[0];
        bytes memory sigs = _signSafeTx(treasury, address(REGISTRY), data, CALL, one);
        vm.expectRevert(bytes("GS020"));
        treasury.execTransaction(address(REGISTRY), 0, data, CALL, 0, 0, 0, address(0), payable(0), sigs);

        (, uint256 total) = REGISTRY.grantsOf(address(treasury), 0, 10);
        assertEq(total, 0);
    }

    /// Lowering a cap is a Safe transaction at threshold, keeps usage, and applies to the next spend.
    function test_safeLowersCapInPlace() public {
        SpendGrant memory terms = _grant(agent, 1);
        bytes32 id = _approveAndRegister(terms);
        vm.prank(agent);
        EXECUTOR.spend(id, address(usdc), 4e6, vendor);

        (, uint256 version,,,) = REGISTRY.getGrant(id);
        terms.assets[0] = AssetLimit(address(usdc), 5e6, 6e6, 6e6);
        _exec(treasury, treasuryKeys, address(REGISTRY), abi.encodeCall(REGISTRY.update, (id, version, terms)));

        GrantState memory s = REGISTRY.grantState(id, address(usdc));
        assertEq(s.spent, 4e6);
        assertEq(s.spendableNow, 2e6);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.OVER_WINDOW_CAP));
        EXECUTOR.spend(id, address(usdc), 3e6, vendor);
    }

    /// A Safe transaction built from an older version cannot undo a newer update. Safe hides the reason as GS013;
    /// simulating the inner call shows it is StaleVersion, and the same terms succeed at the current version.
    function test_staleSafeUpdateFails() public {
        SpendGrant memory terms = _grant(agent, 1);
        bytes32 id = _approveAndRegister(terms);
        (, uint256 version,,,) = REGISTRY.getGrant(id);

        terms.assets[0] = AssetLimit(address(usdc), 5e6, 6e6, 6e6);
        _exec(treasury, treasuryKeys, address(REGISTRY), abi.encodeCall(REGISTRY.update, (id, version, terms)));

        SpendGrant memory older = _grant(agent, 1);
        bytes memory data = abi.encodeCall(REGISTRY.update, (id, version, older));

        vm.prank(address(treasury));
        vm.expectRevert(abi.encodeWithSelector(StaleVersion.selector, version + 1));
        REGISTRY.update(id, version, older);

        bytes memory sigs = _signSafeTx(treasury, address(REGISTRY), data, CALL, treasuryKeys);
        vm.expectRevert(bytes("GS013"));
        treasury.execTransaction(address(REGISTRY), 0, data, CALL, 0, 0, 0, address(0), payable(0), sigs);

        assertEq(REGISTRY.grantState(id, address(usdc)).maxTotal, 6e6);

        _exec(treasury, treasuryKeys, address(REGISTRY), abi.encodeCall(REGISTRY.update, (id, version + 1, older)));
        assertEq(REGISTRY.grantState(id, address(usdc)).maxTotal, MAX_TOTAL);
    }

    function test_safeRevokes() public {
        bytes32 id = _approveAndRegister(_grant(agent, 1));
        _exec(treasury, treasuryKeys, address(REGISTRY), abi.encodeCall(REGISTRY.revoke, (id)));
        assertTrue(REGISTRY.revoked(id));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.REVOKED));
        EXECUTOR.spend(id, address(usdc), 1e6, vendor);
    }

    // ---------------------------------------------------------------- a Safe as delegate

    /// The agent Safe's owners sign the authorization digest wrapped as a SafeMessage, which is what the Safe's
    /// ERC-1271 checks; a relayer submits it.
    function test_agentSafeAuthorizesWithSafeMessage() public {
        bytes32 id = _approveAndRegister(_grant(address(agentSafe), 1));
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 digest = EXECUTOR.authorizationDigest(id, address(usdc), 3e6, vendor, 1, deadline);
        bytes32 safeMessage = FALLBACK_HANDLER.getMessageHashForSafe(address(agentSafe), abi.encode(digest));

        vm.prank(makeAddr("relayer"));
        EXECUTOR.spendWithAuthorization(id, address(usdc), 3e6, vendor, 1, deadline, _sign(safeMessage, agentSafeKeys));
        assertEq(usdc.balanceOf(vendor), 3e6);
        assertTrue(EXECUTOR.nonceUsed(address(agentSafe), 1));
    }

    /// Owners that sign the raw digest, as they would for an EOA delegate, do not satisfy the Safe's ERC-1271.
    function test_agentSafeRejectsRawDigestSignatures() public {
        bytes32 id = _approveAndRegister(_grant(address(agentSafe), 1));
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 digest = EXECUTOR.authorizationDigest(id, address(usdc), 3e6, vendor, 1, deadline);

        bytes memory sigs = _sign(digest, agentSafeKeys);

        // The Safe's own ERC-1271 names the failure: the recovered signers are not owners.
        vm.expectRevert(bytes("GS026"));
        IERC1271(address(agentSafe)).isValidSignature(digest, sigs);

        vm.expectRevert(SpendGrantAuthorizationExecutor.BadAuthorization.selector);
        EXECUTOR.spendWithAuthorization(id, address(usdc), 3e6, vendor, 1, deadline, sigs);
    }

    /// An agent Safe with no fallback handler has no `isValidSignature`, so even correctly wrapped owner
    /// signatures are refused.
    function test_agentSafeWithoutFallbackHandlerIsRefused() public {
        ISafe bare = _deploySafe(agentSafeKeys, 2, vm.randomUint(), address(0));
        bytes32 id = _approveAndRegister(_grant(address(bare), 1));
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 digest = EXECUTOR.authorizationDigest(id, address(usdc), 3e6, vendor, 1, deadline);
        bytes32 safeMessage = FALLBACK_HANDLER.getMessageHashForSafe(address(bare), abi.encode(digest));

        vm.expectRevert(SpendGrantAuthorizationExecutor.BadAuthorization.selector);
        EXECUTOR.spendWithAuthorization(id, address(usdc), 3e6, vendor, 1, deadline, _sign(safeMessage, agentSafeKeys));
        assertEq(usdc.balanceOf(vendor), 0);
    }

    /// The agent Safe can approve a digest on chain: a threshold transaction delegatecalls SignMessageLib, and a
    /// relayer then submits the spend with an empty signature.
    function test_agentSafeApprovesDigestOnChain() public {
        bytes32 id = _approveAndRegister(_grant(address(agentSafe), 1));
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 digest = EXECUTOR.authorizationDigest(id, address(usdc), 3e6, vendor, 1, deadline);

        _execDelegate(
            agentSafe,
            agentSafeKeys,
            address(SIGN_MESSAGE_LIB),
            abi.encodeCall(ISignMessageLib.signMessage, (abi.encode(digest)))
        );

        vm.prank(makeAddr("relayer"));
        EXECUTOR.spendWithAuthorization(id, address(usdc), 3e6, vendor, 1, deadline, "");
        assertEq(usdc.balanceOf(vendor), 3e6);
        assertTrue(EXECUTOR.nonceUsed(address(agentSafe), 1));
    }

    /// The agent Safe's threshold applies to its authorizations: one of its two owners is not enough.
    function test_agentSafeThresholdApplies() public {
        bytes32 id = _approveAndRegister(_grant(address(agentSafe), 1));
        uint256 deadline = vm.getBlockTimestamp() + 600;
        bytes32 digest = EXECUTOR.authorizationDigest(id, address(usdc), 3e6, vendor, 1, deadline);
        bytes32 safeMessage = FALLBACK_HANDLER.getMessageHashForSafe(address(agentSafe), abi.encode(digest));
        uint256[] memory one = new uint256[](1);
        one[0] = agentSafeKeys[0];

        bytes memory sigs = _sign(safeMessage, one);

        // Safe's ERC-1271 reports the short signature as GS020.
        vm.expectRevert(bytes("GS020"));
        IERC1271(address(agentSafe)).isValidSignature(digest, sigs);

        vm.expectRevert(SpendGrantAuthorizationExecutor.BadAuthorization.selector);
        EXECUTOR.spendWithAuthorization(id, address(usdc), 3e6, vendor, 1, deadline, sigs);
    }

    // ---------------------------------------------------------------- helpers

    uint256 internal constant MAX_TOTAL = 100e6;

    function _grant(address delegate, uint256 salt) internal view returns (SpendGrant memory m) {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        m.principal = address(treasury);
        m.delegate = delegate;
        m.recipientMode = 0;
        m.recipient = vendor;
        m.assetCombine = 0;
        m.windowSeconds = 86400;
        m.validAfter = now_ - 60;
        m.validUntil = now_ + 30 days;
        m.salt = salt;
        m.assets = new AssetLimit[](1);
        m.assets[0] = AssetLimit(address(usdc), 5e6, 10e6, MAX_TOTAL);
    }

    function _approveAndRegister(SpendGrant memory terms) internal returns (bytes32 id) {
        // Approve exactly the grant's lifetime cap: the allowance, not the grant, bounds a misused Safe.
        bytes memory approve = abi.encodeCall(MockERC20.approve, (address(EXECUTOR), terms.assets[0].maxTotal));
        bytes memory register = abi.encodeCall(REGISTRY.register, (terms));
        bytes memory batch = abi.encodePacked(
            abi.encodePacked(CALL, address(usdc), uint256(0), approve.length, approve),
            abi.encodePacked(CALL, address(REGISTRY), uint256(0), register.length, register)
        );
        bytes memory data = abi.encodeCall(MULTI_SEND.multiSend, (batch));
        bytes memory sigs = _signSafeTx(treasury, address(MULTI_SEND), data, DELEGATECALL, treasuryKeys);
        assertTrue(
            treasury.execTransaction(address(MULTI_SEND), 0, data, DELEGATECALL, 0, 0, 0, address(0), payable(0), sigs)
        );
        id = REGISTRY.hashGrant(terms);
    }

    function _exec(ISafe safe, uint256[] memory keys, address to, bytes memory data) internal {
        bytes memory sigs = _signSafeTx(safe, to, data, CALL, keys);
        assertTrue(safe.execTransaction(to, 0, data, CALL, 0, 0, 0, address(0), payable(0), sigs));
    }

    function _execDelegate(ISafe safe, uint256[] memory keys, address to, bytes memory data) internal {
        bytes memory sigs = _signSafeTx(safe, to, data, DELEGATECALL, keys);
        assertTrue(safe.execTransaction(to, 0, data, DELEGATECALL, 0, 0, 0, address(0), payable(0), sigs));
    }

    function _signSafeTx(ISafe safe, address to, bytes memory data, uint8 operation, uint256[] memory keys)
        internal
        view
        returns (bytes memory)
    {
        bytes32 txHash = safe.getTransactionHash(to, 0, data, operation, 0, 0, 0, address(0), address(0), safe.nonce());
        return _sign(txHash, keys);
    }

    /// Owner signatures over `hash`, concatenated in ascending owner order as Safe requires.
    function _sign(bytes32 hash, uint256[] memory keys) internal pure returns (bytes memory sigs) {
        uint256[] memory sorted = _sortByAddress(keys);
        for (uint256 i; i < sorted.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(sorted[i], hash);
            sigs = abi.encodePacked(sigs, r, s, v);
        }
    }

    function _deploySafe(uint256[] memory keys, uint256 threshold, uint256 saltNonce, address handler)
        internal
        returns (ISafe)
    {
        uint256[] memory sorted = _sortByAddress(keys);
        address[] memory owners = new address[](sorted.length);
        for (uint256 i; i < sorted.length; i++) {
            owners[i] = vm.addr(sorted[i]);
        }
        bytes memory init =
            abi.encodeCall(ISafe.setup, (owners, threshold, address(0), "", handler, address(0), 0, payable(0)));
        return ISafe(SAFE_FACTORY.createProxyWithNonce(SAFE_SINGLETON, init, saltNonce));
    }

    function _sortByAddress(uint256[] memory keys) internal pure returns (uint256[] memory sorted) {
        sorted = new uint256[](keys.length);
        for (uint256 i; i < keys.length; i++) {
            sorted[i] = keys[i];
        }
        for (uint256 i = 1; i < sorted.length; i++) {
            for (uint256 j = i; j > 0 && vm.addr(sorted[j]) < vm.addr(sorted[j - 1]); j--) {
                (sorted[j], sorted[j - 1]) = (sorted[j - 1], sorted[j]);
            }
        }
    }
}
