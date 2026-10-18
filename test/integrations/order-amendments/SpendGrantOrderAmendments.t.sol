// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {AssetLimit, Reason, SpendGrant, SpendGrantError} from "../../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../../src/SpendGrantRegistry.sol";
import {SpendGrantExecutor} from "../../../src/SpendGrantExecutor.sol";
import {MockERC20} from "../../MockERC20.sol";

/// @dev Test-only consumer of the direct executor. Models explicit bilateral approval and the isolated
/// application call; it does not implement ERC-8001's wire format or signature verification.
contract OrderAmendmentConsumer {
    struct Order {
        uint256 price;
        uint256 revision;
        bytes32 termsHash;
    }

    struct Amendment {
        bytes32 orderId;
        uint256 baseRevision;
        bytes32 baseTermsHash;
        uint256 newPrice;
        bytes32 newTermsHash;
        uint8 approvals;
        bool executed;
    }

    address public immutable buyer;
    address public immutable provider;
    MockERC20 public immutable token;
    SpendGrantExecutor public immutable executor;
    bytes32 public grantId;
    uint256 public nextIntent;
    mapping(bytes32 => Order) public orders;
    mapping(uint256 => Amendment) public amendments;

    event AmendmentApplied(uint256 indexed intent, bytes32 indexed orderId, uint256 supplement);
    event ExecutionAttempt(uint256 indexed intent, bool success);

    constructor(address buyer_, address provider_, MockERC20 token_, SpendGrantExecutor executor_) {
        buyer = buyer_;
        provider = provider_;
        token = token_;
        executor = executor_;
    }

    function bindGrant(bytes32 id) external {
        require(msg.sender == buyer && grantId == bytes32(0) && id != bytes32(0), "binding");
        (address principal, address delegate) = executor.registry().parties(id);
        require(principal == buyer && delegate == address(this), "parties");
        grantId = id;
    }

    function fundOrder(bytes32 id, uint256 price, bytes32 termsHash) external {
        require(msg.sender == buyer && price > 0 && orders[id].price == 0, "order");
        executor.spend(grantId, address(token), price, address(this));
        orders[id] = Order(price, 0, termsHash);
    }

    function propose(bytes32 id, uint256 newPrice, bytes32 newTermsHash) external returns (uint256 intent) {
        Order memory order = orders[id];
        require(msg.sender == buyer && order.price > 0 && newPrice > order.price, "proposal");
        intent = ++nextIntent;
        amendments[intent] = Amendment(id, order.revision, order.termsHash, newPrice, newTermsHash, 0, false);
    }

    function approve(uint256 intent) external {
        require(intent > 0 && intent <= nextIntent && !amendments[intent].executed, "intent");
        require(msg.sender == buyer || msg.sender == provider, "participant");
        amendments[intent].approvals |= msg.sender == buyer ? 1 : 2;
    }

    function execute(uint256 intent) external returns (bool success, bytes memory result) {
        Amendment storage amendment = amendments[intent];
        require(amendment.approvals == 3 && !amendment.executed, "not ready");
        // Application failure consumes this attempt; restoring capacity does not restore consent for a retry.
        amendment.executed = true;
        try this.applyAmendment(intent) {
            success = true;
        } catch (bytes memory reason) {
            result = reason;
        }
        emit ExecutionAttempt(intent, success);
    }

    function applyAmendment(uint256 intent) external {
        require(msg.sender == address(this), "self only");
        Amendment storage amendment = amendments[intent];
        Order storage order = orders[amendment.orderId];
        require(order.revision == amendment.baseRevision && order.termsHash == amendment.baseTermsHash, "stale");
        uint256 supplement = amendment.newPrice - order.price;
        executor.spend(grantId, address(token), supplement, address(this));
        order.price = amendment.newPrice;
        order.termsHash = amendment.newTermsHash;
        order.revision++;
        emit AmendmentApplied(intent, amendment.orderId, supplement);
    }
}

/// @notice Consent and preflight do not reserve grant capacity. The application uses the real registry and
/// executor at execution time, so an intervening cap cut blocks a previously approved order supplement.
contract SpendGrantOrderAmendmentsTest is Test {
    bytes32 internal constant TARGET = keccak256("target order");
    bytes32 internal constant OTHER = keccak256("earlier order");
    bytes32 internal constant OLD_TERMS = keccak256("three projects for 100");
    bytes32 internal constant NEW_TERMS = keccak256("ten projects for 180");

    SpendGrantRegistry internal registry;
    SpendGrantExecutor internal executor;
    MockERC20 internal token;
    OrderAmendmentConsumer internal consumer;
    address internal buyer;
    address internal provider;
    bytes32 internal grantId;
    SpendGrant internal terms;

    function setUp() public {
        vm.warp(1_700_000_000);
        buyer = makeAddr("buyer");
        provider = makeAddr("provider");
        token = new MockERC20();
        registry = new SpendGrantRegistry(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1));
        executor = new SpendGrantExecutor(registry);
        consumer = new OrderAmendmentConsumer(buyer, provider, token, executor);

        terms.principal = buyer;
        terms.delegate = address(consumer);
        terms.recipient = address(consumer); // fixed recipient, recipientMode = 0
        terms.windowSeconds = 60;
        terms.validAfter = uint64(vm.getBlockTimestamp());
        terms.validUntil = terms.validAfter + 1 days;
        terms.assets.push(AssetLimit(address(token), 1000, 1000, 1000));
        terms.salt = 1;
        vm.prank(buyer);
        grantId = registry.register(terms);
        vm.prank(buyer);
        consumer.bindGrant(grantId);
        token.mint(buyer, 2000);
        vm.startPrank(buyer);
        token.approve(address(executor), type(uint256).max);
        consumer.fundOrder(OTHER, 600, keccak256("earlier terms"));
        consumer.fundOrder(TARGET, 100, OLD_TERMS);
        vm.stopPrank();

        // Expire setup debits so the lifetime cap, not the rolling-window cap, is the failing condition.
        vm.warp(vm.getBlockTimestamp() + terms.windowSeconds);
        assertEq(token.allowance(buyer, address(consumer)), 0);
        _assertState(700, 2, 0, 0, 100, 0, OLD_TERMS);
    }

    function test_capCutAfterConsentAndPreflightBlocksSupplement() public {
        uint256 intent = _ready();
        (bool ok, Reason reason) = registry.check(grantId, address(consumer), address(token), 80, address(consumer));
        assertTrue(ok);
        assertEq(uint8(reason), uint8(Reason.OK));

        _updateCap(750);
        (ok, reason) = registry.check(grantId, address(consumer), address(token), 80, address(consumer));
        assertFalse(ok);
        assertEq(uint8(reason), uint8(Reason.OVER_CUMULATIVE_CAP));
        vm.recordLogs();
        bytes memory result;
        (ok, result) = consumer.execute(intent);
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(SpendGrantError.selector, Reason.OVER_CUMULATIVE_CAP));
        _assertState(700, 2, 0, 0, 100, 0, OLD_TERMS);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1); // only the outer attempt; no debit, transfer or applied-amendment event
        assertEq(logs[0].emitter, address(consumer));
        assertEq(logs[0].topics[0], keccak256("ExecutionAttempt(uint256,bool)"));
        assertEq(logs[0].topics[1], bytes32(intent));
        assertFalse(abi.decode(logs[0].data, (bool)));
        (SpendGrant memory current, uint256 version,,,) = registry.getGrant(grantId);
        assertEq(current.assets[0].maxTotal, 750); // the earlier cap update is not rolled back
        assertEq(version, 2);
    }

    function test_cap800StillFundsSupplementUsingRetainedUsage() public {
        uint256 intent = _ready();
        _updateCap(800);
        (bool ok,) = consumer.execute(intent);
        assertTrue(ok);
        _assertState(780, 3, 80, 1, 180, 1, NEW_TERMS);
        vm.expectRevert("not ready");
        consumer.execute(intent);
    }

    function test_restoringCapacityRequiresFreshBilateralApproval() public {
        uint256 oldIntent = _ready();
        _updateCap(750);
        (bool ok,) = consumer.execute(oldIntent);
        assertFalse(ok);
        _updateCap(800);
        vm.expectRevert("not ready");
        consumer.execute(oldIntent);

        uint256 freshIntent = _propose();
        assertTrue(freshIntent != oldIntent);
        vm.prank(buyer);
        consumer.approve(freshIntent);
        vm.expectRevert("not ready");
        consumer.execute(freshIntent); // the provider's old approval cannot approve a new intent
        _assertState(700, 2, 0, 0, 100, 0, OLD_TERMS);
        vm.prank(provider);
        consumer.approve(freshIntent);
        (ok,) = consumer.execute(freshIntent);
        assertTrue(ok);
        _assertState(780, 3, 80, 1, 180, 1, NEW_TERMS);
    }

    function _propose() internal returns (uint256 intent) {
        vm.prank(buyer);
        return consumer.propose(TARGET, 180, NEW_TERMS);
    }

    function _ready() internal returns (uint256 intent) {
        intent = _propose();
        vm.prank(buyer);
        consumer.approve(intent);
        vm.prank(provider);
        consumer.approve(intent);
    }

    function _updateCap(uint256 cap) internal {
        (, uint256 version,,,) = registry.getGrant(grantId);
        terms.assets[0] = AssetLimit(address(token), cap, cap, cap);
        vm.prank(buyer);
        registry.update(grantId, version, terms);
    }

    function _assertState(
        uint256 spent,
        uint256 calls,
        uint256 windowSpent,
        uint256 live,
        uint256 price,
        uint256 revision,
        bytes32 termsHash
    ) internal view {
        (uint256 actualSpent, uint256 actualCalls) = registry.usage(grantId, address(token));
        assertEq(actualSpent, spent);
        assertEq(actualCalls, calls);
        (uint256 actualWindow, uint256 actualLive) = registry.rollingUsage(grantId, address(token));
        assertEq(actualWindow, windowSpent);
        assertEq(actualLive, live);
        assertEq(token.balanceOf(buyer), 2000 - spent);
        assertEq(token.balanceOf(address(consumer)), spent);
        assertEq(token.balanceOf(provider), 0);
        assertEq(token.allowance(buyer, address(executor)), type(uint256).max);
        (uint256 actualPrice, uint256 actualRevision, bytes32 actualHash) = consumer.orders(TARGET);
        assertEq(actualPrice, price);
        assertEq(actualRevision, revision);
        assertEq(actualHash, termsHash);
        (actualPrice, actualRevision, actualHash) = consumer.orders(OTHER);
        assertEq(actualPrice, 600);
        assertEq(actualRevision, 0);
        assertEq(actualHash, keccak256("earlier terms"));
    }
}
