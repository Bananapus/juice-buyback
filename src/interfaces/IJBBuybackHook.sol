// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IJBPayHook} from "lib/juice-contracts-v4/src/interfaces/IJBPayHook.sol";
import {IJBRulesetDataHook} from "lib/juice-contracts-v4/src/interfaces/IJBRulesetDataHook.sol";
import {IJBDirectory} from "lib/juice-contracts-v4/src/interfaces/IJBDirectory.sol";
import {IJBController} from "lib/juice-contracts-v4/src/interfaces/IJBController.sol";
import {IJBProjects} from "lib/juice-contracts-v4/src/interfaces/IJBProjects.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3SwapCallback} from "lib/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IWETH9} from "./external/IWETH9.sol";

interface IJBBuybackHook is IJBPayHook, IJBRulesetDataHook, IUniswapV3SwapCallback {
    event BuybackDelegate_Swap(
        uint256 indexed projectId, uint256 amountIn, IUniswapV3Pool pool, uint256 amountOut, address caller
    );
    event BuybackDelegate_Mint(uint256 indexed projectId, uint256 amountIn, uint256 tokenCount, address caller);
    event BuybackDelegate_TwapWindowChanged(
        uint256 indexed projectId, uint256 oldSecondsAgo, uint256 newSecondsAgo, address caller
    );
    event BuybackDelegate_TwapSlippageToleranceChanged(
        uint256 indexed projectId, uint256 oldTwapDelta, uint256 newTwapDelta, address caller
    );
    event BuybackDelegate_PoolAdded(
        uint256 indexed projectId, address indexed terminalToken, address newPool, address caller
    );

    function SLIPPAGE_DENOMINATOR() external view returns (uint256);

    function MIN_TWAP_SLIPPAGE_TOLERANCE() external view returns (uint256);

    function MAX_TWAP_SLIPPAGE_TOLERANCE() external view returns (uint256);

    function MIN_TWAP_WINDOW() external view returns (uint256);

    function MAX_TWAP_WINDOW() external view returns (uint256);

    function UNISWAP_V3_FACTORY() external view returns (address);

    function DIRECTORY() external view returns (IJBDirectory);

    function CONTROLLER() external view returns (IJBController);

    function PROJECTS() external view returns (IJBProjects);

    function WETH() external view returns (IWETH9);

    function poolOf(uint256 projectId, address terminalToken) external view returns (IUniswapV3Pool pool);

    function twapWindowOf(uint256 projectId) external view returns (uint32 window);

    function twapSlippageToleranceOf(uint256 projectId) external view returns (uint256 slippageTolerance);

    function projectTokenOf(uint256 projectId) external view returns (address projectTokenOf);

    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        uint32 twapWindow,
        uint256 twapSlippageTolerance,
        address terminalToken
    )
        external
        returns (IUniswapV3Pool newPool);

    function setTwapWindowOf(uint256 projectId, uint32 newWindow) external;

    function setTwapSlippageToleranceOf(uint256 projectId, uint256 newSlippageTolerance) external;
}
