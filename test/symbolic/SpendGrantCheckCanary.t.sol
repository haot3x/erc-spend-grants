// SPDX-License-Identifier: CC0-1.0
pragma solidity 0.8.28;

import {SpendGrantSymbolic} from "./SpendGrantSymbolic.t.sol";

/// @dev Must FAIL. It asserts false where `check` returns OK and `consume` succeeds, so a counterexample proves
/// check_checkMatchesConsume reaches its OK branch and its pass is not vacuous. `pnpm test:symbolic` runs it with
/// `test:symbolic:check-canary`, which succeeds only when Halmos reports this check as failed.
contract SpendGrantCheckCanary is SpendGrantSymbolic {
    function check_CANARY_okBranchIsReached(
        uint8 grantPick,
        bool byStranger,
        uint8 assetPick,
        uint256 amount,
        address recipient,
        uint256 ts
    ) public {
        (bool checkRan, bool ok, uint8 reason, bool success,) =
            _checkThenConsume(grantPick, byStranger, assetPick, amount, recipient, ts);
        if (checkRan && ok && reason == 0 && success) assert(false);
    }
}
