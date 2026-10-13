// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssetLimit, IERC1271, SpendGrant} from "../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../src/SpendGrantRegistry.sol";
import {SpendGrantExecutor} from "../../src/SpendGrantExecutor.sol";
import {SpendGrantRedemptionEnforcer} from "../../src/SpendGrantRedemptionEnforcer.sol";
import {SpendGrantRedemptionExecutor} from "../../src/SpendGrantRedemptionExecutor.sol";
import {MockERC20} from "../MockERC20.sol";
import {EvilDelegator} from "../SpendGrantRedemption.t.sol";

/// @dev The parts of MetaMask's DelegationManager that the tests call.
interface IDelegationManager {
    struct Caveat {
        address enforcer;
        bytes terms;
        bytes args;
    }

    struct Delegation {
        address delegate;
        address delegator;
        bytes32 authority;
        Caveat[] caveats;
        uint256 salt;
        bytes signature;
    }

    function paused() external view returns (bool);
    function ANY_DELEGATE() external view returns (address);
    function ROOT_AUTHORITY() external view returns (bytes32);
    function getDomainHash() external view returns (bytes32);
    function getDelegationHash(Delegation calldata delegation) external pure returns (bytes32);
    function redeemDelegations(
        bytes[] calldata permissionContexts,
        bytes32[] calldata modes,
        bytes[] calldata executionCalldatas
    ) external;
}

/// @dev The least a delegator account needs for the real manager to drive it: ERC-1271 for its delegation
/// signatures, and executeFromExecutor with the return shape the manager decodes.
contract ForkDeleGator {
    error NotManager();
    error UnsupportedMode();

    address internal immutable MANAGER;
    address internal immutable OWNER;

    constructor(address manager_, address owner_) {
        MANAGER = manager_;
        OWNER = owner_;
    }

    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData)
    {
        if (msg.sender != MANAGER) revert NotManager();
        if (mode[0] != 0x00 || mode[1] != 0x00) revert UnsupportedMode();
        address target = address(bytes20(executionCalldata[:20]));
        uint256 value = uint256(bytes32(executionCalldata[20:52]));
        (bool ok, bytes memory ret) = target.call{value: value}(executionCalldata[52:]);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        returnData = new bytes[](1);
        returnData[0] = ret;
    }

    function isValidSignature(bytes32 hash_, bytes calldata sig) external view returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        address signer = ecrecover(hash_, uint8(sig[64]), bytes32(sig[:32]), bytes32(sig[32:64]));
        return signer == OWNER ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
    }
}

/// @dev Sits on a delegation and, at one chosen hook, tries to spend again: it redeems a caveat-free delegation
/// from the principal whose execution is the same spend, and catches whatever that does.
contract ForkRecordThief {
    IDelegationManager internal immutable MANAGER;
    bool internal inBefore;
    bool public struck;
    bool public nestedSpent;
    bytes public nestedError;
    bytes internal nestedContext;
    bytes internal nestedExecution;

    constructor(IDelegationManager manager_) {
        MANAGER = manager_;
    }

    function arm(bool inBefore_, bytes memory context, bytes memory execution) external {
        (inBefore, struck, nestedSpent, nestedContext, nestedExecution) = (inBefore_, false, false, context, execution);
        nestedError = "";
    }

    function beforeAllHook(bytes calldata, bytes calldata, bytes32, bytes calldata, bytes32, address, address)
        external
    {}

    function afterAllHook(bytes calldata, bytes calldata, bytes32, bytes calldata, bytes32, address, address)
        external
    {}

    function beforeHook(bytes calldata, bytes calldata, bytes32, bytes calldata, bytes32, address, address) external {
        if (inBefore) _strike();
    }

    function afterHook(bytes calldata, bytes calldata, bytes32, bytes calldata, bytes32, address, address) external {
        if (!inBefore) _strike();
    }

    function _strike() internal {
        if (struck) return;
        struck = true;
        bytes[] memory contexts = new bytes[](1);
        contexts[0] = nestedContext;
        bytes32[] memory modes = new bytes32[](1);
        bytes[] memory executions = new bytes[](1);
        executions[0] = nestedExecution;
        try MANAGER.redeemDelegations(contexts, modes, executions) {
            nestedSpent = true;
        } catch (bytes memory err) {
            nestedError = err;
        }
    }
}

/// @notice Drives the redemption enforcer and executor through MetaMask's DelegationManager v1.3.0 as
/// deployed on Arc testnet, instead of the mock manager the unit tests use. It confirms the mock's three
/// assumptions on the real contract: the caller of redeemDelegations is what the hooks see as redeemer,
/// the root delegation's delegator performs the execution, and each beforeHook runs right before its
/// own execution. It proves this for that manager only; another ERC-7710 manager may differ.
/// @dev Needs a network. Run with `pnpm test:fork`; without FORK_TESTS=true the suite is skipped so
/// `pnpm check` stays offline. Lives under test/fork so the ERC bundle, which must run offline, omits it.
contract SpendGrantRedemptionForkTest is Test {
    IDelegationManager internal constant MANAGER = IDelegationManager(0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3);

    uint256 internal constant OWNER_PK = 0xA11CE;
    uint256 internal constant DELEGATE_PK = 0xB0B;

    SpendGrantRegistry internal registry;
    SpendGrantRedemptionEnforcer internal enforcer;
    SpendGrantRedemptionExecutor internal executor;
    MockERC20 internal token;
    ForkDeleGator internal principalAccount;

    address internal delegate;
    address internal subDelegate;
    address internal recipient;
    address internal stranger;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("arc_testnet");
        assertGt(address(MANAGER).code.length, 0, "no manager at the MetaMask address on this chain");
        assertFalse(MANAGER.paused(), "manager is paused");

        delegate = vm.addr(DELEGATE_PK);
        subDelegate = vm.addr(0x5AB);
        recipient = vm.addr(0xC0C);
        stranger = vm.addr(0xBAD);

        token = new MockERC20();
        uint64 nonce = vm.getNonce(address(this));
        address predictedExecutor = vm.computeCreateAddress(address(this), nonce + 2);
        registry = new SpendGrantRegistry(predictedExecutor);
        enforcer = new SpendGrantRedemptionEnforcer(address(MANAGER), predictedExecutor, address(registry));
        executor = new SpendGrantRedemptionExecutor(registry, enforcer);
        assertEq(address(executor), predictedExecutor);

        principalAccount = new ForkDeleGator(address(MANAGER), vm.addr(OWNER_PK));
        token.mint(address(principalAccount), 1e24);
        vm.prank(address(principalAccount));
        token.approve(address(executor), type(uint256).max);
    }

    function test_fork_delegateRedemptionSpends() public {
        bytes32 id = _register(_grant());
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](1);
        chain[0] = _signedByAccount(_root(delegate, true));

        vm.prank(delegate);
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(_execution(id, 1e18, recipient)));

        assertEq(token.balanceOf(recipient), 1e18);
        (uint256 spent, uint256 calls) = registry.usage(id, address(token));
        assertEq(spent, 1e18);
        assertEq(calls, 1);
    }

    function test_fork_subDelegateRedemptionIsRejected() public {
        bytes32 id = _register(_grant());
        // Root: principal account -> delegate, carrying the caveat. Leaf: delegate -> subDelegate, with
        // the root's hash as its authority, signed by the delegate's key as the manager requires of an EOA.
        IDelegationManager.Delegation memory root = _signedByAccount(_root(delegate, true));
        IDelegationManager.Delegation memory leaf;
        leaf.delegate = subDelegate;
        leaf.delegator = delegate;
        leaf.authority = MANAGER.getDelegationHash(root);
        leaf.caveats = new IDelegationManager.Caveat[](0);
        leaf.signature = _signDelegation(DELEGATE_PK, leaf);
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](2);
        chain[0] = leaf;
        chain[1] = root;

        // The root's hook sees the sub-delegate as the redeemer, not the grant's delegate.
        vm.prank(subDelegate);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantRedemptionEnforcer.WrongRedeemer.selector));
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(_execution(id, 1e18, recipient)));
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_fork_openDelegationRevertsEvenForTheDelegate() public {
        // The principal's root open to any delegate, carrying the caveat, does not name the grant's delegate: the
        // hook reverts for the delegate and for anyone else.
        bytes32 id = _register(_grant());
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](1);
        chain[0] = _signedByAccount(_root(MANAGER.ANY_DELEGATE(), true));
        bytes memory execution = _execution(id, 1e18, recipient);

        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantRedemptionEnforcer.WrongDelegate.selector));
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(execution));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantRedemptionEnforcer.WrongDelegate.selector));
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(execution));
    }

    function test_fork_openDelegationByAPrincipalThatIsADelegateReverts() public {
        // The money-path review's FC-1 on the live manager. The principal's account has its own grant and is also
        // the delegate of Q's grant, which Q registered without it. It signs a delegation open to any delegate that
        // carries the caveat. A stranger redeems it for Q's grant; under the earlier rule the hook was inert there
        // and the account's call reached the executor as Q's delegate's direct call. The hook now reverts: the
        // delegator is not Q's principal.
        _register(_grant());
        address q = vm.addr(0x0A0);
        token.mint(q, 1e24);
        vm.prank(q);
        token.approve(address(executor), type(uint256).max);
        SpendGrant memory m = _grant();
        m.principal = q;
        m.delegate = address(principalAccount);
        m.recipientMode = 1;
        m.recipient = address(0);
        bytes32 qId = _register(m);
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](1);
        chain[0] = _signedByAccount(_root(MANAGER.ANY_DELEGATE(), true));
        bytes memory execution = _execution(qId, 1e18, stranger);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantRedemptionEnforcer.WrongDelegator.selector));
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(execution));
    }

    function test_fork_hostileIntermediaryCannotRideTheRedemption() public {
        // The review's High, replayed on the real manager inside a chain the rule accepts: the principal's root to the
        // delegate carries the caveat, the delegate delegates to a middle delegator, that delegator delegates back to
        // the delegate with itself as the enforcer, and the delegate redeems. From its beforeHook, before the root's
        // hook writes the record, or its afterHook, after the execution took it, the middle delegator calls the
        // executor with the same spend, as neither the grant's principal nor its delegate: the executor refuses that
        // call itself (13), before it asks the enforcer for any record, and the whole redemption reverts with the
        // middle delegator's StrikeRefused carrying that refusal.
        for (uint256 variant = 0; variant < 2; variant++) {
            EvilDelegator evil = new EvilDelegator(executor, variant == 0);
            SpendGrant memory m = _grant();
            m.salt = 100 + variant;
            bytes32 id = _register(m);

            IDelegationManager.Delegation memory root = _signedByAccount(_root(delegate, true));
            IDelegationManager.Delegation memory middle;
            middle.delegate = address(evil);
            middle.delegator = delegate;
            middle.authority = MANAGER.getDelegationHash(root);
            middle.caveats = new IDelegationManager.Caveat[](0);
            middle.signature = _signDelegation(DELEGATE_PK, middle);
            IDelegationManager.Delegation memory leaf;
            leaf.delegate = delegate;
            leaf.delegator = address(evil);
            leaf.authority = MANAGER.getDelegationHash(middle);
            leaf.caveats = new IDelegationManager.Caveat[](1);
            leaf.caveats[0] = IDelegationManager.Caveat(address(evil), "", "");
            leaf.signature = hex"00"; // evil's ERC-1271 accepts anything
            IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](3);
            chain[0] = leaf;
            chain[1] = middle;
            chain[2] = root;

            vm.expectCall(address(enforcer), abi.encodeWithSelector(enforcer.take.selector, address(evil)), 0);
            // In the afterHook variant the principal's execution took the record once before evil struck, so the same
            // prefix with the principal's account matches a real call.
            if (variant == 1) {
                vm.expectCall(
                    address(enforcer), abi.encodeWithSelector(enforcer.take.selector, address(principalAccount)), 1
                );
            }
            bytes memory redeem = abi.encodeCall(
                IDelegationManager.redeemDelegations,
                (_one(abi.encode(chain)), _one(bytes32(0)), _one(_execution(id, 1e18, recipient)))
            );
            vm.prank(delegate);
            (bool ok, bytes memory ret) = address(MANAGER).call(redeem);
            assertFalse(ok);
            assertEq(
                ret,
                abi.encodeWithSelector(
                    EvilDelegator.StrikeRefused.selector,
                    abi.encodeWithSelector(bytes4(keccak256("SpendGrantError(uint8)")), uint8(13))
                )
            );
            assertEq(token.balanceOf(recipient), 0);
            (uint256 spent, uint256 calls) = registry.usage(id, address(token));
            assertEq(spent, 0);
            assertEq(calls, 0);
            assertEq(enforcer.recorded(address(principalAccount), id, address(token), 1e18, recipient), address(0));
        }
    }

    function test_fork_loopThroughAnotherAccountPays() public {
        // The principal's root to the delegate carries the caveat, the delegate delegates to another account, that
        // account delegates back to the delegate, and the delegate redeems. The enforcer checks the root delegation
        // and the redeemer, not the hops between, so on the live manager too this pays once and leaves no record.
        uint256 otherPk = 0x7777;
        address other = vm.addr(otherPk);
        bytes32 id = _register(_grant());
        IDelegationManager.Delegation memory root = _signedByAccount(_root(delegate, true));
        IDelegationManager.Delegation memory middle;
        middle.delegate = other;
        middle.delegator = delegate;
        middle.authority = MANAGER.getDelegationHash(root);
        middle.caveats = new IDelegationManager.Caveat[](0);
        middle.signature = _signDelegation(DELEGATE_PK, middle);
        IDelegationManager.Delegation memory leaf;
        leaf.delegate = delegate;
        leaf.delegator = other;
        leaf.authority = MANAGER.getDelegationHash(middle);
        leaf.caveats = new IDelegationManager.Caveat[](0);
        leaf.signature = _signDelegation(otherPk, leaf);
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](3);
        chain[0] = leaf;
        chain[1] = middle;
        chain[2] = root;

        vm.prank(delegate);
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(_execution(id, 1e18, recipient)));

        assertEq(token.balanceOf(recipient), 1e18);
        assertEq(token.balanceOf(address(principalAccount)), 1e24 - 1e18);
        (uint256 spent, uint256 calls) = registry.usage(id, address(token));
        assertEq(spent, 1e18);
        assertEq(calls, 1);
        assertEq(enforcer.recorded(address(principalAccount), id, address(token), 1e18, recipient), address(0));
    }

    function test_fork_identicalEntriesInOneBatchBothSpend() public {
        // Two identical entries share one record key, which has no counter. The manager runs each entry's
        // hooks around its own execution, so the first entry's record is taken and cleared before the second
        // is written, and both spend. Nothing in the enforcer or executor enforces that order.
        bytes32 id = _register(_grant());
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](1);
        chain[0] = _signedByAccount(_root(delegate, true));

        vm.prank(delegate);
        MANAGER.redeemDelegations(_two(abi.encode(chain)), _two(bytes32(0)), _two(_execution(id, 1e18, recipient)));

        assertEq(token.balanceOf(recipient), 2e18);
        (uint256 spent, uint256 calls) = registry.usage(id, address(token));
        assertEq(spent, 2e18);
        assertEq(calls, 2);
    }

    function test_fork_principalBelowTheRootReverts() public {
        // The finding that led to the root-only rule, replayed on the live manager: the delegate's own account
        // is the root delegator, so the principal's delegation, which carries the caveat, is a lower one. Its
        // hook runs first and reverts, so nothing is recorded and nothing is paid.
        ForkDeleGator delegateAccount = new ForkDeleGator(address(MANAGER), vm.addr(DELEGATE_PK));
        SpendGrant memory m = _grant();
        m.delegate = address(delegateAccount);
        bytes32 id = _register(m);
        bytes memory execution = _execution(id, 1e18, recipient);

        IDelegationManager.Delegation memory root;
        root.delegate = address(principalAccount);
        root.delegator = address(delegateAccount);
        root.authority = MANAGER.ROOT_AUTHORITY();
        root.caveats = new IDelegationManager.Caveat[](0);
        root.signature = _signDelegation(DELEGATE_PK, root);
        IDelegationManager.Delegation memory lower;
        lower.delegate = address(delegateAccount);
        lower.delegator = address(principalAccount);
        lower.authority = MANAGER.getDelegationHash(root);
        lower.caveats = new IDelegationManager.Caveat[](1);
        lower.caveats[0] = IDelegationManager.Caveat(address(enforcer), "", "");
        lower = _signedByAccount(lower);
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](2);
        chain[0] = lower;
        chain[1] = root;

        vm.prank(address(delegateAccount));
        vm.expectRevert(abi.encodeWithSelector(SpendGrantRedemptionEnforcer.NotRoot.selector));
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(execution));
    }

    function test_fork_rootCarryingTheCaveatTwiceReverts() public {
        // A thief between two copies of the caveat on the principal's root could take the first record before the
        // second copy writes it again; a root that carries the caveat twice is rejected outright.
        bytes memory execution = _execution(_register(_grant()), 1e18, recipient);
        ForkRecordThief thief = new ForkRecordThief(MANAGER);
        IDelegationManager.Delegation memory root = _root(delegate, true);
        IDelegationManager.Caveat[] memory caveats = new IDelegationManager.Caveat[](3);
        caveats[0] = root.caveats[0];
        caveats[1] = IDelegationManager.Caveat(address(thief), "", "");
        caveats[2] = IDelegationManager.Caveat(address(enforcer), "", "");
        root.caveats = caveats;
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](1);
        chain[0] = _signedByAccount(root);
        IDelegationManager.Delegation[] memory nested = new IDelegationManager.Delegation[](1);
        nested[0] = _signedByAccount(_root(address(thief), false));
        thief.arm(true, abi.encode(nested), execution);

        vm.prank(delegate);
        vm.expectRevert(SpendGrantRedemptionEnforcer.CaveatNotOnce.selector);
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(execution));
    }

    function test_fork_delegationCarryingTheCaveatCannotRideTheRecord() public {
        // A thief after the caveat on the principal's root redeems a delegation from the principal to itself that
        // also carries the caveat. With args that delegation names the thief, not the grant's delegate, and
        // reverts; without them it reverts too. Either way the delegate's record is untouched: one payment.
        for (uint256 run = 0; run < 2; run++) {
            uint256 snap = vm.snapshotState();
            bytes32 id = _register(_grant());
            bytes memory execution = _execution(id, 1e18, recipient);
            ForkRecordThief thief = new ForkRecordThief(MANAGER);
            IDelegationManager.Delegation memory root = _root(delegate, true);
            IDelegationManager.Caveat[] memory caveats = new IDelegationManager.Caveat[](2);
            caveats[0] = root.caveats[0];
            caveats[1] = IDelegationManager.Caveat(address(thief), "", "");
            root.caveats = caveats;
            IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](1);
            chain[0] = _signedByAccount(root);

            IDelegationManager.Delegation[] memory nested = new IDelegationManager.Delegation[](1);
            nested[0] = _signedByAccount(_root(address(thief), true));
            if (run == 1) nested[0].caveats[0].args = "";
            thief.arm(true, abi.encode(nested), execution);

            vm.prank(delegate);
            MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(execution));

            assertTrue(thief.struck());
            assertFalse(thief.nestedSpent());
            // With args the thief's delegation names the thief rather than the grant's delegate; without them it
            // cannot show it is the root.
            assertEq(
                thief.nestedError(),
                run == 0
                    ? abi.encodeWithSelector(SpendGrantRedemptionEnforcer.WrongDelegate.selector)
                    : abi.encodeWithSelector(SpendGrantRedemptionEnforcer.MissingDelegation.selector)
            );
            (uint256 spent, uint256 calls) = registry.usage(id, address(token));
            assertEq(calls, 1);
            assertEq(spent, 1e18);
            vm.revertToState(snap);
        }
    }

    function test_fork_unknownGrantIdIsNonexistent() public {
        // The delegate redeems the principal's root, which carries the caveat, for a spend of an id the registry
        // does not know. On the live manager too, the hook neither records nor reverts, so the execution runs, and
        // the redemption reverts with the executor's NONEXISTENT (14), not with any error of the enforcer's.
        SpendGrant memory m = _grant();
        _register(m);
        m.salt = 2;
        bytes32 unknown = registry.hashGrant(m);
        (address unknownPrincipal,) = registry.parties(unknown);
        assertEq(unknownPrincipal, address(0), "the unknown id is registered");
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](1);
        chain[0] = _signedByAccount(_root(delegate, true));
        bytes memory execution = _execution(unknown, 1e18, recipient);

        vm.prank(delegate);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("SpendGrantError(uint8)")), uint8(14)));
        MANAGER.redeemDelegations(_one(abi.encode(chain)), _one(bytes32(0)), _one(execution));
    }

    // ---------------------------------------------------------------- helpers

    function _grant() internal view returns (SpendGrant memory m) {
        m.principal = address(principalAccount);
        m.delegate = delegate;
        m.recipientMode = 0;
        m.recipient = recipient;
        m.assetCombine = 0;
        m.windowSeconds = 86400;
        m.validAfter = 0;
        m.validUntil = type(uint64).max;
        m.salt = 1;
        m.assets = new AssetLimit[](1);
        m.assets[0] = AssetLimit(address(token), 1e18, 10e18, 100e18);
    }

    /// @dev Registers the terms from their principal, the DeleGator account, as `register` requires; returns the id.
    function _register(SpendGrant memory m) internal returns (bytes32 id) {
        vm.prank(m.principal);
        id = registry.register(m);
    }

    /// @dev ERC-7579 single execution targeting the executor's `spend(grantId, asset, amount, recipient)`.
    function _execution(bytes32 id, uint256 amount, address to) internal view returns (bytes memory) {
        return abi.encodePacked(
            address(executor), uint256(0), abi.encodeCall(SpendGrantExecutor.spend, (id, address(token), amount, to))
        );
    }

    /// @dev A root delegation from the principal account, unsigned.
    function _root(address delegate_, bool withCaveat) internal view returns (IDelegationManager.Delegation memory d) {
        d.delegate = delegate_;
        d.delegator = address(principalAccount);
        d.authority = MANAGER.ROOT_AUTHORITY();
        d.caveats = new IDelegationManager.Caveat[](withCaveat ? 1 : 0);
        if (withCaveat) d.caveats[0] = IDelegationManager.Caveat(address(enforcer), "", "");
        d.salt = 0;
    }

    /// @dev Signs with the account owner's key; the manager validates it through the account's ERC-1271.
    function _signedByAccount(IDelegationManager.Delegation memory d)
        internal
        view
        returns (IDelegationManager.Delegation memory)
    {
        d.signature = _signDelegation(OWNER_PK, d);
        return _withEnforcerArgs(d);
    }

    /// @dev Puts the delegation into the args of its SpendGrant caveats, so the enforcer can check that it is
    /// the root. Args are not part of the delegation hash, so the signature still holds.
    function _withEnforcerArgs(IDelegationManager.Delegation memory d)
        internal
        view
        returns (IDelegationManager.Delegation memory)
    {
        bytes memory signature = d.signature;
        d.signature = ""; // not part of the hash, so not needed in args
        for (uint256 c = 0; c < d.caveats.length; c++) {
            if (d.caveats[c].enforcer == address(enforcer)) d.caveats[c].args = "";
        }
        bytes memory self = abi.encode(d);
        d.signature = signature;
        for (uint256 c = 0; c < d.caveats.length; c++) {
            if (d.caveats[c].enforcer == address(enforcer)) d.caveats[c].args = self;
        }
        return d;
    }

    /// @dev The manager's own typed-data digest, read from the live contract rather than recomputed.
    function _signDelegation(uint256 pk, IDelegationManager.Delegation memory d) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", MANAGER.getDomainHash(), MANAGER.getDelegationHash(d)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _one(bytes memory item) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = item;
    }

    function _one(bytes32 item) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = item;
    }

    function _two(bytes memory item) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](2);
        arr[0] = item;
        arr[1] = item;
    }

    function _two(bytes32 item) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](2);
        arr[0] = item;
        arr[1] = item;
    }
}
