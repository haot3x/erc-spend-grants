// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssetLimit, SpendGrant} from "../../src/SpendGrantTypes.sol";
import {SpendGrantHash} from "../../src/SpendGrantHash.sol";
import {SpendGrantExecutor} from "../../src/SpendGrantExecutor.sol";
import {SpendGrantRedemptionEnforcer} from "../../src/SpendGrantRedemptionEnforcer.sol";
import {MockDelegationManager} from "../SpendGrantRedemption.t.sol";

/// @dev Halmos properties of the redemption enforcer's write rule (`check_` prefix; forge test does not run
/// them). Run with `pnpm test:symbolic`. The rule is local to one hook call: whatever else runs in the
/// transaction, a record for the principal exists only if a hook wrote it, so proving the hook writes only
/// at the principal's root delegation proves no record is ever written anywhere else.
contract SpendGrantRecordSymbolic is Test {
    address internal constant EXECUTOR = address(0xE0E0);
    address internal constant REGISTRY = address(0xF0F0);
    address internal constant PRINCIPAL = address(0x1001);
    address internal constant RECIPIENT = address(0x1003);
    address internal constant ASSET = address(0x1004);

    MockDelegationManager internal manager;
    SpendGrantRedemptionEnforcer internal enforcer;

    function setUp() public {
        manager = new MockDelegationManager();
        enforcer = new SpendGrantRedemptionEnforcer(address(manager), EXECUTOR, REGISTRY);
    }

    /// The principal's hook, for any two-caveat delegation offered in args (this enforcer first, any enforcer
    /// second) and any hash the manager passes: if the principal's record is set afterwards, the args are the
    /// delegation the manager hashed, it is the root, it carries this caveat once, and the record names the redeemer.
    /// Keep the delegator a literal: with a symbolic delegator, even under vm.assume(delegator == PRINCIPAL), the
    /// record's slot is a symbolic hash, Halmos never observes the write, and this passes vacuously.
    /// SpendGrantRecordCanary asserts false in this write branch and must fail; `pnpm test:symbolic` checks that it
    /// does. check_otherDelegatorsNeverRecord covers another delegator. That the args' own delegator is the hooked one follows from the manager
    /// passing the true hash of the hooked delegation, not from this contract.
    function check_recordOnlyAtThePrincipalsRootDelegation(
        address redeemer,
        address argDelegate,
        address argDelegator,
        bytes32 argAuthority,
        uint256 argSalt,
        address otherEnforcer,
        bytes32 delegationHash
    ) public {
        address recorded =
            _hookPrincipal(redeemer, argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer, delegationHash);
        if (recorded != address(0)) {
            assert(
                manager.getDelegationHash(
                    _delegationOf(argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer)
                ) == delegationHash
            );
            assert(argAuthority == manager.ROOT_AUTHORITY());
            assert(otherEnforcer != address(enforcer));
            assert(recorded == redeemer);
        }
    }

    /// A hook for a delegator other than the principal writes nothing, even when the args are that delegator's own
    /// root delegation and match the hash: only the delegator check stands in the way. The delegator is a literal so
    /// both slots read here are concrete, and a write under either would show.
    function check_otherDelegatorsNeverRecord(address redeemer, address argDelegate, uint256 argSalt) public {
        address other = address(0x2002);
        MockDelegationManager.Delegation memory d =
            _delegationOf(argDelegate, other, manager.ROOT_AUTHORITY(), argSalt, address(0));
        bytes32 delegationHash = manager.getDelegationHash(d);
        vm.prank(address(manager));
        (bool ok,) = address(enforcer).call(
            abi.encodeCall(
                enforcer.beforeHook, ("", abi.encode(d), bytes32(0), _execution(), delegationHash, other, redeemer)
            )
        );
        ok;
        assert(enforcer.recorded(other, _grantHash(), ASSET, 1, RECIPIENT) == address(0));
        assert(enforcer.recorded(PRINCIPAL, _grantHash(), ASSET, 1, RECIPIENT) == address(0));
    }

    /// The principal's hook with no args reverts and writes nothing.
    function check_emptyArgsRevertForThePrincipal(address redeemer, bytes32 delegationHash) public {
        vm.prank(address(manager));
        (bool ok,) = address(enforcer).call(
            abi.encodeCall(enforcer.beforeHook, ("", "", bytes32(0), _execution(), delegationHash, PRINCIPAL, redeemer))
        );
        assert(!ok);
        assert(enforcer.recorded(PRINCIPAL, _grantHash(), ASSET, 1, RECIPIENT) == address(0));
    }

    function _hookPrincipal(
        address redeemer,
        address argDelegate,
        address argDelegator,
        bytes32 argAuthority,
        uint256 argSalt,
        address otherEnforcer,
        bytes32 delegationHash
    ) internal returns (address) {
        MockDelegationManager.Delegation memory d =
            _delegationOf(argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer);
        vm.prank(address(manager));
        (bool ok,) = address(enforcer).call(
            abi.encodeCall(
                enforcer.beforeHook, ("", abi.encode(d), bytes32(0), _execution(), delegationHash, PRINCIPAL, redeemer)
            )
        );
        ok;
        return enforcer.recorded(PRINCIPAL, _grantHash(), ASSET, 1, RECIPIENT);
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

    /// Not vacuous: at the principal's root delegation, shown by its own args and hash, the record is written
    /// and names the redeemer, for any redeemer, delegate, and salt.
    function check_rootDelegationRecords(address redeemer, address argDelegate, uint256 argSalt) public {
        vm.assume(redeemer != address(0));
        MockDelegationManager.Delegation memory d;
        d.delegate = argDelegate;
        d.delegator = PRINCIPAL;
        d.authority = manager.ROOT_AUTHORITY();
        d.salt = argSalt;
        d.caveats = new MockDelegationManager.Caveat[](1);
        d.caveats[0] = MockDelegationManager.Caveat(address(enforcer), "", "");
        bytes32 delegationHash = manager.getDelegationHash(d);

        vm.prank(address(manager));
        enforcer.beforeHook("", abi.encode(d), bytes32(0), _execution(), delegationHash, PRINCIPAL, redeemer);
        assert(enforcer.recorded(PRINCIPAL, _grantHash(), ASSET, 1, RECIPIENT) == redeemer);
    }

    function _grant() internal pure returns (SpendGrant memory m) {
        m.principal = PRINCIPAL;
        m.delegate = address(0x1002);
        m.recipientMode = 0;
        m.recipient = RECIPIENT;
        m.windowSeconds = 86400;
        m.validAfter = 0;
        m.validUntil = 2 ** 40;
        m.salt = 1;
        m.assets = new AssetLimit[](1);
        m.assets[0] = AssetLimit(ASSET, 1, 1, 1);
    }

    function _grantHash() internal view returns (bytes32) {
        return SpendGrantHash.digest(block.chainid, REGISTRY, _grant());
    }

    function _execution() internal pure returns (bytes memory) {
        return abi.encodePacked(
            EXECUTOR, uint256(0), abi.encodeCall(SpendGrantExecutor.spend, (_grant(), "", ASSET, 1, RECIPIENT))
        );
    }
}
