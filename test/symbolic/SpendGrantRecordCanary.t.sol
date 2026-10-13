// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {SpendGrantRecordSymbolic} from "./SpendGrantRecordSymbolic.t.sol";

/// @dev Must FAIL. It asserts false in the write branch of check_recordOnlyAtThePrincipalsRootDelegation, so a
/// counterexample proves that property's write branch is reached and its pass is not vacuous. `pnpm test:symbolic`
/// runs it with `test:symbolic:canary`, which succeeds only when Halmos reports this check as failed.
contract SpendGrantRecordCanary is SpendGrantRecordSymbolic {
    function check_CANARY_writeBranchIsReached(
        address redeemer,
        address argDelegate,
        address argDelegator,
        bytes32 argAuthority,
        uint256 argSalt,
        address otherEnforcer,
        bytes32 delegationHash
    ) public {
        (, address recorded) =
            _hookPrincipal(redeemer, argDelegate, argDelegator, argAuthority, argSalt, otherEnforcer, delegationHash);
        if (recorded != address(0)) assert(false);
    }
}
