// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssetLimit, Reason, SpendGrant, SpendGrantError} from "../../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../../src/SpendGrantRegistry.sol";
import {SpendGrantExecutor} from "../../../src/SpendGrantExecutor.sol";
import {SpendGrantAuthorizationExecutor} from "../../../src/SpendGrantAuthorizationExecutor.sol";
import {MockERC20} from "../../MockERC20.sol";

/// @dev An x402 payment settled under a registered grant. The resource server's `accepts` entry names the asset,
/// amount, payTo and maxTimeoutSeconds; the agent (the grant's delegate) answers with a `SpendAuthorization` for
/// exactly those, and the facilitator settles it with `spendWithAuthorization`, so the principal pays and the agent
/// holds no funds. The facilitator is off chain: `_verify` is its simulated call and `_settle` its transaction, and
/// both map a failure to the same error code. See README.md beside this file.
contract SpendGrantX402Test is Test {
    uint256 internal constant DELEGATE_PK = 0xA6E;
    uint256 internal constant MAX_TIMEOUT = 60;

    /// The `accepts` entry the agent chose.
    struct Requirements {
        address asset;
        uint256 amount;
        address payTo;
        uint256 maxTimeoutSeconds;
    }

    /// The scheme payload in PAYMENT-SIGNATURE.
    struct Payment {
        bytes32 grantId;
        uint256 nonce;
        uint256 deadline;
        bytes authorization;
    }

    SpendGrantRegistry internal registry;
    SpendGrantAuthorizationExecutor internal executor;
    MockERC20 internal usdc;

    address internal principal;
    address internal agent;
    address internal facilitator;
    address internal serverA;
    address internal serverB;
    bytes32 internal grantId;

    function setUp() public {
        principal = makeAddr("treasury");
        agent = vm.addr(DELEGATE_PK);
        facilitator = makeAddr("facilitator");
        serverA = makeAddr("serverA");
        serverB = makeAddr("serverB");

        usdc = new MockERC20();
        uint64 nonce = vm.getNonce(address(this));
        registry = new SpendGrantRegistry(vm.computeCreateAddress(address(this), nonce + 1));
        executor = new SpendGrantAuthorizationExecutor(registry);

        usdc.mint(principal, 1_000e6);
        vm.prank(principal);
        usdc.approve(address(executor), type(uint256).max);

        vm.warp(1_700_000_000);
        grantId = _register(_grant(1e6, 5e6, 20e6));
    }

    // ---------------------------------------------------------------- settlement

    function test_facilitatorSettlesFromPrincipalToPayTo() public {
        Requirements memory req = _requirements(serverA, 0.25e6);
        Payment memory pay = _pay(req, 1);

        assertEq(_verify(req, pay), "");
        assertEq(_settle(req, pay), "");

        assertEq(usdc.balanceOf(serverA), 0.25e6);
        assertEq(usdc.balanceOf(principal), 1_000e6 - 0.25e6);
        assertEq(usdc.balanceOf(agent), 0);
        assertEq(usdc.balanceOf(facilitator), 0);
        // SettlementResponse.payer is the account the funds left, which the registry reports for the grant.
        (address payer,) = registry.parties(pay.grantId);
        assertEq(payer, principal);
    }

    /// payTo comes from each resource server, so the grant uses recipientMode 1 and one grant pays any of them.
    function test_oneGrantPaysDifferentServers() public {
        Requirements memory a = _requirements(serverA, 0.4e6);
        Requirements memory b = _requirements(serverB, 0.6e6);
        assertEq(_settle(a, _pay(a, 1)), "");
        assertEq(_settle(b, _pay(b, 2)), "");
        assertEq(usdc.balanceOf(serverA), 0.4e6);
        assertEq(usdc.balanceOf(serverB), 0.6e6);
    }

    // ---------------------------------------------------------------- replay and races

    /// A facilitator or resource server that retries a payment does not pay twice.
    function test_retriedPaymentIsRejected() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        assertEq(_settle(req, pay), "");
        assertEq(_verify(req, pay), "invalid_spend_grant_nonce_used");
        assertEq(_settle(req, pay), "invalid_spend_grant_nonce_used");
        assertEq(usdc.balanceOf(serverA), 0.5e6);
    }

    /// The payload is a bearer authorization: anyone who sees it may submit it, but only to the payTo it names. A
    /// facilitator that loses the race finds the nonce used under the agent and the payTo already paid.
    function test_otherSubmitterSettlesFirst() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);

        vm.prank(makeAddr("observer"));
        executor.spendWithAuthorization(
            pay.grantId, req.asset, req.amount, req.payTo, pay.nonce, pay.deadline, pay.authorization
        );

        assertEq(_settle(req, pay), "invalid_spend_grant_nonce_used");
        assertTrue(executor.nonceUsed(agent, pay.nonce));
        assertEq(usdc.balanceOf(serverA), 0.5e6);
    }

    /// The agent withdraws a payment it sent but no longer wants settled.
    function test_agentCancelsUnsettledPayment() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        vm.prank(agent);
        executor.cancelNonce(pay.nonce);
        assertEq(_settle(req, pay), "invalid_spend_grant_nonce_used");
        assertEq(usdc.balanceOf(serverA), 0);
    }

    // ---------------------------------------------------------------- the principal acts between verify and settle

    function test_capCutAfterVerifyBlocksSettlement() public {
        Requirements memory req = _requirements(serverA, 1e6);
        assertEq(_settle(req, _pay(req, 1)), "");
        // Let the first debit leave the window, so only the lifetime cap can stop the next payment.
        vm.warp(vm.getBlockTimestamp() + 86400);
        Payment memory pay = _pay(req, 2);
        assertEq(_verify(req, pay), "");

        // The treasury lowers the lifetime cap to what is already spent plus less than this payment.
        (SpendGrant memory terms, uint256 version,,,) = registry.getGrant(grantId);
        terms.assets[0] = AssetLimit(address(usdc), 1e6, 1.5e6, 1.5e6);
        vm.prank(principal);
        registry.update(grantId, version, terms);

        assertEq(_settle(req, pay), "invalid_spend_grant_over_cumulative_cap");
        assertEq(usdc.balanceOf(serverA), 1e6);
        assertFalse(executor.nonceUsed(agent, pay.nonce));
    }

    function test_revokeAfterVerifyBlocksSettlement() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        assertEq(_verify(req, pay), "");
        vm.prank(principal);
        registry.revoke(grantId);
        assertEq(_settle(req, pay), "invalid_spend_grant_revoked");
        assertEq(usdc.balanceOf(serverA), 0);
    }

    function test_treasuryShortfallIsInsufficientFunds() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        vm.prank(principal);
        usdc.approve(address(executor), 0.1e6);
        assertEq(_verify(req, pay), "insufficient_funds");
    }

    // ---------------------------------------------------------------- what the signature binds

    /// deadline is now + maxTimeoutSeconds: the payment settles up to the last second before it and never at it.
    function test_deadlineFromMaxTimeout() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        assertEq(pay.deadline, vm.getBlockTimestamp() + MAX_TIMEOUT);

        uint256 snap = vm.snapshotState();
        vm.warp(pay.deadline - 1);
        assertEq(_settle(req, pay), "");
        vm.revertToState(snap);

        vm.warp(pay.deadline);
        assertEq(_settle(req, pay), "invalid_spend_grant_authorization_expired");
    }

    /// A facilitator cannot settle for more than the agent signed: the recovered signer is then not the delegate.
    function test_amountIsBoundBySignature() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        req.amount = 0.9e6;
        assertEq(_settle(req, pay), "invalid_spend_grant_unauthorized_delegate");
    }

    /// Nor redirect it: payTo is signed too.
    function test_payToIsBoundBySignature() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        req.payTo = facilitator;
        assertEq(_settle(req, pay), "invalid_spend_grant_unauthorized_delegate");
        assertEq(usdc.balanceOf(facilitator), 0);
    }

    /// A payTo the registry refuses in either recipient mode fails with WRONG_RECIPIENT even when signed.
    function test_payToCannotBeRegistryExecutorOrAsset() public {
        address[3] memory bad = [address(registry), address(executor), address(usdc)];
        for (uint256 i; i < bad.length; i++) {
            Requirements memory req = _requirements(bad[i], 0.5e6);
            assertEq(_verify(req, _pay(req, i)), "invalid_spend_grant_wrong_recipient");
        }
    }

    function test_perCallCapBoundsOnePayment() public {
        Requirements memory req = _requirements(serverA, 1e6 + 1);
        assertEq(_verify(req, _pay(req, 1)), "invalid_spend_grant_over_tx_cap");
    }

    // ---------------------------------------------------------------- facilitator model

    /// `/verify`: simulate the settlement call and discard its effects, as an eth_call from the facilitator would.
    function _verify(Requirements memory req, Payment memory pay) internal returns (string memory code) {
        uint256 snap = vm.snapshotState();
        code = _settle(req, pay);
        vm.revertToState(snap);
    }

    /// `/settle`: submit the agent's authorization for the requirements the resource server stated.
    function _settle(Requirements memory req, Payment memory pay) internal returns (string memory) {
        vm.prank(facilitator);
        try executor.spendWithAuthorization(
            pay.grantId, req.asset, req.amount, req.payTo, pay.nonce, pay.deadline, pay.authorization
        ) {
            return "";
        } catch (bytes memory err) {
            return _errorCode(err);
        }
    }

    /// Revert data to the x402 errorCode in README.md.
    function _errorCode(bytes memory err) internal pure returns (string memory) {
        bytes4 sel = bytes4(err);
        if (sel == SpendGrantError.selector) {
            Reason reason;
            assembly {
                reason := mload(add(err, 36))
            }
            return string.concat("invalid_spend_grant_", _reasonName(reason));
        }
        if (sel == SpendGrantAuthorizationExecutor.NonceAlreadyUsed.selector) return "invalid_spend_grant_nonce_used";
        if (sel == SpendGrantAuthorizationExecutor.AuthorizationExpired.selector) {
            return "invalid_spend_grant_authorization_expired";
        }
        if (sel == SpendGrantAuthorizationExecutor.BadAuthorization.selector) return "invalid_spend_grant_signature";
        if (sel == SpendGrantExecutor.TransferFailed.selector) return "insufficient_funds";
        if (sel == SpendGrantExecutor.NativeRequiresAccountAdapter.selector) return "invalid_payload";
        return "unexpected_settle_error";
    }

    function _reasonName(Reason reason) internal pure returns (string memory) {
        string[15] memory names = [
            "ok",
            "invalid_grant",
            "bad_signature",
            "not_yet_valid",
            "expired",
            "revoked",
            "wrong_asset",
            "wrong_recipient",
            "over_tx_cap",
            "over_window_cap",
            "over_cumulative_cap",
            "window_full",
            "unauthorized_executor",
            "unauthorized_delegate",
            "nonexistent"
        ];
        return names[uint8(reason)];
    }

    // ---------------------------------------------------------------- helpers

    function _grant(uint256 perCall, uint256 perWindow, uint256 total) internal view returns (SpendGrant memory m) {
        m.principal = principal;
        m.delegate = agent;
        m.recipientMode = 1;
        m.recipient = address(0);
        m.assetCombine = 0;
        m.windowSeconds = 86400;
        m.validAfter = 1_699_999_000;
        m.validUntil = 1_900_000_000;
        m.salt = 1;
        m.assets = new AssetLimit[](1);
        m.assets[0] = AssetLimit(address(usdc), perCall, perWindow, total);
    }

    function _register(SpendGrant memory m) internal returns (bytes32 id) {
        vm.prank(m.principal);
        id = registry.register(m);
    }

    function _requirements(address payTo, uint256 amount) internal view returns (Requirements memory) {
        return Requirements(address(usdc), amount, payTo, MAX_TIMEOUT);
    }

    /// The agent signs exactly the requirements it chose, with a deadline maxTimeoutSeconds from now.
    function _pay(Requirements memory req, uint256 nonce) internal view returns (Payment memory pay) {
        pay.grantId = grantId;
        pay.nonce = nonce;
        pay.deadline = vm.getBlockTimestamp() + req.maxTimeoutSeconds;
        bytes32 digest = executor.authorizationDigest(grantId, req.asset, req.amount, req.payTo, nonce, pay.deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATE_PK, digest);
        pay.authorization = abi.encodePacked(r, s, v);
    }
}
