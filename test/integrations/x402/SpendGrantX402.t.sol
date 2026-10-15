// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssetLimit, GrantState, NATIVE, Reason, SpendGrant, SpendGrantError} from "../../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../../src/SpendGrantRegistry.sol";
import {SpendGrantExecutor} from "../../../src/SpendGrantExecutor.sol";
import {SpendGrantAuthorizationExecutor} from "../../../src/SpendGrantAuthorizationExecutor.sol";
import {MockERC20} from "../../MockERC20.sol";

/// @dev A token whose transfer to a blocklisted payee fails for a reason that is not a short balance or allowance.
contract BlocklistERC20 is MockERC20 {
    mapping(address => bool) public blocked;

    function blockPayee(address who) external {
        blocked[who] = true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(!blocked[to], "blocked");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev An x402 payment settled under a registered grant. The resource server's `accepts` entry names the asset,
/// amount, payTo and maxTimeoutSeconds; the agent (the grant's delegate) answers with a `SpendAuthorization` for
/// exactly those, and the facilitator settles it with `spendWithAuthorization`, so the principal pays and the agent
/// holds no funds. The facilitator is off chain: `_verify` is its simulated call and `_settle` its transaction, and
/// both map a failure to the same error code. See README.md beside this file.
contract SpendGrantX402Test is Test {
    uint256 internal constant DELEGATE_PK = 0xA6E;
    uint256 internal constant MAX_TIMEOUT = 60;
    /// A deadline must lie more than this many seconds beyond the latest block, as in the TypeScript facilitator.
    uint256 internal constant MIN_SLACK = 5;

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

    function test_allowanceShortfallIsInsufficientFunds() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        vm.prank(principal);
        usdc.approve(address(executor), 0.1e6);
        assertEq(_verify(req, pay), "insufficient_funds");
    }

    function test_balanceShortfallIsInsufficientFunds() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        vm.prank(principal);
        assertTrue(usdc.transfer(serverB, 1_000e6 - 0.1e6));
        assertEq(_verify(req, pay), "insufficient_funds");
        assertEq(_settle(req, pay), "insufficient_funds");
    }

    /// A token that refuses the transfer for another reason (here a blocklisted payee) is not a funds shortfall:
    /// the principal's balance and allowance both cover the amount.
    function test_otherTokenFailureIsNotInsufficientFunds() public {
        BlocklistERC20 token = new BlocklistERC20();
        token.mint(principal, 1_000e6);
        vm.prank(principal);
        token.approve(address(executor), type(uint256).max);
        SpendGrant memory terms = _grant(1e6, 5e6, 20e6);
        terms.assets[0].asset = address(token);
        terms.salt = 2;
        bytes32 id = _register(terms);
        token.blockPayee(serverA);

        Requirements memory req = Requirements(address(token), 0.5e6, serverA, MAX_TIMEOUT);
        Payment memory pay = _payFor(id, req, 1);
        assertEq(_verify(req, pay), "unexpected_verify_error");
        assertEq(_settle(req, pay), "unexpected_settle_error");
        assertEq(token.balanceOf(serverA), 0);
        assertFalse(executor.nonceUsed(agent, pay.nonce));
    }

    // ---------------------------------------------------------------- what the signature binds

    /// The facilitator bounds the deadline by the latest block: at most maxTimeoutSeconds ahead, so the agent cannot
    /// sign a long-lived bearer authorization, and more than MIN_SLACK ahead, so the facilitator does not pay gas
    /// for a payment that will expire before it is mined. A refused payment is never submitted.
    function test_facilitatorEnforcesDeadlineBound() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        uint256 t = vm.getBlockTimestamp();
        uint256[5] memory refused =
            [t + MAX_TIMEOUT + 1, t + MAX_TIMEOUT + 1_000_000, t + MIN_SLACK, t + MIN_SLACK - 1, t];
        for (uint256 i; i < refused.length; i++) {
            Payment memory pay = _payWithDeadline(grantId, req, i, refused[i]);
            assertEq(_verify(req, pay), "invalid_payload");
            assertEq(_settle(req, pay), "invalid_payload");
            assertFalse(executor.nonceUsed(agent, pay.nonce));
        }
        assertEq(usdc.balanceOf(serverA), 0);

        // Both ends of the accepted range settle.
        assertEq(_settle(req, _payWithDeadline(grantId, req, 10, t + MAX_TIMEOUT)), "");
        assertEq(_settle(req, _payWithDeadline(grantId, req, 11, t + MIN_SLACK + 1)), "");
        assertEq(usdc.balanceOf(serverA), 1e6);
    }

    /// deadline is now + maxTimeoutSeconds. The facilitator checks the latest block and the executor the block that
    /// mines the call, so a payment settles up to the last second before the deadline and never at it.
    function test_deadlineIsExclusiveAtTheExecutor() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        uint256 latest = vm.getBlockTimestamp();
        assertEq(pay.deadline, latest + MAX_TIMEOUT);

        uint256 snap = vm.snapshotState();
        vm.warp(pay.deadline - 1);
        assertEq(_settleAt(req, pay, latest), "");
        vm.revertToState(snap);

        vm.warp(pay.deadline);
        assertEq(_settleAt(req, pay, latest), "invalid_spend_grant_authorization_expired");
        assertEq(usdc.balanceOf(serverA), 0);
    }

    /// A facilitator cannot settle for more than the agent signed: the recovered signer is then not the delegate.
    function test_amountIsBoundBySignature() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        req.amount = 0.9e6;
        assertEq(_settle(req, pay), "invalid_spend_grant_unauthorized_delegate");
        assertEq(usdc.balanceOf(serverA), 0);
        assertEq(usdc.balanceOf(principal), 1_000e6);
        assertFalse(executor.nonceUsed(agent, pay.nonce));
    }

    /// Nor redirect it: payTo is signed too.
    function test_payToIsBoundBySignature() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        req.payTo = facilitator;
        assertEq(_settle(req, pay), "invalid_spend_grant_unauthorized_delegate");
        assertEq(usdc.balanceOf(facilitator), 0);
    }

    /// A payTo the registry refuses fails with WRONG_RECIPIENT even when signed. The grant is in recipientMode 1.
    function test_payToCannotBePrincipalZeroRegistryExecutorOrAsset() public {
        address[5] memory bad = [principal, address(0), address(registry), address(executor), address(usdc)];
        for (uint256 i; i < bad.length; i++) {
            Requirements memory req = _requirements(bad[i], 0.5e6);
            assertEq(_verify(req, _pay(req, i)), "invalid_spend_grant_wrong_recipient");
        }
    }

    function test_perCallCapBoundsOnePayment() public {
        Requirements memory req = _requirements(serverA, 1e6 + 1);
        assertEq(_verify(req, _pay(req, 1)), "invalid_spend_grant_over_tx_cap");
    }

    // ---------------------------------------------------------------- requirements and signature checks

    function test_zeroMaxTimeoutIsInvalidPaymentRequirements() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        req.maxTimeoutSeconds = 0;
        Payment memory pay = _pay(req, 1);
        assertEq(_verify(req, pay), "invalid_payment_requirements");
        assertEq(_settle(req, pay), "invalid_payment_requirements");
    }

    function test_nativeAssetIsInvalidPaymentRequirements() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        req.asset = NATIVE;
        Payment memory pay = _pay(req, 1);
        assertEq(_verify(req, pay), "invalid_payment_requirements");
        assertEq(_settle(req, pay), "invalid_payment_requirements");
        assertFalse(executor.nonceUsed(agent, pay.nonce));
    }

    /// A signature the executor cannot parse or recover is BadAuthorization, whatever the delegate.
    function test_malformedAuthorizationIsInvalidSignature() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        Payment memory pay = _pay(req, 1);
        pay.authorization = new bytes(64);
        assertEq(_verify(req, pay), "invalid_spend_grant_signature");
        pay.authorization = new bytes(65);
        assertEq(_verify(req, pay), "invalid_spend_grant_signature");
        assertEq(usdc.balanceOf(serverA), 0);
    }

    /// An id the registry does not know has no principal, so the response carries no payer.
    function test_unknownGrantIsNonexistentWithoutPayer() public {
        Requirements memory req = _requirements(serverA, 0.5e6);
        bytes32 unknown = bytes32(uint256(0x11));
        Payment memory pay = _payFor(unknown, req, 1);
        assertEq(_verify(req, pay), "invalid_spend_grant_nonexistent");
        assertEq(_settle(req, pay), "invalid_spend_grant_nonexistent");
        (address payer,) = registry.parties(unknown);
        assertEq(payer, address(0));
    }

    // ---------------------------------------------------------------- facilitator model

    /// `/verify`: simulate the settlement call and discard its effects, as an eth_call from the facilitator would.
    function _verify(Requirements memory req, Payment memory pay) internal returns (string memory code) {
        uint256 snap = vm.snapshotState();
        code = _submit(req, pay, vm.getBlockTimestamp(), "unexpected_verify_error");
        vm.revertToState(snap);
    }

    /// `/settle`: submit the agent's authorization for the requirements the resource server stated.
    function _settle(Requirements memory req, Payment memory pay) internal returns (string memory) {
        return _settleAt(req, pay, vm.getBlockTimestamp());
    }

    /// `/settle` for a facilitator whose latest block has timestamp `latest`, which may trail the block that mines it.
    function _settleAt(Requirements memory req, Payment memory pay, uint256 latest) internal returns (string memory) {
        return _submit(req, pay, latest, "unexpected_settle_error");
    }

    function _submit(Requirements memory req, Payment memory pay, uint256 latest, string memory fallbackCode)
        internal
        returns (string memory)
    {
        string memory pre = _precheck(req, pay, latest);
        if (bytes(pre).length != 0) return pre;
        vm.prank(facilitator);
        try executor.spendWithAuthorization(
            pay.grantId, req.asset, req.amount, req.payTo, pay.nonce, pay.deadline, pay.authorization
        ) {
            return "";
        } catch (bytes memory err) {
            return _errorCode(err, pay.grantId, req, fallbackCode);
        }
    }

    /// The checks before the call, with `latest` the latest block's timestamp; "" when the call may go ahead. The
    /// wire checks (version, scheme, network, field formats) have no counterpart in a contract test.
    function _precheck(Requirements memory req, Payment memory pay, uint256 latest)
        internal
        pure
        returns (string memory)
    {
        if (req.maxTimeoutSeconds < 1) return "invalid_payment_requirements";
        if (req.asset == NATIVE) return "invalid_payment_requirements";
        if (pay.deadline > latest + req.maxTimeoutSeconds || pay.deadline <= latest + MIN_SLACK) {
            return "invalid_payload";
        }
        return "";
    }

    /// Revert data to the x402 errorCode in README.md. `TransferFailed` is `insufficient_funds` only when the grant's
    /// state, read at the same block, shows the balance or allowance below the amount.
    function _errorCode(bytes memory err, bytes32 id, Requirements memory req, string memory fallbackCode)
        internal
        view
        returns (string memory)
    {
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
        if (sel == SpendGrantExecutor.TransferFailed.selector) {
            GrantState memory st = registry.grantState(id, req.asset);
            bool short =
                (st.balanceKnown && st.balance < req.amount) || (st.allowanceKnown && st.allowance < req.amount);
            return short ? "insufficient_funds" : fallbackCode;
        }
        if (sel == SpendGrantExecutor.NativeRequiresAccountAdapter.selector) return "invalid_payment_requirements";
        return fallbackCode;
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
    function _pay(Requirements memory req, uint256 nonce) internal view returns (Payment memory) {
        return _payFor(grantId, req, nonce);
    }

    function _payFor(bytes32 id, Requirements memory req, uint256 nonce) internal view returns (Payment memory) {
        return _payWithDeadline(id, req, nonce, vm.getBlockTimestamp() + req.maxTimeoutSeconds);
    }

    /// A payment the agent signed with a deadline of its own choosing.
    function _payWithDeadline(bytes32 id, Requirements memory req, uint256 nonce, uint256 deadline)
        internal
        view
        returns (Payment memory pay)
    {
        pay.grantId = id;
        pay.nonce = nonce;
        pay.deadline = deadline;
        bytes32 digest = executor.authorizationDigest(id, req.asset, req.amount, req.payTo, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(DELEGATE_PK, digest);
        pay.authorization = abi.encodePacked(r, s, v);
    }
}
