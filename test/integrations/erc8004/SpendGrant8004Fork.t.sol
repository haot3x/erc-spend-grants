// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AssetLimit, FixedField, Reason, SpendGrant, SpendGrantError} from "../../../src/SpendGrantTypes.sol";
import {SpendGrantRegistry} from "../../../src/SpendGrantRegistry.sol";
import {SpendGrantAuthorizationExecutor} from "../../../src/SpendGrantAuthorizationExecutor.sol";
import {MockERC20} from "../../MockERC20.sol";

/// @dev The parts of the ERC-8004 Identity Registry that the tests call.
interface IIdentityRegistry {
    function register() external returns (uint256 agentId);
    function getAgentWallet(uint256 agentId) external view returns (address);
    function setAgentWallet(uint256 agentId, address newWallet, uint256 deadline, bytes calldata signature) external;
    function unsetAgentWallet(uint256 agentId) external;
    function getVersion() external pure returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    /// @dev An ERC-721 transfer, not ERC-20.
    function transferFrom(address from, address to, uint256 tokenId) external;
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );
}

/// @dev A contract wallet for the agent: it accepts any signature (ERC-1271) and spends under its grant when told to.
contract Erc1271Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function spend(SpendGrantAuthorizationExecutor executor, bytes32 id, address token, uint256 amount, address to)
        external
    {
        executor.spend(id, token, amount, to);
    }
}

/// @dev A grant whose delegate is an ERC-8004 agent's wallet, using the Identity Registry and the ERC-8427 registry
/// and executor deployed on Arc testnet. The principal resolves `getAgentWallet(agentId)` and registers a grant to
/// that address. The grant binds the address, not the identity: when the agent's wallet changes or the agent NFT is
/// transferred, the grant stays with the old address until the principal revokes and registers again. The salt
/// `keccak256(abi.encode(identityChainId, identityRegistry, agentId, n))` labels the grant for third parties and authorizes nothing.
///
/// Needs a network. Run with `pnpm test:fork`; without FORK_TESTS=true the suite is skipped so `pnpm check` stays
/// offline. Under test/integrations, so the ERC bundle omits it. See README.md beside this file.
contract SpendGrant8004ForkTest is Test {
    IIdentityRegistry internal constant IDENTITY = IIdentityRegistry(0x8004A818BFB912233c491871b3d84c89A494BD9e);
    SpendGrantRegistry internal constant REGISTRY = SpendGrantRegistry(0xe8987A22a1e3fd4a63cB517A9476B9d214388287);
    SpendGrantAuthorizationExecutor internal constant EXECUTOR =
        SpendGrantAuthorizationExecutor(0xB99785329AbEc9936b6EF6350015be39D3392646);

    uint256 internal constant SALT_N = 1;

    /// @dev The deployed implementation's event for every change to the `agentWallet` key.
    event MetadataSet(
        uint256 indexed agentId, string indexed indexedMetadataKey, string metadataKey, bytes metadataValue
    );

    MockERC20 internal usdc;
    address internal principal;
    address internal vendor;
    address internal owner;
    address internal oldWallet;
    address internal newWallet;
    address internal newOwner;
    uint256 internal newWalletPk;
    uint256 internal agentId;

    function setUp() public {
        if (!vm.envOr("FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("arc_testnet");
        assertEq(IDENTITY.getVersion(), "2.0.0", "the Identity Registry was upgraded");
        assertEq(REGISTRY.executor(), address(EXECUTOR), "registry and executor do not match");
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = IDENTITY.eip712Domain();
        assertEq(name, "ERC8004IdentityRegistry", "the Identity Registry's EIP-712 name changed");
        assertEq(version, "1", "the Identity Registry's EIP-712 version changed");
        assertEq(chainId, block.chainid, "the Identity Registry's EIP-712 chain id changed");
        assertEq(verifying, address(IDENTITY), "the Identity Registry's verifying contract changed");

        principal = makeAddr("treasury");
        vendor = makeAddr("vendor");
        // Labels unique to this suite, so the fork's live state holds nothing for these addresses. The agent's first
        // wallet is its owner's address, which register() sets.
        owner = makeAddr("erc8004-owner");
        oldWallet = owner;
        (newWallet, newWalletPk) = makeAddrAndKey("erc8004-new-wallet");
        newOwner = makeAddr("erc8004-new-owner");

        usdc = new MockERC20();
        usdc.mint(principal, 1_000e6);
        vm.prank(principal);
        usdc.approve(address(EXECUTOR), type(uint256).max);

        vm.prank(owner);
        agentId = IDENTITY.register();
    }

    // ---------------------------------------------------------------- the principal resolves the wallet

    /// The principal reads the agent's wallet from the Identity Registry, grants to that address, and the agent spends.
    function test_principalGrantsToResolvedAgentWalletAndAgentSpends() public {
        assertEq(IDENTITY.getAgentWallet(agentId), oldWallet);
        bytes32 id = _register(_grant(IDENTITY.getAgentWallet(agentId)));

        vm.prank(oldWallet);
        EXECUTOR.spend(id, address(usdc), 4e6, vendor);
        assertEq(usdc.balanceOf(vendor), 4e6);
        assertEq(usdc.balanceOf(principal), 1_000e6 - 4e6);
    }

    // ---------------------------------------------------------------- the grant binds the address: wallet change

    /// Changing the agent's wallet does not touch the grant: the old wallet keeps spending.
    function test_oldWalletKeepsSpendingAfterWalletChange() public {
        bytes32 id = _register(_grant(oldWallet));
        _setWallet(agentId, owner, newWallet, newWalletPk);
        assertEq(IDENTITY.getAgentWallet(agentId), newWallet);

        vm.prank(oldWallet);
        EXECUTOR.spend(id, address(usdc), 4e6, vendor);
        assertEq(usdc.balanceOf(vendor), 4e6);
    }

    /// The agent's new wallet is not the grant's delegate, so it cannot spend under the old grant.
    function test_newWalletCannotSpendUnderOldGrant() public {
        bytes32 id = _register(_grant(oldWallet));
        _setWallet(agentId, owner, newWallet, newWalletPk);

        vm.prank(newWallet);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.UNAUTHORIZED_DELEGATE));
        EXECUTOR.spend(id, address(usdc), 4e6, vendor);
    }

    /// The delegate is fixed at registration, so the principal cannot retarget a grant with `update`.
    function test_updateCannotRetargetGrantToNewWallet() public {
        bytes32 id = _register(_grant(oldWallet));
        _setWallet(agentId, owner, newWallet, newWalletPk);

        (SpendGrant memory terms, uint256 version,,,) = REGISTRY.getGrant(id);
        terms.delegate = newWallet;
        vm.prank(principal);
        vm.expectRevert(FixedField.selector);
        REGISTRY.update(id, version, terms);
    }

    /// Until the principal revokes, the old wallet is authorized; after it, the grant is dead.
    function test_revokeStopsOldWalletAfterWalletChange() public {
        bytes32 id = _register(_grant(oldWallet));
        _setWallet(agentId, owner, newWallet, newWalletPk);
        vm.prank(principal);
        REGISTRY.revoke(id);

        vm.prank(oldWallet);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.REVOKED));
        EXECUTOR.spend(id, address(usdc), 1e6, vendor);
    }

    /// Rebinding to the new wallet is revoke plus register; the new grant is a new id, since the delegate is in the hash.
    /// Usage does not carry over: the old grant's spend does not count against the new one.
    function test_rebindAfterWalletChangeIsRevokePlusRegister() public {
        bytes32 oldId = _register(_grant(oldWallet));
        vm.prank(oldWallet);
        EXECUTOR.spend(oldId, address(usdc), 5e6, vendor);
        _setWallet(agentId, owner, newWallet, newWalletPk);
        vm.prank(principal);
        REGISTRY.revoke(oldId);
        bytes32 newId = _register(_grant(IDENTITY.getAgentWallet(agentId)));
        assertTrue(newId != oldId);
        (uint256 spent,) = REGISTRY.usage(newId, address(usdc));
        assertEq(spent, 0);

        // Two full per-call spends fill the window cap of 10e6, which the old grant's 5e6 would have exceeded.
        vm.startPrank(newWallet);
        EXECUTOR.spend(newId, address(usdc), 5e6, vendor);
        EXECUTOR.spend(newId, address(usdc), 5e6, vendor);
        vm.stopPrank();
        assertEq(usdc.balanceOf(vendor), 15e6);
    }

    // ---------------------------------------------------------------- the grant binds the address: unset

    /// The owner clears the wallet without a transfer: `getAgentWallet` is zero and the old wallet keeps spending.
    function test_unsetClearsWalletButOldWalletKeepsSpending() public {
        bytes32 id = _register(_grant(oldWallet));
        _expectWalletEvent(agentId, "");
        vm.prank(owner);
        IDENTITY.unsetAgentWallet(agentId);

        assertEq(IDENTITY.ownerOf(agentId), owner);
        assertEq(IDENTITY.getAgentWallet(agentId), address(0));
        vm.prank(oldWallet);
        EXECUTOR.spend(id, address(usdc), 4e6, vendor);
        assertEq(usdc.balanceOf(vendor), 4e6);
    }

    /// A principal that passes the unset wallet on unchecked is refused as INVALID_GRANT.
    function test_registerWithUnsetWalletReverts() public {
        vm.prank(owner);
        IDENTITY.unsetAgentWallet(agentId);
        SpendGrant memory terms = _grant(IDENTITY.getAgentWallet(agentId));

        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.INVALID_GRANT));
        REGISTRY.register(terms);
    }

    // ---------------------------------------------------------------- the grant binds the address: contract wallet

    /// A contract becomes the agent wallet through ERC-1271, a grant to it is spent by the contract calling the
    /// executor, the previous EOA wallet's grant is unaffected, and any other address is refused.
    function test_contractWalletSpendsUnderItsGrant() public {
        bytes32 eoaId = _register(_grant(oldWallet));
        Erc1271Wallet wallet = new Erc1271Wallet();
        // Not a valid ECDSA signature, so the implementation falls through to `isValidSignature`.
        uint256 deadline = vm.getBlockTimestamp() + 60;
        _expectWalletEvent(agentId, abi.encodePacked(address(wallet)));
        vm.prank(owner);
        IDENTITY.setAgentWallet(agentId, address(wallet), deadline, hex"01");
        assertEq(IDENTITY.getAgentWallet(agentId), address(wallet));
        bytes32 id = _register(_grant(IDENTITY.getAgentWallet(agentId)));

        wallet.spend(EXECUTOR, id, address(usdc), 4e6, vendor);
        assertEq(usdc.balanceOf(vendor), 4e6);

        vm.prank(oldWallet);
        EXECUTOR.spend(eoaId, address(usdc), 4e6, vendor);
        assertEq(usdc.balanceOf(vendor), 8e6);

        vm.prank(vendor);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.UNAUTHORIZED_DELEGATE));
        EXECUTOR.spend(id, address(usdc), 1e6, vendor);
    }

    // ---------------------------------------------------------------- the grant binds the address: NFT transfer

    /// A transfer clears the agent wallet, and the grant stays with the old wallet.
    function test_transferClearsWalletButOldWalletKeepsSpending() public {
        bytes32 id = _register(_grant(oldWallet));
        // The deployed implementation announces the clear with an empty value.
        _expectWalletEvent(agentId, "");
        vm.prank(owner);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IDENTITY.transferFrom(owner, newOwner, agentId);

        assertEq(IDENTITY.ownerOf(agentId), newOwner);
        assertEq(IDENTITY.getAgentWallet(agentId), address(0));
        vm.prank(oldWallet);
        EXECUTOR.spend(id, address(usdc), 4e6, vendor);
        assertEq(usdc.balanceOf(vendor), 4e6);
    }

    /// After a transfer `getAgentWallet` is zero. A principal that passes it on unchecked is refused: the registry
    /// rejects a zero delegate as INVALID_GRANT. The check belongs to the principal, before it registers.
    function test_registerWithClearedWalletReverts() public {
        vm.prank(owner);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IDENTITY.transferFrom(owner, newOwner, agentId);
        SpendGrant memory terms = _grant(IDENTITY.getAgentWallet(agentId));

        vm.prank(principal);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.INVALID_GRANT));
        REGISTRY.register(terms);
    }

    /// The new owner's verified wallet is not the old grant's delegate, so it cannot spend under it.
    function test_newOwnersWalletCannotSpendUnderOldGrant() public {
        bytes32 oldId = _register(_grant(oldWallet));
        vm.prank(owner);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IDENTITY.transferFrom(owner, newOwner, agentId);
        _setWallet(agentId, newOwner, newWallet, newWalletPk);
        assertEq(IDENTITY.getAgentWallet(agentId), newWallet);

        vm.prank(newWallet);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.UNAUTHORIZED_DELEGATE));
        EXECUTOR.spend(oldId, address(usdc), 1e6, vendor);
    }

    /// The new owner re-verifies a wallet; the principal then revokes the old grant and registers to it.
    function test_rebindAfterTransferIsRevokePlusRegister() public {
        bytes32 oldId = _register(_grant(oldWallet));
        vm.prank(owner);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IDENTITY.transferFrom(owner, newOwner, agentId);
        _setWallet(agentId, newOwner, newWallet, newWalletPk);
        assertEq(IDENTITY.getAgentWallet(agentId), newWallet);

        vm.prank(principal);
        REGISTRY.revoke(oldId);
        bytes32 newId = _register(_grant(IDENTITY.getAgentWallet(agentId)));

        vm.prank(newWallet);
        EXECUTOR.spend(newId, address(usdc), 4e6, vendor);
        assertEq(usdc.balanceOf(vendor), 4e6);
    }

    // ---------------------------------------------------------------- the salt is a label

    /// A third party recomputes the salt from the stored terms, and compares the delegate to the current wallet. The
    /// salt matches throughout; only the delegate comparison notices that the wallet changed.
    function test_thirdPartyChecksSaltAndDelegateAgainstWallet() public {
        bytes32 id = _register(_grant(oldWallet));

        (SpendGrant memory terms,,,,) = REGISTRY.getGrant(id);
        assertEq(terms.salt, _salt(agentId, SALT_N));
        assertEq(terms.salt, uint256(keccak256(abi.encode(uint256(5042002), address(IDENTITY), agentId, SALT_N))));
        // The same registry address is live on other chains, so another chain id gives another salt.
        assertTrue(terms.salt != uint256(keccak256(abi.encode(uint256(1), address(IDENTITY), agentId, SALT_N))));
        assertEq(terms.delegate, IDENTITY.getAgentWallet(agentId));

        _setWallet(agentId, owner, newWallet, newWalletPk);
        (terms,,,,) = REGISTRY.getGrant(id);
        assertEq(terms.salt, _salt(agentId, SALT_N));
        assertTrue(terms.delegate != IDENTITY.getAgentWallet(agentId));
    }

    /// The salt names the agent, but holding the identity is not holding the grant: the agent's new wallet is refused.
    function test_matchingSaltDoesNotAuthorizeNewWallet() public {
        bytes32 id = _register(_grant(oldWallet));
        _setWallet(agentId, owner, newWallet, newWalletPk);
        (SpendGrant memory terms,,,,) = REGISTRY.getGrant(id);
        assertEq(terms.salt, _salt(agentId, SALT_N));

        vm.prank(newWallet);
        vm.expectRevert(abi.encodeWithSelector(SpendGrantError.selector, Reason.UNAUTHORIZED_DELEGATE));
        EXECUTOR.spend(id, address(usdc), 1e6, vendor);
    }

    /// `update` ignores the salt in the terms it is given: the stored salt and the grant id do not move.
    function test_updateIgnoresChangedSalt() public {
        bytes32 id = _register(_grant(oldWallet));
        (SpendGrant memory terms, uint256 version,,,) = REGISTRY.getGrant(id);
        terms.salt = _salt(agentId + 1, SALT_N);
        terms.assets[0] = AssetLimit(address(usdc), 5e6, 6e6, 6e6);
        vm.prank(principal);
        REGISTRY.update(id, version, terms);

        (SpendGrant memory after_, uint256 newVersion,,,) = REGISTRY.getGrant(id);
        assertEq(newVersion, version + 1);
        assertEq(after_.assets[0].maxTotal, 6e6);
        assertEq(after_.salt, _salt(agentId, SALT_N));
        (address stored,) = REGISTRY.parties(id);
        assertEq(stored, principal);
    }

    // ---------------------------------------------------------------- discovery

    /// `grantsTo` is keyed by the delegate address: after a wallet change the old grant stays under the old wallet and
    /// does not appear under the new one, so an agent finds grants for its new wallet only once the principal rebinds.
    function test_grantsToFollowsTheAddressNotTheIdentity() public {
        // Counts are relative to the live registry's lists at the fork block.
        (, uint256 oldBefore) = REGISTRY.grantsTo(oldWallet, 0, 0);
        (, uint256 newBefore) = REGISTRY.grantsTo(newWallet, 0, 0);

        bytes32 oldId = _register(_grant(oldWallet));
        (bytes32[] memory ids, uint256 total) = REGISTRY.grantsTo(oldWallet, oldBefore, 10);
        assertEq(total, oldBefore + 1);
        assertEq(ids[0], oldId);

        _setWallet(agentId, owner, newWallet, newWalletPk);
        (ids, total) = REGISTRY.grantsTo(newWallet, newBefore, 10);
        assertEq(total, newBefore);
        assertEq(ids.length, 0);
        (ids, total) = REGISTRY.grantsTo(oldWallet, oldBefore, 10);
        assertEq(total, oldBefore + 1);
        assertEq(ids[0], oldId);

        vm.prank(principal);
        REGISTRY.revoke(oldId);
        bytes32 newId = _register(_grant(IDENTITY.getAgentWallet(agentId)));
        (ids, total) = REGISTRY.grantsTo(newWallet, newBefore, 10);
        assertEq(total, newBefore + 1);
        assertEq(ids[0], newId);
    }

    // ---------------------------------------------------------------- helpers

    /// The salt convention, after ERC-8004's agentRegistry `{namespace}:{chainId}:{identityRegistry}`: it commits to the
    /// Identity Registry's chain and address, the agent id and a counter, so a third party can recompute it from the
    /// stored terms and knows which chain's registry to query. The fork's chain is the Identity Registry's chain.
    function _salt(uint256 id, uint256 n) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(block.chainid, address(IDENTITY), id, n)));
    }

    function _grant(address delegate) internal view returns (SpendGrant memory m) {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        m.principal = principal;
        m.delegate = delegate;
        m.recipientMode = 0;
        m.recipient = vendor;
        m.assetCombine = 0;
        m.windowSeconds = 86400;
        m.validAfter = now_ - 60;
        m.validUntil = now_ + 30 days;
        m.salt = _salt(agentId, SALT_N);
        m.assets = new AssetLimit[](1);
        m.assets[0] = AssetLimit(address(usdc), 5e6, 10e6, 100e6);
    }

    function _register(SpendGrant memory terms) internal returns (bytes32 id) {
        vm.prank(principal);
        id = REGISTRY.register(terms);
    }

    /// `caller` (the token owner or an approved operator) sets a new wallet, proving control of it with the new wallet's
    /// EIP-712 signature. The signed `owner` field is the token owner, whoever calls. The deployed contract requires a
    /// deadline within five minutes.
    function _setWallet(uint256 id, address caller, address wallet, uint256 walletPk) internal {
        uint256 deadline = vm.getBlockTimestamp() + 60;
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = IDENTITY.eip712Domain();
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifying
            )
        );
        address tokenOwner = IDENTITY.ownerOf(id);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("AgentWalletSet(uint256 agentId,address newWallet,address owner,uint256 deadline)"),
                id,
                wallet,
                tokenOwner,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(walletPk, keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
        _expectWalletEvent(id, abi.encodePacked(wallet));
        vm.prank(caller);
        IDENTITY.setAgentWallet(id, wallet, deadline, abi.encodePacked(r, s, v));
    }

    /// The next call must emit `MetadataSet` for the `agentWallet` key with `value`: the new wallet, or empty for a
    /// clear. The event does not carry the previous wallet.
    function _expectWalletEvent(uint256 id, bytes memory value) internal {
        vm.expectEmit(true, true, false, true, address(IDENTITY));
        emit MetadataSet(id, "agentWallet", "agentWallet", value);
    }
}
