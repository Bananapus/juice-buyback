// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {ERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {mulDiv} from "lib/prb-math/src/Common.sol";
import {TickMath} from "lib/v3-core/contracts/libraries/TickMath.sol";
import {OracleLibrary} from "lib/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {IUniswapV3Pool} from "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IJBTerminal} from "lib/juice-contracts-v4/src/interfaces/terminal/IJBTerminal.sol";
import {IJBMultiTerminal} from "lib/juice-contracts-v4/src/interfaces/terminal/IJBMultiTerminal.sol";
import {JBAfterPayRecordedContext} from "lib/juice-contracts-v4/src/structs/JBAfterPayRecordedContext.sol";
import {JBPermissioned} from "lib/juice-contracts-v4/src/abstract/JBPermissioned.sol";
import {IJBDirectory} from "lib/juice-contracts-v4/src/interfaces/IJBDirectory.sol";
import {IJBController} from "lib/juice-contracts-v4/src/interfaces/IJBController.sol";
import {IJBProjects} from "lib/juice-contracts-v4/src/interfaces/IJBController.sol";
import {IJBPermissioned} from "lib/juice-contracts-v4/src/interfaces/IJBPermissioned.sol";
import {IJBRulesetDataHook} from "lib/juice-contracts-v4/src/interfaces/IJBRulesetDataHook.sol";
import {IJBPayHook} from "lib/juice-contracts-v4/src/interfaces/IJBPayHook.sol";
import {JBPayHookSpecification} from "lib/juice-contracts-v4/src/structs/JBPayHookSpecification.sol";
import {JBBeforePayRecordedContext} from "lib/juice-contracts-v4/src/structs/JBBeforePayRecordedContext.sol";
import {JBBeforeRedeemRecordedContext} from "lib/juice-contracts-v4/src/structs/JBBeforeRedeemRecordedContext.sol";
import {JBRedeemHookSpecification} from "lib/juice-contracts-v4/src/structs/JBRedeemHookSpecification.sol";
import {JBConstants} from "lib/juice-contracts-v4/src/libraries/JBConstants.sol";
import {JBMetadataResolver} from "lib/juice-contracts-v4/src/libraries/JBMetadataResolver.sol";
import {JBBuybackHookPermissionIds} from "./libraries/JBBuybackHookPermissionIds.sol";
import {IJBBuybackHook} from "./interfaces/IJBBuybackHook.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";

/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
/// @notice Generic Buyback Hook compatible with any Juicebox payment terminal and any project token that can be pooled.
/// @notice Functions as a Data Hook and Pay Hook allowing beneficiaries of payments to get the highest amount
/// of a project's token between minting using the project weight and swapping in a given Uniswap V3 pool.
contract JBBuybackHook is ERC165, JBPermissioned, IJBBuybackHook {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error JuiceBuyback_MaximumSlippage();
    error JuiceBuyback_InsufficientPayAmount();
    error JuiceBuyback_NotEnoughTokensReceived();
    error JuiceBuyback_NewSecondsAgoTooLow();
    error JuiceBuyback_NoProjectToken();
    error JuiceBuyback_PoolAlreadySet();
    error JuiceBuyback_TransferFailed();
    error JuiceBuyback_InvalidTwapSlippageTolerance();
    error JuiceBuyback_InvalidTwapWindow();
    error JuiceBuyback_Unauthorized();

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The TWAP max deviation acepted and timeframe to use for the pool twap, packed in a uint256.
    /// @custom:param _projectId The ID of the project to which the TWAP params apply.
    mapping(uint256 _projectId => uint256) internal _twapParamsOf;

    //*********************************************************************//
    // --------------------- public constant properties ------------------ //
    //*********************************************************************//

    /// @notice The unit of the max slippage.
    uint256 public constant SLIPPAGE_DENOMINATOR = 10_000;

    /// @notice The minimum twap deviation allowed, out of MAX_SLIPPAGE.
    /// @dev This serves to avoid operators settings values that force the bypassing the swap when a quote is not
    /// provided in payment metadata.
    uint256 public constant MIN_TWAP_SLIPPAGE_TOLERANCE = 100;

    /// @notice The maximum twap deviation allowed, out of MAX_SLIPPAGE.
    /// @dev This serves to avoid operators settings values that force the bypassing the swap when a quote is not
    /// provided in payment metadata.
    uint256 public constant MAX_TWAP_SLIPPAGE_TOLERANCE = 9000;

    /// @notice The smallest TWAP period allowed, in seconds.
    /// @dev This serves to avoid operators settings values that force the bypassing the swap when a quote is not
    /// provided in payment metadata.
    uint256 public constant MIN_TWAP_WINDOW = 2 minutes;

    /// @notice The largest TWAP period allowed, in seconds.
    /// @dev This serves to avoid operators settings values that force the bypassing the swap when a quote is not
    /// provided in payment metadata.
    uint256 public constant MAX_TWAP_WINDOW = 2 days;

    //*********************************************************************//
    // -------------------- public immutable properties ------------------ //
    //*********************************************************************//

    /// @notice The uniswap v3 factory used to reference pools from.
    address public immutable UNISWAP_V3_FACTORY;

    /// @notice The directory of terminals and controllers.
    IJBDirectory public immutable DIRECTORY;

    /// @notice The controller used to mint and burn tokens from.
    IJBController public immutable CONTROLLER;

    /// @notice The project registry.
    IJBProjects public immutable PROJECTS;

    /// @notice The WETH contract.
    IWETH9 public immutable WETH;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The uniswap pool corresponding to the project token <-> terminal token pair.
    /// @custom:param _projectId The ID of the project to which the pool applies.
    /// @custom:param _terminalToken The address of the token being used to make payments in.
    mapping(uint256 projectId => mapping(address terminalToken => IUniswapV3Pool)) public poolOf;

    /// @notice Each project's token.
    /// @custom:param _projectId The ID of the project to which the token belongs.
    mapping(uint256 projectId => address) public projectTokenOf;

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param weth The WETH contract.
    /// @param factory The uniswap v3 factory used to reference pools from.
    /// @param directory The directory of terminals and controllers.
    /// @param controller The controller used to mint and burn tokens from.
    constructor(
        IWETH9 weth,
        address factory,
        IJBDirectory directory,
        IJBController controller
    )
        JBPermissioned(IJBPermissioned(address(controller)).PERMISSIONS())
    {
        WETH = weth;
        DIRECTORY = directory;
        CONTROLLER = controller;
        UNISWAP_V3_FACTORY = factory;
        PROJECTS = controller.PROJECTS();
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice The DataSource implementation that determines if a swap path and/or a mint path should be taken.
    /// @param context The context passed to the data hook in terminalStore.recordPaymentFrom(..). context.metadata can have a Uniswap quote
    /// and specify how much of the payment should be used to swap, otherwise a quote will be determined from a TWAP and
    /// use the full amount paid in.
    /// @return weight The weight to use, which is the original weight passed in if no swap path is taken, 0 if only the
    /// swap path is taken, and an adjusted weight if the both the swap and mint paths are taken.
    /// @return hookSpecifications The amount to send to delegates instead of adding to the local balance. This is
    /// empty if only the mint path is taken.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        override
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications)
    {
        // Keep a reference to the payment total
        uint256 totalPaid = context.amount.value;

        // Keep a reference to the weight
        weight = context.weight;

        // Keep a reference to the minimum number of tokens expected to be swapped for.
        uint256 minimumSwapAmountOut;

        // Keep a reference to the amount from the payment to allocate towards a swap.
        uint256 amountToSwapWith;

        // Keep a reference to a flag indicating if the quote passed into the metadata exists.
        bool quoteExists;

        // Scoped section to prevent Stack Too Deep.
        {
            bytes memory metadata;

            // The metadata ID is the first 4 bytes of this contract's address.
            bytes4 metadataId = bytes4(bytes20(address(this)));

            // Unpack the quote from the pool, given by the frontend.
            (quoteExists, metadata) = JBMetadataResolver.getDataFor(metadataId, context.metadata);
            if (quoteExists) (amountToSwapWith, minimumSwapAmountOut) = abi.decode(metadata, (uint256, uint256));
        }

        // If no amount was specified to swap with, default to the full amount of the payment.
        if (amountToSwapWith == 0) amountToSwapWith = totalPaid;

        // Find the default total number of tokens to mint as if no Buyback Delegate were installed, as a fixed point
        // number with 18 decimals

        uint256 tokenCountWithoutDelegate = mulDiv(amountToSwapWith, weight, 10 ** context.amount.decimals);

        // Keep a reference to the project's token.
        address projectToken = projectTokenOf[context.projectId];

        // Keep a reference to the token being used by the terminal that is calling this delegate. Use weth is ETH.
        address terminalToken = context.amount.token == JBConstants.NATIVE_TOKEN ? address(WETH) : context.amount.token;

        // If a minimum amount of tokens to swap for wasn't specified, resolve a value as good as possible using a TWAP.
        if (minimumSwapAmountOut == 0) {
            minimumSwapAmountOut = _getQuote(context.projectId, projectToken, amountToSwapWith, terminalToken);
        }

        // If the minimum amount received from swapping is greather than received when minting, use the swap path.
        if (tokenCountWithoutDelegate < minimumSwapAmountOut) {
            // Make sure the amount to swap with is at most the full amount being paid.
            if (amountToSwapWith > totalPaid) revert JuiceBuyback_InsufficientPayAmount();

            // Keep a reference to a flag indicating if the pool will reference the project token as the first in the
            // pair.
            bool projectTokenIs0 = address(projectToken) < terminalToken;

            // Return this delegate as the one to use, while forwarding the amount to swap with. Speficy metadata that
            // allows the swap to be executed.
            hookSpecifications = new JBPayHookSpecification[](1);
            hookSpecifications[0] = JBPayHookSpecification({
                hook: IJBPayHook(this),
                amount: amountToSwapWith,
                metadata: abi.encode(
                    quoteExists,
                    projectTokenIs0,
                    totalPaid == amountToSwapWith ? 0 : totalPaid - amountToSwapWith,
                    minimumSwapAmountOut
                    )
            });

            // All the mint will be done in afterPayRecordedWith, return 0 as weight to avoid minting via the terminal
            return (0, hookSpecifications);
        }
    }

    /// @notice The timeframe to use for the pool TWAP.
    /// @param  projectId The ID of the project for which the value applies.
    /// @return secondsAgo The period over which the TWAP is computed.
    function twapWindowOf(uint256 projectId) external view returns (uint32) {
        return uint32(_twapParamsOf[projectId]);
    }

    /// @notice The TWAP max deviation acepted, out of SLIPPAGE_DENOMINATOR.
    /// @param  projectId The ID of the project for which the value applies.
    /// @return delta the maximum deviation allowed between the token amount received and the TWAP quote.
    function twapSlippageToleranceOf(uint256 projectId) external view returns (uint256) {
        return _twapParamsOf[projectId] >> 128;
    }

    /// @notice For interface completion.
    /// @dev This is a passthrough of the redemption parameters
    /// @param context The redeem data passed by the terminal.
    function beforeRedeemRecordedWith(JBBeforeRedeemRecordedContext calldata context)
        external
        pure
        override
        returns (uint256, JBRedeemHookSpecification[] memory hookSpecifications)
    {
        return (context.reclaimAmount.value, hookSpecifications);
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBRulesetDataHook).interfaceId || interfaceId == type(IJBPayHook).interfaceId
            || interfaceId == type(IJBBuybackHook).interfaceId || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Hooks used to swap a provided amount to the beneficiary, using any leftover amount to mint.
    /// @dev This hook is called only if the quote for the swap is bigger than the quote when minting.
    /// If the swap reverts (slippage, liquidity, etc), the delegate will then mint the same amount of token as if the
    /// delegate was not used.
    /// @param context The hook context passed by the terminal.
    function afterPayRecordedWith(JBAfterPayRecordedContext calldata context) external payable override {
        // Make sure only a payment terminal belonging to the project can access this functionality.
        if (!DIRECTORY.isTerminalOf(context.projectId, IJBTerminal(msg.sender))) {
            revert JuiceBuyback_Unauthorized();
        }

        // Parse the metadata passed in from the data source.
        (bool quoteExists, bool projectTokenIs0, uint256 amountToMintWith, uint256 minimumSwapAmountOut) =
            abi.decode(context.hookMetadata, (bool, bool, uint256, uint256));

        // Get a reference to the amount of tokens that was swapped for.
        uint256 exactSwapAmountOut = _swap(context, projectTokenIs0);

        // Make sure the slippage is tolerable if passed in via an explicit quote.
        if (quoteExists && exactSwapAmountOut < minimumSwapAmountOut) revert JuiceBuyback_MaximumSlippage();

        // Get a reference to any amount of tokens paid in remaining in this contract.
        uint256 terminalTokenInThisContract = context.forwardedAmount.token == JBConstants.NATIVE_TOKEN
            ? address(this).balance
            : IERC20(context.forwardedAmount.token).balanceOf(address(this));

        // Use any leftover amount of tokens paid in remaining to mint.
        // Keep a reference to the number of tokens being minted.
        uint256 partialMintTokenCount;
        if (terminalTokenInThisContract != 0) {
            partialMintTokenCount = mulDiv(terminalTokenInThisContract, context.weight, 10 ** context.amount.decimals);

            // If the token paid in wasn't ETH, give the terminal permission to pull them back into its balance.
            if (context.forwardedAmount.token != JBConstants.NATIVE_TOKEN) {
                IERC20(context.forwardedAmount.token).approve(msg.sender, terminalTokenInThisContract);
            }

            // Keep a reference to the amount being paid.
            uint256 payValue = context.forwardedAmount.token == JBConstants.NATIVE_TOKEN ? terminalTokenInThisContract : 0;

            // Add the paid amount back to the project's terminal balance.
            IJBMultiTerminal(msg.sender).addToBalanceOf{value: payValue}({
                projectId: context.projectId,
                token: context.forwardedAmount.token,
                amount: terminalTokenInThisContract,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });

            emit BuybackDelegate_Mint(context.projectId, terminalTokenInThisContract, partialMintTokenCount, msg.sender);
        }

        // Add amount to mint to leftover mint amount (avoiding stack too deep here)
        partialMintTokenCount += mulDiv(amountToMintWith, context.weight, 10 ** context.amount.decimals);

        // Mint the whole amount of tokens again together with the (optional partial mint), such that the correct
        // portion of reserved tokens get taken into account.
        CONTROLLER.mintTokensOf({
            projectId: context.projectId,
            tokenCount: exactSwapAmountOut + partialMintTokenCount,
            beneficiary: address(context.beneficiary),
            memo: "",
            useReservedRate: true
        });
    }

    /// @notice The Uniswap V3 pool callback where the token transfer is expected to happen.
    /// @param amount0Delta The amount of token 0 being used for the swap.
    /// @param amount1Delta The amount of token 1 being used for the swap.
    /// @param data Data passed in by the swap operation.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external override {
        // Unpack the data passed in through the swap hook.
        (uint256 projectId, address terminalToken) = abi.decode(data, (uint256, address));

        // Get the terminal token, using WETH if the token paid in is ETH.
        address terminalTokenWithWETH = terminalToken == JBConstants.NATIVE_TOKEN ? address(WETH) : terminalToken;

        // Make sure this call is being made from within the swap execution.
        if (msg.sender != address(poolOf[projectId][terminalTokenWithWETH])) revert JuiceBuyback_Unauthorized();

        // Keep a reference to the amount of tokens that should be sent to fulfill the swap (the positive delta)
        uint256 amountToSendToPool = amount0Delta < 0 ? uint256(amount1Delta) : uint256(amount0Delta);

        // Wrap ETH into WETH if relevant (do not rely on ETH delegate balance to support pure WETH terminals)
        if (terminalToken == JBConstants.NATIVE_TOKEN) WETH.deposit{value: amountToSendToPool}();

        // Transfer the token to the pool.
        IERC20(terminalTokenWithWETH).transfer(msg.sender, amountToSendToPool);
    }

    /// @notice Add a pool for a given project. This pool the becomes the default for a given token project <-->
    /// terminal token pair.
    /// @dev Uses create2 for callback auth and allows adding a pool not deployed yet.
    /// This can be called by the project owner or an address having the SET_POOL permission in JBPermissions
    /// @param projectId The ID of the project having its pool set.
    /// @param fee The fee that is used in the pool being set.
    /// @param twapWindow The period over which the TWAP is computed.
    /// @param twapSlippageTolerance The maximum deviation allowed between amount received and TWAP.
    /// @param terminalToken The terminal token that payments are made in.
    /// @return newPool The pool that was created.
    function setPoolFor(
        uint256 projectId,
        uint24 fee,
        uint32 twapWindow,
        uint256 twapSlippageTolerance,
        address terminalToken
    )
        external
        returns (IUniswapV3Pool newPool)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBBuybackHookPermissionIds.CHANGE_POOL
        });

        // Make sure the provided delta is within sane bounds.
        if (twapSlippageTolerance < MIN_TWAP_SLIPPAGE_TOLERANCE || twapSlippageTolerance > MAX_TWAP_SLIPPAGE_TOLERANCE)
        {
            revert JuiceBuyback_InvalidTwapSlippageTolerance();
        }

        // Make sure the provided period is within sane bounds.
        if (twapWindow < MIN_TWAP_WINDOW || twapWindow > MAX_TWAP_WINDOW) revert JuiceBuyback_InvalidTwapWindow();

        // Keep a reference to the project's token.
        address projectToken = address(CONTROLLER.TOKENS().tokenOf(projectId));

        // Make sure the project has issued a token.
        if (projectToken == address(0)) revert JuiceBuyback_NoProjectToken();

        // If the terminal token specified in ETH, use WETH instead.
        if (terminalToken == JBConstants.NATIVE_TOKEN) terminalToken = address(WETH);

        // Keep a reference to a flag indicating if the pool will reference the project token as the first in the pair.
        bool projectTokenIs0 = address(projectToken) < terminalToken;

        // Compute the corresponding pool's address, which is a function of both tokens and the specified fee.
        newPool = IUniswapV3Pool(
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                UNISWAP_V3_FACTORY,
                                keccak256(
                                    abi.encode(
                                        projectTokenIs0 ? projectToken : terminalToken,
                                        projectTokenIs0 ? terminalToken : projectToken,
                                        fee
                                    )
                                ),
                                // POOL_INIT_CODE_HASH from
                                // https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/PoolAddress.sol
                                bytes32(0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54)
                            )
                        )
                    )
                )
            )
        );

        // Make sure this pool has yet to be specified in this delegate.
        if (poolOf[projectId][terminalToken] == newPool) revert JuiceBuyback_PoolAlreadySet();

        // Store the pool.
        poolOf[projectId][terminalToken] = newPool;

        // Store the twap period and max slipage.
        _twapParamsOf[projectId] = twapSlippageTolerance << 128 | twapWindow;
        projectTokenOf[projectId] = address(projectToken);

        emit BuybackDelegate_TwapWindowChanged(projectId, 0, twapWindow, msg.sender);
        emit BuybackDelegate_TwapSlippageToleranceChanged(projectId, 0, twapSlippageTolerance, msg.sender);
        emit BuybackDelegate_PoolAdded(projectId, terminalToken, address(newPool), msg.sender);
    }

    /// @notice Increase the period over which the TWAP is computed.
    /// @dev This can be called by the project owner or an address having the SET_TWAP_PERIOD permission in
    /// JBPermissions.
    /// @param projectId The ID for which the new value applies.
    /// @param newWindow The new TWAP period.
    function setTwapWindowOf(uint256 projectId, uint32 newWindow) external {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBBuybackHookPermissionIds.SET_POOL_PARAMS
        });

        // Make sure the provided period is within sane bounds.
        if (newWindow < MIN_TWAP_WINDOW || newWindow > MAX_TWAP_WINDOW) {
            revert JuiceBuyback_InvalidTwapWindow();
        }

        // Keep a reference to the currently stored TWAP params.
        uint256 twapParams = _twapParamsOf[projectId];

        // Keep a reference to the old window value.
        uint256 oldWindow = uint128(twapParams);

        // Store the new packed value of the TWAP params.
        _twapParamsOf[projectId] = uint256(newWindow) | ((twapParams >> 128) << 128);

        emit BuybackDelegate_TwapWindowChanged(projectId, oldWindow, newWindow, msg.sender);
    }

    /// @notice Set the maximum deviation allowed between amount received and TWAP.
    /// @dev This can be called by the project owner or an address having the SET_POOL permission in JBPermissions.
    /// @param projectId The ID for which the new value applies.
    /// @param newSlippageTolerance the new delta, out of SLIPPAGE_DENOMINATOR.
    function setTwapSlippageToleranceOf(uint256 projectId, uint256 newSlippageTolerance) external {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBBuybackHookPermissionIds.SET_POOL_PARAMS
        });

        // Make sure the provided delta is within sane bounds.
        if (newSlippageTolerance < MIN_TWAP_SLIPPAGE_TOLERANCE || newSlippageTolerance > MAX_TWAP_SLIPPAGE_TOLERANCE) {
            revert JuiceBuyback_InvalidTwapSlippageTolerance();
        }

        // Keep a reference to the currently stored TWAP params.
        uint256 twapParams = _twapParamsOf[projectId];

        // Keep a reference to the old slippage value.
        uint256 oldSlippageTolerance = twapParams >> 128;

        // Store the new packed value of the TWAP params.
        _twapParamsOf[projectId] = newSlippageTolerance << 128 | ((twapParams << 128) >> 128);

        emit BuybackDelegate_TwapSlippageToleranceChanged(
            projectId, oldSlippageTolerance, newSlippageTolerance, msg.sender
        );
    }

    //*********************************************************************//
    // ---------------------- internal functions ------------------------- //
    //*********************************************************************//

    /// @notice Get a quote based on TWAP over a secondsAgo period, taking into account a twapDelta max deviation.
    /// @param projectId The ID of the project for which the swap is being made.
    /// @param projectToken The project's token being swapped for.
    /// @param amountIn The amount being used to swap.
    /// @param terminalToken The token paid in being used to swap.
    /// @return amountOut the minimum amount received according to the TWAP.
    function _getQuote(
        uint256 projectId,
        address projectToken,
        uint256 amountIn,
        address terminalToken
    )
        internal
        view
        returns (uint256 amountOut)
    {
        // Get a reference to the pool that'll be used to make the swap.
        IUniswapV3Pool pool = poolOf[projectId][address(terminalToken)];

        // Make sure the pool exists.
        try pool.slot0() returns (uint160, int24, uint16, uint16, uint16, uint8, bool unlocked) {
            // If the pool hasn't been initialized, return an empty quote.
            if (!unlocked) return 0;
        } catch {
            // If the address is invalid or if the pool has not yet been deployed, return an empty quote.
            return 0;
        }

        // Unpack the TWAP params and get a reference to the period and slippage.
        uint256 twapParams = _twapParamsOf[projectId];
        uint32 quotePeriod = uint32(twapParams);
        uint256 maxDelta = twapParams >> 128;

        // Keep a reference to the TWAP tick.
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(pool), quotePeriod);

        // Get a quote based on this TWAP tick.
        amountOut = OracleLibrary.getQuoteAtTick({
            tick: arithmeticMeanTick,
            baseAmount: uint128(amountIn),
            baseToken: terminalToken,
            quoteToken: address(projectToken)
        });

        // Return the lowest TWAP tolerable.
        amountOut -= (amountOut * maxDelta) / SLIPPAGE_DENOMINATOR;
    }

    /// @notice Swap the terminal token to receive the project token.
    /// @param data The afterPayRecordedContext passed by the terminal.
    /// @param projectTokenIs0 A flag indicating if the pool will reference the project token as the first in the pair.
    /// @return amountReceived The amount of tokens received from the swap.
    function _swap(JBAfterPayRecordedContext calldata data, bool projectTokenIs0) internal returns (uint256 amountReceived) {
        // The amount of tokens that are being used with which to make the swap.
        uint256 amountToSwapWith = data.forwardedAmount.value;

        // Get the terminal token, using WETH if the token paid in is ETH.
        address terminalTokenWithWETH =
            data.forwardedAmount.token == JBConstants.NATIVE_TOKEN ? address(WETH) : data.forwardedAmount.token;

        // Get a reference to the pool that'll be used to make the swap.
        IUniswapV3Pool pool = poolOf[data.projectId][terminalTokenWithWETH];

        // Try swapping.
        try pool.swap({
            recipient: address(this),
            zeroForOne: !projectTokenIs0,
            amountSpecified: int256(amountToSwapWith),
            sqrtPriceLimitX96: projectTokenIs0 ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
            data: abi.encode(data.projectId, data.forwardedAmount.token)
        }) returns (int256 amount0, int256 amount1) {
            // If the swap succeded, take note of the amount of tokens received. This will return as negative since it
            // is an exact input.
            amountReceived = uint256(-(projectTokenIs0 ? amount0 : amount1));
        } catch {
            // If the swap failed, return.
            return 0;
        }

        // Burn the whole amount received.
        CONTROLLER.burnTokensOf({holder: address(this), projectId: data.projectId, tokenCount: amountReceived, memo: ""});

        // We return the amount we received/burned and we will mint them to the user later

        emit BuybackDelegate_Swap(data.projectId, amountToSwapWith, pool, amountReceived, msg.sender);
    }
}
