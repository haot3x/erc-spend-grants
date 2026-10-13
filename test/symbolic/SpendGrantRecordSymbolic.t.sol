// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssetLimit, SpendGrant} from "../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../src/SpendGrantRegistry.sol";
import {SpendGrantExecutor} from "../../src/SpendGrantExecutor.sol";
import {SpendGrantRedemptionEnforcer} from "../../src/SpendGrantRedemptionEnforcer.sol";
import {MockDelegationManager} from "../SpendGrantRedemption.t.sol";

/// @dev Halmos properties of the redemption enforcer's write rule (`check_` prefix; forge test does not run
/// them). Run with `pnpm test:symbolic`. The rule is local to one hook call: whatever else runs in the
/// transaction, a record for the principal exists only if a hook wrote it, so proving the hook writes only
/// at the principal's root delegation to the grant's delegate, redeemed by that delegate, proves no record is
/// ever written anywhere else.
///
/// The hook asks the registry for the grant's principal (`parties`), so setUp deploys a real registry and
/// registers the grant the properties spend. Against an address with no code that call reverts, every hook
/// reverts, the write branch is unreachable, and each property here would pass for that reason alone.
contract SpendGrantRecordSymbolic is Test {
    address internal constant EXECUTOR = address(0xE0E0);
    address internal constant PRINCIPAL = address(0x1001);
    address internal constant DELEGATE = address(0x1002);
    address internal constant RECIPIENT = address(0x1003);
    address internal constant ASSET = address(0x1004);
    /// @dev An id no registration in setUp assigns; a literal, so the record slots read for it are concrete.
    bytes32 internal constant UNREGISTERED = bytes32(uint256(0x0dd));

    MockDelegationManager internal manager;
    SpendGrantRegistry internal registry;
    SpendGrantRedemptionEnforcer internal enforcer;
    bytes32 internal grantId;

    function setUp() public {
        manager = new MockDelegationManager();
        registry = new SpendGrantRegistry(EXECUTOR);
        enforcer = new SpendGrantRedemptionEnforcer(address(manager), EXECUTOR, address(registry));
        vm.prank(PRINCIPAL);
        grantId = registry.register(_grant());
    }

    /// The principal's hook, for any two-caveat delegation offered in args (this enforcer first, any enforcer
    /// second), any hash the manager passes, and any redeemer: if it returns normally, the args are the delegation
    /// the manager hashed, it is the root, it names the grant's delegate, it carries this caveat once, the redeemer
    /// is the grant's delegate, and the principal's record names that redeemer; if it reverts, there is no record.
    /// Keep the delegator a literal: with a symbolic delegator, even under vm.assume(delegator == PRINCIPAL), the
    /// record's slot is a symbolic hash, Halmos never observes the write, and this passes vacuously.
    /// SpendGrantRecordCanary asserts false in this write branch and must fail; `pnpm test:symbolic` checks that it
    /// does. check_otherDelegatorsRevert covers every other delegator. That the args' own delegator is the hooked
    /// one follows from the manager passing the true hash of the hooked delegation, not from this contract.
    function check_recordOnlyAtThePrincipalsRootDelegation(
        address redeemer,
        address argDelegate,
        address argDelegator,
        bytes32 argAuthority,
        uint256 argSalt,
        address otherEnforcer,
        bytes32 delegationHash
    ) public {
        (bool ok, address recorded) =
            _hookPrincipal(redeemer, argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer, delegationHash);
        if (ok) {
            assert(
                manager.getDelegationHash(
                    _delegationOf(argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer)
                ) == delegationHash
            );
            assert(argAuthority == manager.ROOT_AUTHORITY());
            assert(argDelegate == DELEGATE);
            assert(otherEnforcer != address(enforcer));
            assert(redeemer == DELEGATE);
            assert(recorded == redeemer);
        } else {
            assert(recorded == address(0));
        }
    }

    /// A hook for any delegator but the principal reverts with WrongDelegator() and records nothing, for any
    /// two-caveat delegation in args, any hash, and any redeemer: so also for that delegator's own root delegation
    /// to the grant's delegate, matching the hash and redeemed by that delegate. The revert data is checked, so a
    /// hook that reverted for another reason would not pass.
    function check_otherDelegatorsRevert(
        address delegator,
        address redeemer,
        address argDelegate,
        address argDelegator,
        bytes32 argAuthority,
        uint256 argSalt,
        address otherEnforcer,
        bytes32 delegationHash
    ) public {
        vm.assume(delegator != PRINCIPAL);
        bytes memory args = abi.encode(_delegationOf(argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer));
        vm.prank(address(manager));
        (bool ok, bytes memory ret) = address(enforcer).call(
            abi.encodeCall(
                enforcer.beforeHook, ("", args, bytes32(0), _execution(), delegationHash, delegator, redeemer)
            )
        );
        assert(!ok);
        assert(
            keccak256(ret) == keccak256(abi.encodeWithSelector(SpendGrantRedemptionEnforcer.WrongDelegator.selector))
        );
        assert(enforcer.recorded(PRINCIPAL, grantId, ASSET, 1, RECIPIENT) == address(0));
    }

    /// The principal's hook with no args reverts with MissingDelegation() and writes nothing.
    function check_emptyArgsRevertForThePrincipal(address redeemer, bytes32 delegationHash) public {
        vm.prank(address(manager));
        (bool ok, bytes memory ret) = address(enforcer).call(
            abi.encodeCall(enforcer.beforeHook, ("", "", bytes32(0), _execution(), delegationHash, PRINCIPAL, redeemer))
        );
        assert(!ok);
        assert(
            keccak256(ret) == keccak256(abi.encodeWithSelector(SpendGrantRedemptionEnforcer.MissingDelegation.selector))
        );
        assert(enforcer.recorded(PRINCIPAL, grantId, ASSET, 1, RECIPIENT) == address(0));
    }

    /// An execution whose grant id the registry does not know: for the principal and for a zero delegator, with any
    /// delegation in args (inputs that, for the registered id, write the record or revert) or none, the hooks neither
    /// revert nor write.
    function check_unregisteredIdNeverRecordsNorReverts(
        address redeemer,
        address argDelegate,
        address argDelegator,
        bytes32 argAuthority,
        uint256 argSalt,
        address otherEnforcer,
        bytes32 delegationHash
    ) public {
        (address unknownPrincipal,) = registry.parties(UNREGISTERED);
        assert(unknownPrincipal == address(0));
        bytes memory args = abi.encode(_delegationOf(argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer));
        bytes memory execution = _executionFor(UNREGISTERED);
        assert(_hook(true, args, execution, delegationHash, PRINCIPAL, redeemer));
        assert(_hook(true, "", execution, delegationHash, PRINCIPAL, redeemer));
        assert(_hook(true, args, execution, delegationHash, address(0), redeemer));
        assert(_hook(true, "", execution, delegationHash, address(0), redeemer));
        assert(_hook(false, args, execution, delegationHash, PRINCIPAL, redeemer));
        assert(enforcer.recorded(PRINCIPAL, UNREGISTERED, ASSET, 1, RECIPIENT) == address(0));
        assert(enforcer.recorded(address(0), UNREGISTERED, ASSET, 1, RECIPIENT) == address(0));
        assert(enforcer.recorded(PRINCIPAL, grantId, ASSET, 1, RECIPIENT) == address(0));
    }

    function _hookPrincipal(
        address redeemer,
        address argDelegate,
        address argDelegator,
        bytes32 argAuthority,
        uint256 argSalt,
        address otherEnforcer,
        bytes32 delegationHash
    ) internal returns (bool ok, address recorded) {
        MockDelegationManager.Delegation memory d =
            _delegationOf(argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer);
        vm.prank(address(manager));
        (ok,) = address(enforcer).call(
            abi.encodeCall(
                enforcer.beforeHook, ("", abi.encode(d), bytes32(0), _execution(), delegationHash, PRINCIPAL, redeemer)
            )
        );
        recorded = enforcer.recorded(PRINCIPAL, grantId, ASSET, 1, RECIPIENT);
    }

    /// @dev Calls beforeHook (or afterHook) as the manager; true when it did not revert.
    function _hook(
        bool before,
        bytes memory args,
        bytes memory execution,
        bytes32 delegationHash,
        address delegator,
        address redeemer
    ) internal returns (bool ok) {
        bytes memory data = before
            ? abi.encodeCall(enforcer.beforeHook, ("", args, bytes32(0), execution, delegationHash, delegator, redeemer))
            : abi.encodeCall(enforcer.afterHook, ("", args, bytes32(0), execution, delegationHash, delegator, redeemer));
        vm.prank(address(manager));
        (ok,) = address(enforcer).call(data);
    }

    /// @dev This enforcer's caveat first; a second caveat when `otherEnforcer` is nonzero.
    function _delegationOf(
        address delegate_,
        address delegator_,
        bytes32 authority,
        uint256 salt,
        address otherEnforcer
    ) internal view returns (MockDelegationManager.Delegation memory d) {
        d.delegate = delegate_;
        d.delegator = delegator_;
        d.authority = authority;
        d.salt = salt;
        d.caveats = new MockDelegationManager.Caveat[](otherEnforcer == address(0) ? 1 : 2);
        d.caveats[0] = MockDelegationManager.Caveat(address(enforcer), "", "");
        if (otherEnforcer != address(0)) d.caveats[1] = MockDelegationManager.Caveat(otherEnforcer, "", "");
    }

    /// Not vacuous: at the principal's root delegation to the grant's delegate, shown by its own args and hash and
    /// redeemed by that delegate, the record is written and names the delegate, for any salt.
    function check_rootDelegationRecords(uint256 argSalt) public {
        MockDelegationManager.Delegation memory d;
        d.delegate = DELEGATE;
        d.delegator = PRINCIPAL;
        d.authority = manager.ROOT_AUTHORITY();
        d.salt = argSalt;
        d.caveats = new MockDelegationManager.Caveat[](1);
        d.caveats[0] = MockDelegationManager.Caveat(address(enforcer), "", "");
        bytes32 delegationHash = manager.getDelegationHash(d);

        vm.prank(address(manager));
        enforcer.beforeHook("", abi.encode(d), bytes32(0), _execution(), delegationHash, PRINCIPAL, DELEGATE);
        assert(enforcer.recorded(PRINCIPAL, grantId, ASSET, 1, RECIPIENT) == DELEGATE);
    }

    function _grant() internal pure returns (SpendGrant memory m) {
        m.principal = PRINCIPAL;
        m.delegate = DELEGATE;
        m.recipientMode = 0;
        m.recipient = RECIPIENT;
        m.windowSeconds = 86400;
        m.validAfter = 0;
        m.validUntil = 2 ** 40;
        m.salt = 1;
        m.assets = new AssetLimit[](1);
        m.assets[0] = AssetLimit(ASSET, 1, 1, 1);
    }

    /// @dev The spend the properties hook: the registered grant's id.
    function _execution() internal view returns (bytes memory) {
        return _executionFor(grantId);
    }

    function _executionFor(bytes32 id) internal pure returns (bytes memory) {
        return
            abi.encodePacked(EXECUTOR, uint256(0), abi.encodeCall(SpendGrantExecutor.spend, (id, ASSET, 1, RECIPIENT)));
    }
}
