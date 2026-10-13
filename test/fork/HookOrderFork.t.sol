// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IDelegationManager, ForkDeleGator} from "./SpendGrantRedemptionFork.t.sol";
import {MockDelegationManager, MockDeleGator} from "../SpendGrantRedemption.t.sol";

contract TraceLog {
    bytes32[] internal entries;

    function push(bytes32 tag) external {
        entries.push(tag);
    }

    function all() external view returns (bytes32[] memory) {
        return entries;
    }
}

/// @dev Logs every hook the manager calls on it, tagged with its label.
contract TraceEnforcer {
    TraceLog internal immutable LOG;
    bytes16 internal immutable LABEL;

    constructor(TraceLog log_, bytes16 label_) {
        LOG = log_;
        LABEL = label_;
    }

    function beforeAllHook(bytes calldata, bytes calldata, bytes32, bytes calldata, bytes32, address, address)
        external
    {
        LOG.push(bytes32(abi.encodePacked(LABEL, bytes16("beforeAll"))));
    }

    function beforeHook(bytes calldata, bytes calldata, bytes32, bytes calldata, bytes32, address, address) external {
        LOG.push(bytes32(abi.encodePacked(LABEL, bytes16("before"))));
    }

    function afterHook(bytes calldata, bytes calldata, bytes32, bytes calldata, bytes32, address, address) external {
        LOG.push(bytes32(abi.encodePacked(LABEL, bytes16("after"))));
    }

    function afterAllHook(bytes calldata, bytes calldata, bytes32, bytes calldata, bytes32, address, address)
        external
    {
        LOG.push(bytes32(abi.encodePacked(LABEL, bytes16("afterAll"))));
    }
}

/// @notice The mock manager's hook order must be MetaMask DelegationManager v1.3.0's, because the redemption
/// tests and the record model rest on it: a two-delegation chain with a logging enforcer in every caveat slot,
/// redeemed twice in one batch, must leave the same trace on both.
contract HookOrderForkTest is Test {
    IDelegationManager internal constant MANAGER = IDelegationManager(0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3);

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("arc_testnet");
    }

    function _signDelegation(uint256 pk, IDelegationManager.Delegation memory d) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", MANAGER.getDomainHash(), MANAGER.getDelegationHash(d)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
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

    uint256 internal constant ROOT_PK = 0xA1;
    uint256 internal constant MID_PK = 0xA2;
    uint256 internal constant REDEEMER_PK = 0xA3;

    function test_fork_mockManagerHookOrderMatchesTheLiveManager() public {
        bytes32[] memory live = _liveTrace();
        bytes32[] memory mock = _mockTrace();
        for (uint256 i = 0; i < live.length; i++) {
            emit log_named_bytes32("live", live[i]);
        }
        assertEq(mock.length, live.length, "trace length");
        for (uint256 i = 0; i < live.length; i++) {
            assertEq(mock[i], live[i], "trace entry");
        }
    }

    function _liveTrace() internal returns (bytes32[] memory) {
        TraceLog log = new TraceLog();
        ForkDeleGator rootAccount = new ForkDeleGator(address(MANAGER), vm.addr(ROOT_PK));
        ForkDeleGator midAccount = new ForkDeleGator(address(MANAGER), vm.addr(MID_PK));
        address redeemer = vm.addr(REDEEMER_PK);

        IDelegationManager.Delegation memory root;
        root.delegate = address(midAccount);
        root.delegator = address(rootAccount);
        root.authority = MANAGER.ROOT_AUTHORITY();
        root.caveats = new IDelegationManager.Caveat[](2);
        root.caveats[0] = IDelegationManager.Caveat(address(new TraceEnforcer(log, "root0")), "", "");
        root.caveats[1] = IDelegationManager.Caveat(address(new TraceEnforcer(log, "root1")), "", "");
        root.signature = _signDelegation(ROOT_PK, root);
        IDelegationManager.Delegation memory leaf;
        leaf.delegate = redeemer;
        leaf.delegator = address(midAccount);
        leaf.authority = MANAGER.getDelegationHash(root);
        leaf.caveats = new IDelegationManager.Caveat[](2);
        leaf.caveats[0] = IDelegationManager.Caveat(address(new TraceEnforcer(log, "leaf0")), "", "");
        leaf.caveats[1] = IDelegationManager.Caveat(address(new TraceEnforcer(log, "leaf1")), "", "");
        leaf.signature = _signDelegation(MID_PK, leaf);
        IDelegationManager.Delegation[] memory chain = new IDelegationManager.Delegation[](2);
        chain[0] = leaf;
        chain[1] = root;

        bytes memory execution = abi.encodePacked(address(log), uint256(0), abi.encodeCall(TraceLog.push, ("exec")));
        vm.prank(redeemer);
        MANAGER.redeemDelegations(_two(abi.encode(chain)), _two(bytes32(0)), _two(execution));
        return log.all();
    }

    function _mockTrace() internal returns (bytes32[] memory) {
        TraceLog log = new TraceLog();
        MockDelegationManager mock = new MockDelegationManager();
        MockDeleGator rootAccount = new MockDeleGator(address(mock), vm.addr(ROOT_PK));
        MockDeleGator midAccount = new MockDeleGator(address(mock), vm.addr(MID_PK));
        address redeemer = vm.addr(REDEEMER_PK);

        MockDelegationManager.Delegation memory root;
        root.delegate = address(midAccount);
        root.delegator = address(rootAccount);
        root.caveats = new MockDelegationManager.Caveat[](2);
        root.caveats[0] = MockDelegationManager.Caveat(address(new TraceEnforcer(log, "root0")), "", "");
        root.caveats[1] = MockDelegationManager.Caveat(address(new TraceEnforcer(log, "root1")), "", "");
        MockDelegationManager.Delegation memory leaf;
        leaf.delegate = redeemer;
        leaf.delegator = address(midAccount);
        leaf.caveats = new MockDelegationManager.Caveat[](2);
        leaf.caveats[0] = MockDelegationManager.Caveat(address(new TraceEnforcer(log, "leaf0")), "", "");
        leaf.caveats[1] = MockDelegationManager.Caveat(address(new TraceEnforcer(log, "leaf1")), "", "");
        root.authority = mock.ROOT_AUTHORITY();
        leaf.authority = mock.getDelegationHash(root);
        MockDelegationManager.Delegation[] memory chain = new MockDelegationManager.Delegation[](2);
        chain[0] = leaf;
        chain[1] = root;

        bytes memory execution = abi.encodePacked(address(log), uint256(0), abi.encodeCall(TraceLog.push, ("exec")));
        vm.prank(redeemer);
        mock.redeemDelegations(_two(abi.encode(chain)), _two(bytes32(0)), _two(execution));
        return log.all();
    }
}
