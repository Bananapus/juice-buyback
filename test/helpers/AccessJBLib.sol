// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "lib/juice-contracts-v4/src/libraries/JBCurrencyIds.sol";
import "lib/juice-contracts-v4/src/libraries/JBConstants.sol";
import "lib/juice-contracts-v4/src/libraries/JBConstants.sol";

contract AccessJBLib {
    function ETH() external pure returns (uint256) {
        return JBCurrencyIds.NATIVE;
    }

    function USD() external pure returns (uint256) {
        return JBCurrencyIds.USD;
    }

    function ETHToken() external pure returns (address) {
        return JBConstants.NATIVE_TOKEN;
    }

    function MAX_FEE() external pure returns (uint256) {
        return JBConstants.MAX_FEE;
    }

    function SPLITS_TOTAL_PERCENT() external pure returns (uint256) {
        return JBConstants.SPLITS_TOTAL_PERCENT;
    }
}
