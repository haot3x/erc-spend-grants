// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssetLimit, ISpendGrantRegistry, NATIVE, Reason, SpendGrant} from "../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../src/SpendGrantRegistry.sol";

/// @dev Exposes the registry's internal helpers to the symbolic checks.
contract SymbolicRegistry is SpendGrantRegistry {
    constructor(address executor_) SpendGrantRegistry(executor_) {}

    function live(uint64 stamped, uint64 windowSeconds) external view returns (bool) {
        return _live(stamped, windowSeconds);
    }

    function pack(uint64 time, uint256 amount) external pure returns (uint256) {
        return _pack(time, amount);
    }

    function unpack(uint256 word) external pure returns (uint64 time, uint256 amount) {
        return _unpack(word);
    }

    /// @dev Steps 9-12 and the write for NATIVE under `grantId`, with the caps passed in. The window is the one
    /// the grant was registered with.
    function debitDirect(bytes32 grantId, AssetLimit memory limit, uint256 amount) external {
        _debit(grantId, limit, NATIVE, amount);
    }
}

/// @dev Has code, so it passes the asset code check (step 8). Never called.
contract CodeAsset {}

/// @dev Halmos properties (`check_` prefix; forge test does not run them). Run with `pnpm test:symbolic`.
/// Every grant is registered in setUp under literal parties, so every id and storage slot a check reads is
/// concrete: with a symbolic party the slots become symbolic hashes, writes go unobserved, and a property can pass
/// vacuously (see SpendGrantRecordSymbolic). This contract is the registry's executor.
contract SpendGrantSymbolic is Test {
    bytes4 internal constant SPEND_GRANT_ERROR = bytes4(keccak256("SpendGrantError(uint8)"));
    uint256 internal constant STEPS = 2;
    uint64 internal constant WINDOW = 3600;
    uint64 internal constant VALID_AFTER = 1_700_000_000;
    uint64 internal constant VALID_UNTIL = 1_800_000_000;

    address internal constant PRINCIPAL = address(0xA11CE);
    address internal constant DELEGATE = address(0xB0B);
    address internal constant DELEGATE2 = address(0xB0B2);
    address internal constant STRANGER = address(0x5757);
    address internal constant PAYEE = address(0xC0C);
    /// Listed, without code: fails step 8.
    address internal constant NO_CODE = address(0xC0DE);
    /// Listed, holding an EIP-7702 delegation designator: fails step 8.
    address internal constant DESIGNATED = address(0x7702);
    /// Never listed: fails step 7.
    address internal constant UNLISTED = address(0xD00D);
    bytes32 internal constant UNKNOWN = keccak256("unknown grant");

    SymbolicRegistry internal registry;
    address internal codeAsset;

    /// Open recipient, NATIVE (1e18, 5e18, 10e18), window WINDOW; the delegate is DELEGATE (or DELEGATE2 for
    /// `grant2`). The debit checks debit `grant`'s id directly.
    bytes32 internal grant;
    bytes32 internal grant2;
    /// For check_checkMatchesConsume: a fixed payee, an open recipient with two earlier debits of `codeAsset`,
    /// and a revoked grant, each listing `codeAsset`, NO_CODE, DESIGNATED and NATIVE.
    bytes32 internal fixedGrant;
    bytes32 internal openGrant;
    bytes32 internal revokedGrant;

    function setUp() public {
        registry = new SymbolicRegistry(address(this));
        codeAsset = address(new CodeAsset());
        vm.etch(DESIGNATED, abi.encodePacked(hex"ef0100", address(0x1234)));

        AssetLimit[] memory native = new AssetLimit[](1);
        native[0] = AssetLimit(NATIVE, 1e18, 5e18, 10e18);
        grant = _register(_terms(DELEGATE, 1, address(0), native, 1));
        grant2 = _register(_terms(DELEGATE2, 1, address(0), native, 2));

        AssetLimit[] memory four = _fourAssets();
        fixedGrant = _register(_terms(DELEGATE, 0, PAYEE, four, 3));
        openGrant = _register(_terms(DELEGATE, 1, address(0), four, 4));
        revokedGrant = _register(_terms(DELEGATE, 1, address(0), four, 5));
        vm.prank(PRINCIPAL);
        registry.revoke(revokedGrant);

        // openGrant: 100 at VALID_AFTER and 50 at VALID_AFTER + 1000 of codeAsset, whose caps are (100, 150, 200):
        // depending on the time, the window holds 150, 50 or 0 and the lifetime has 50 left.
        vm.warp(VALID_AFTER);
        registry.consume(openGrant, DELEGATE, codeAsset, 100, PAYEE);
        vm.warp(VALID_AFTER + 1000);
        registry.consume(openGrant, DELEGATE, codeAsset, 50, PAYEE);
    }

    /// The code's liveness test equals the spec's primary form for every time, stamp, and window.
    function check_liveMatchesSpec(uint64 stamped, uint64 windowSeconds, uint64 ts) public {
        vm.warp(ts);
        assertEq(registry.live(stamped, windowSeconds), uint256(ts) < uint256(stamped) + uint256(windowSeconds));
    }

    /// Packing a debit word loses nothing for any timestamp and any 192-bit amount.
    function check_packRoundTrip(uint64 time, uint192 amount) public view {
        (uint64 t, uint256 a) = registry.unpack(registry.pack(time, amount));
        assertEq(t, time);
        assertEq(a, uint256(amount));
    }

    /// Over any short sequence of spends and time steps, a debit of the registered grant is accepted exactly
    /// when the spec's caps allow it (computed in exact arithmetic), reverts with the spec's reason when they do
    /// not, and the rolling and lifetime views equal the model afterward.
    struct Model {
        uint64[STEPS] times;
        uint256[STEPS] amounts;
        uint256 n;
        uint256 lifetime;
        uint64 now_;
    }

    /// Time steps are drawn from the expiry boundary (0, window - 1, window, window + 1);
    /// `check_liveMatchesSpec` covers the liveness arithmetic for every value. Amounts and caps
    /// are full 256-bit values; the Bitwuzla solver finishes this where Z3 and Yices time out.
    function check_debitSequenceMatchesModel(
        uint256 maxPerCall,
        uint256 maxPerWindow,
        uint256 maxTotal,
        uint256[STEPS] memory amounts,
        uint8[STEPS] memory gaps
    ) public {
        vm.assume(maxPerCall > 0 && maxPerCall <= maxPerWindow && maxPerWindow <= maxTotal);
        AssetLimit memory limit = AssetLimit(NATIVE, maxPerCall, maxPerWindow, maxTotal);

        Model memory m;
        m.now_ = 1_700_000_000;
        for (uint256 k = 0; k < STEPS; k++) {
            uint8 g = gaps[k];
            vm.assume(g < 4);
            m.now_ += g == 0 ? 0 : g == 1 ? WINDOW - 1 : g == 2 ? WINDOW : WINDOW + 1;
            vm.warp(m.now_);
            _step(m, limit, WINDOW, amounts[k]);
        }
    }

    /// At full 256-bit width, a single debit is accepted exactly when the spec's caps allow it
    /// in exact arithmetic, and otherwise reverts with the spec's reason.
    function check_debitMatchesCapsFullWidth(uint256 maxPerCall, uint256 maxPerWindow, uint256 maxTotal, uint256 amount)
        public
    {
        vm.assume(maxPerCall > 0 && maxPerCall <= maxPerWindow && maxPerWindow <= maxTotal);
        Model memory m;
        m.now_ = 1_700_000_000;
        vm.warp(m.now_);
        _step(m, AssetLimit(NATIVE, maxPerCall, maxPerWindow, maxTotal), WINDOW, amount);
    }

    function _step(Model memory m, AssetLimit memory limit, uint64 windowSeconds, uint256 amount) internal {
        uint256 windowSum = _windowSum(m, windowSeconds);

        Reason expected = Reason.OK;
        if (amount == 0 || amount > limit.maxPerCall || amount > type(uint192).max) {
            expected = Reason.OVER_TX_CAP;
        } else if (_exceeds(windowSum, amount, limit.maxPerWindow)) {
            expected = Reason.OVER_WINDOW_CAP;
        } else if (_exceeds(m.lifetime, amount, limit.maxTotal)) {
            expected = Reason.OVER_CUMULATIVE_CAP;
        }

        try registry.debitDirect(grant, limit, amount) {
            assertTrue(expected == Reason.OK);
            m.times[m.n] = m.now_;
            m.amounts[m.n] = amount;
            m.n++;
            m.lifetime += amount;
            windowSum += amount;
        } catch (bytes memory err) {
            assertTrue(expected != Reason.OK);
            assertEq(err, abi.encodeWithSelector(SPEND_GRANT_ERROR, uint8(expected)));
        }

        (uint256 spent,) = registry.usage(grant, NATIVE);
        (uint256 rolling,) = registry.rollingUsage(grant, NATIVE);
        assertEq(spent, m.lifetime);
        assertEq(rolling, windowSum);
        assertLe(rolling, limit.maxPerWindow);
        assertLe(spent, limit.maxTotal);
    }

    /// @dev The spec's primary liveness form, independent of the registry's `_live`.
    function _windowSum(Model memory m, uint64 windowSeconds) internal pure returns (uint256 sum) {
        for (uint256 i = 0; i < m.n; i++) {
            if (uint256(m.now_) < uint256(m.times[i]) + uint256(windowSeconds)) sum += m.amounts[i];
        }
    }

    /// Once the principal revokes a grant, no consume succeeds, whatever the amount, recipient or time: inside the
    /// validity window it reverts REVOKED, outside it NOT_YET_VALID or EXPIRED.
    function check_revokedGrantNeverConsumes(uint256 amount, address recipient, uint256 ts) public {
        vm.prank(PRINCIPAL);
        // A revert here would end every path before an assertion and pass vacuously.
        try registry.revoke(grant) {}
        catch {
            assert(false);
        }
        vm.warp(ts);
        uint8 expected = ts < VALID_AFTER ? 3 : ts >= VALID_UNTIL ? 4 : 5;
        try registry.consume(grant, DELEGATE, NATIVE, amount, recipient) {
            assertTrue(false);
        } catch (bytes memory err) {
            assertEq(err, _err(expected));
        }
    }

    /// No caller other than the executor can record a debit, for any grant id and any authorizer it claims.
    function check_onlyExecutorConsumes(
        address caller,
        bytes32 grantId,
        address authorizer,
        uint256 amount,
        address recipient
    ) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        try registry.consume(grantId, authorizer, NATIVE, amount, recipient) {
            assertTrue(false);
        } catch (bytes memory err) {
            assertEq(err, _err(12));
        }
    }

    /// For either of two registered grants with different delegates, no authorizer other than that grant's
    /// delegate can record a debit, even when the executor calls, at any time. The check precedes the validity,
    /// revocation, payee and cap checks, so it holds whatever they would say.
    function check_onlyDelegateAuthorizes(
        bool second,
        address authorizer,
        uint256 amount,
        address recipient,
        uint256 ts
    ) public {
        bytes32 grantId = second ? grant2 : grant;
        vm.assume(authorizer != (second ? DELEGATE2 : DELEGATE));
        vm.warp(ts);
        try registry.consume(grantId, authorizer, NATIVE, amount, recipient) {
            assertTrue(false);
        } catch (bytes memory err) {
            assertEq(err, _err(13));
        }
    }

    /// Non-vacuity witness for check_onlyDelegateAuthorizes: when the executor (this test contract)
    /// passes the grant's delegate as authorizer, the debit is recorded.
    function check_delegateAuthorizes(uint256 amount, address recipient) public {
        vm.assume(amount > 0 && amount <= 1e18);
        // The payee rules reject these five; an open-recipient grant accepts every other recipient.
        vm.assume(
            recipient != address(0) && recipient != PRINCIPAL && recipient != address(registry)
                && recipient != address(this) && recipient != NATIVE
        );
        vm.warp(VALID_AFTER);
        try registry.consume(grant, DELEGATE, NATIVE, amount, recipient) {
            (uint256 spent, uint256 calls) = registry.usage(grant, NATIVE);
            assertEq(spent, amount);
            assertEq(calls, 1);
        } catch {
            assertTrue(false);
        }
    }

    /// No payee of zero, the principal, the registry, the executor, or the spent asset is ever recorded, whatever the amount.
    function check_rejectedPayeesNeverConsume(uint256 amount, uint8 which) public {
        vm.assume(which < 5);
        // A branch rather than an array index: Halmos cannot read memory at a symbolic offset.
        address payee = which == 0
            ? address(0)
            : which == 1 ? PRINCIPAL : which == 2 ? address(registry) : which == 3 ? address(this) : NATIVE;
        vm.warp(VALID_AFTER);
        try registry.consume(grant, DELEGATE, NATIVE, amount, payee) {
            assertTrue(false);
        } catch (bytes memory err) {
            assertEq(err, _err(7));
        }
    }

    /// P-EQ: `check` returns OK exactly when `consume`, called by the executor in the same state, succeeds, and
    /// otherwise `consume` reverts with exactly `SpendGrantError(uint8)` carrying check's reason. Over any time,
    /// amount and recipient; the grant from {fixed payee, open recipient with earlier debits, revoked, unknown};
    /// the authorizer from {delegate, stranger}; the asset from {listed with code, NATIVE, listed without code,
    /// listed EIP-7702 designator, unlisted}. SpendGrantCheckCanary shows the OK branch is reached.
    function check_checkMatchesConsume(
        uint8 grantPick,
        bool byStranger,
        uint8 assetPick,
        uint256 amount,
        address recipient,
        uint256 ts
    ) public {
        (bool checkRan, bool ok, uint8 reason, bool success, bytes memory ret) =
            _checkThenConsume(grantPick, byStranger, assetPick, amount, recipient, ts);
        assertTrue(checkRan);
        assertEq(ok, reason == 0);
        assertEq(success, ok);
        if (success) {
            assertEq(ret.length, 0);
        } else {
            assertEq(ret, abi.encodeWithSelector(SPEND_GRANT_ERROR, reason));
        }
    }

    /// @dev check, then consume as the executor, on the same state and inputs. `check` is called low-level and
    /// its words decoded by hand, so a revert or an out-of-range value shows as `checkRan == false` instead of
    /// ending the path before any assertion.
    function _checkThenConsume(
        uint8 grantPick,
        bool byStranger,
        uint8 assetPick,
        uint256 amount,
        address recipient,
        uint256 ts
    ) internal returns (bool checkRan, bool ok, uint8 reason, bool success, bytes memory ret) {
        vm.assume(grantPick < 4 && assetPick < 5);
        // Branches rather than array indexes: Halmos cannot read memory at a symbolic offset.
        bytes32 grantId =
            grantPick == 0 ? fixedGrant : grantPick == 1 ? openGrant : grantPick == 2 ? revokedGrant : UNKNOWN;
        address asset = assetPick == 0
            ? codeAsset
            : assetPick == 1 ? NATIVE : assetPick == 2 ? NO_CODE : assetPick == 3 ? DESIGNATED : UNLISTED;
        address authorizer = byStranger ? STRANGER : DELEGATE;
        vm.warp(ts);
        (bool called, bytes memory out) = address(registry).staticcall(
            abi.encodeCall(ISpendGrantRegistry.check, (grantId, authorizer, asset, amount, recipient))
        );
        if (called && out.length == 64) {
            (uint256 okWord, uint256 reasonWord) = abi.decode(out, (uint256, uint256));
            checkRan = okWord <= 1 && reasonWord <= 14;
            ok = okWord == 1;
            reason = uint8(reasonWord);
        }
        (success, ret) = address(registry).call(
            abi.encodeCall(ISpendGrantRegistry.consume, (grantId, authorizer, asset, amount, recipient))
        );
    }

    /// @dev `used + amount > cap` in exact (257-bit) arithmetic.
    function _exceeds(uint256 used, uint256 amount, uint256 cap) internal pure returns (bool) {
        unchecked {
            uint256 sum = used + amount;
            return sum < used || sum > cap;
        }
    }

    /// `SpendGrantError(uint8)` carrying the literal reason number.
    function _err(uint8 reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SPEND_GRANT_ERROR, reason);
    }

    function _terms(address delegate, uint8 mode, address recipient, AssetLimit[] memory assets, uint256 salt)
        internal
        pure
        returns (SpendGrant memory g)
    {
        g.principal = PRINCIPAL;
        g.delegate = delegate;
        g.recipientMode = mode;
        g.recipient = recipient;
        g.windowSeconds = WINDOW;
        g.validAfter = VALID_AFTER;
        g.validUntil = VALID_UNTIL;
        g.salt = salt;
        g.assets = assets;
    }

    function _register(SpendGrant memory g) internal returns (bytes32 id) {
        vm.prank(PRINCIPAL);
        id = registry.register(g);
    }

    /// codeAsset, NO_CODE, DESIGNATED and NATIVE, ascending, as a grant must list them.
    function _fourAssets() internal view returns (AssetLimit[] memory list) {
        list = new AssetLimit[](4);
        list[0] = AssetLimit(codeAsset, 100, 150, 200);
        list[1] = AssetLimit(NO_CODE, 100, 150, 200);
        list[2] = AssetLimit(DESIGNATED, 100, 150, 200);
        list[3] = AssetLimit(NATIVE, 1e18, 5e18, 10e18);
        for (uint256 i = 1; i < 4; i++) {
            for (uint256 j = i; j > 0 && uint160(list[j].asset) < uint160(list[j - 1].asset); j--) {
                (list[j], list[j - 1]) = (list[j - 1], list[j]);
            }
        }
    }
}
