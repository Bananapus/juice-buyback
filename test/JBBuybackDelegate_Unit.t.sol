// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "src/interfaces/external/IWETH9.sol";
import "./helpers/TestBaseWorkflowV3.sol";

import "lib/juice-contracts-v4/src/interfaces/IJBController.sol";
import "lib/juice-contracts-v4/src/interfaces/IJBDirectory.sol";
import "lib/juice-contracts-v4/src/interfaces/IJBRedeemHook.sol";
import "lib/juice-contracts-v4/src/libraries/JBConstants.sol";

import {MetadataResolverHelper} from "lib/juice-contracts-v4/src/../test/helpers/MetadataResolverHelper.sol";

import "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol";
import "lib/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import "lib/forge-std/src/Test.sol";

import "./helpers/PoolAddress.sol";
import "src/JBBuybackHook.sol";
import "src/libraries/JBBuybackHookPermissionIds.sol";

/**
 * @notice Unit tests for the JBBuybackHook contract.
 *
 */
contract TestJBBuybackHook_Units is Test {
    using stdStorage for StdStorage;

    ForTest_JBBuybackHook hook;

    event BuybackDelegate_Swap(
        uint256 indexed projectId, uint256 amountIn, IUniswapV3Pool pool, uint256 amountOut, address caller
    );
    event BuybackDelegate_Mint(uint256 indexed projectId, uint256 amount, uint256 tokenCount, address caller);
    event BuybackDelegate_TwapWindowChanged(
        uint256 indexed projectId, uint256 oldSecondsAgo, uint256 newSecondsAgo, address caller
    );
    event BuybackDelegate_TwapSlippageToleranceChanged(
        uint256 indexed projectId, uint256 oldTwapDelta, uint256 newTwapDelta, address caller
    );
    event BuybackDelegate_PoolAdded(
        uint256 indexed projectId, address indexed terminalToken, address newPool, address caller
    );

    // Use the L1 UniswapV3Pool jbx/eth 1% fee for create2 magic
    IUniswapV3Pool pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);
    IERC20 projectToken = IERC20(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);
    IWETH9 weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint24 fee = 10_000;

    // A random non-weth pool: The PulseDogecoin Staking Carnival Token/HEX @ 0.3%
    IERC20 otherRandomProjectToken = IERC20(0x2b591e99afE9f32eAA6214f7B7629768c40Eeb39);
    IERC20 randomTerminalToken = IERC20(0x488Db574C77dd27A07f9C97BAc673BC8E9fC6Bf3);
    IUniswapV3Pool randomPool = IUniswapV3Pool(0x7668B2Ea8490955F68F5c33E77FE150066c94fb9);
    uint24 randomFee = 3000;
    uint256 randomId = 420;

    address uniswapFactory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;

    IJBMultiTerminal multiTerminal = IJBMultiTerminal(makeAddr("IJBMultiTerminal"));
    IJBProjects projects = IJBProjects(makeAddr("IJBProjects"));
    IJBPermissions permissions = IJBPermissions(makeAddr("IJBPermissions"));
    IJBController controller = IJBController(makeAddr("controller"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    IJBTokens tokens = IJBTokens(makeAddr("tokens"));

    MetadataResolverHelper metadataHelper = new MetadataResolverHelper();

    address terminalStore = makeAddr("terminalStore");

    address dude = makeAddr("dude");
    address owner = makeAddr("owner");

    uint32 secondsAgo = 100;
    uint256 twapDelta = 100;

    uint256 projectId = 69;

    JBBeforePayRecordedContext beforePayRecordedContext = JBBeforePayRecordedContext({
        terminal: address(multiTerminal),
        payer: dude,
        amount: JBTokenAmount({token: address(weth), value: 1 ether, decimals: 18, currency: 1}),
        projectId: projectId,
        rulesetId: 0,
        beneficiary: dude,
        weight: 69,
        reservedRate: 0,
        metadata: ""
    });

    JBAfterPayRecordedContext afterPayRecordedContext = JBAfterPayRecordedContext({
        payer: dude,
        projectId: projectId,
        rulesetId: 0,
        amount: JBTokenAmount({token: JBConstants.NATIVE_TOKEN, value: 1 ether, decimals: 18, currency: 1}),
        forwardedAmount: JBTokenAmount({token: JBConstants.NATIVE_TOKEN, value: 1 ether, decimals: 18, currency: 1}),
        weight: 1,
        projectTokenCount: 69,
        beneficiary: dude,
        hookMetadata: "",
        payerMetadata: ""
    });

    function setUp() external {
        vm.etch(address(projectToken), "6969");
        vm.etch(address(weth), "6969");
        vm.etch(address(pool), "6969");
        vm.etch(address(multiTerminal), "6969");
        vm.etch(address(projects), "6969");
        vm.etch(address(permissions), "6969");
        vm.etch(address(controller), "6969");
        vm.etch(address(directory), "6969");

        vm.label(address(pool), "pool");
        vm.label(address(projectToken), "projectToken");
        vm.label(address(weth), "weth");

        vm.mockCall(address(multiTerminal), abi.encodeCall(multiTerminal.STORE, ()), abi.encode(terminalStore));
        vm.mockCall(address(controller), abi.encodeCall(IJBPermissioned.PERMISSIONS, ()), abi.encode(permissions));
        vm.mockCall(address(controller), abi.encodeCall(controller.PROJECTS, ()), abi.encode(projects));

        vm.mockCall(address(projects), abi.encodeCall(projects.ownerOf, (projectId)), abi.encode(owner));

        vm.mockCall(address(controller), abi.encodeCall(controller.TOKENS, ()), abi.encode(tokens));

        vm.prank(owner);
        hook = new ForTest_JBBuybackHook({
            weth: weth,
            factory: uniswapFactory,
            directory: directory,
            controller: controller
        });

        hook.ForTest_initPool(pool, projectId, secondsAgo, twapDelta, address(projectToken), address(weth));
        hook.ForTest_initPool(
            randomPool, randomId, secondsAgo, twapDelta, address(otherRandomProjectToken), address(randomTerminalToken)
        );
    }

    /**
     * @notice Test beforePayRecordedWith when a quote is provided as metadata
     *
     * @dev    _tokenCount == weight, as we use a value of 1.
     */
    function test_beforePayRecordedWith_callWithQuote(
        uint256 weight,
        uint256 swapOutCount,
        uint256 amountIn,
        uint256 decimals
    )
        public
    {
        // Avoid accidentally using the twap (triggered if out == 0)
        swapOutCount = bound(swapOutCount, 1, type(uint256).max);

        // Avoid mulDiv overflow
        weight = bound(weight, 1, 1 ether);

        // Use between 1 wei and the whole amount from pay(..)
        amountIn = bound(amountIn, 1, beforePayRecordedContext.amount.value);

        // The terminal token decimals
        decimals = bound(decimals, 1, 18);

        uint256 tokenCount = mulDiv(amountIn, weight, 10 ** decimals);

        // Pass the quote as metadata
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(amountIn, swapOutCount);

        // Pass the delegate id
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = bytes4(bytes20(address(hook)));

        // Generate the metadata
        bytes memory metadata = metadataHelper.createMetadata(ids, data);

        // Set the relevant context
        beforePayRecordedContext.weight = weight;
        beforePayRecordedContext.metadata = metadata;
        beforePayRecordedContext.amount =
            JBTokenAmount({token: address(weth), value: 1 ether, decimals: decimals, currency: 1});

        // Returned values to catch:
        JBPayHookSpecification[] memory allocationsReturned;
        uint256 weightReturned;

        // Test: call beforePayRecordedContext
        vm.prank(terminalStore);
        (weightReturned, allocationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // Mint pathway if more token received when minting:
        if (tokenCount >= swapOutCount) {
            // No delegate allocation returned
            assertEq(allocationsReturned.length, 0, "Wrong allocation length");

            // weight unchanged
            assertEq(weightReturned, weight, "Weight isn't unchanged");
        }
        // Swap pathway (return the delegate allocation)
        else {
            assertEq(allocationsReturned.length, 1, "Wrong allocation length");
            assertEq(address(allocationsReturned[0].hook), address(hook), "wrong delegate address returned");
            assertEq(allocationsReturned[0].amount, amountIn, "worng amount in returned");
            assertEq(
                allocationsReturned[0].metadata,
                abi.encode(
                    true,
                    address(projectToken) < address(weth),
                    beforePayRecordedContext.amount.value - amountIn,
                    swapOutCount
                ),
                "wrong metadata"
            );

            assertEq(weightReturned, 0, "wrong weight returned (if swapping)");
        }
    }

    /**
     * @notice Test beforePayRecordedContext when no quote is provided, falling back on the pool twap
     *
     * @dev    This bypass testing Uniswap Oracle lib by re-using the internal _getQuote
     */
    function test_beforePayRecordedContext_useTwap(uint256 tokenCount) public {
        // Set the relevant context
        beforePayRecordedContext.weight = tokenCount;
        beforePayRecordedContext.metadata = "";

        // Mock the pool being unlocked
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, true));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Mock the pool's twap
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        uint160[] memory secondPerLiquidity = new uint160[](2);
        secondPerLiquidity[0] = 100;
        secondPerLiquidity[1] = 1000;

        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 100;
        tickCumulatives[1] = 1000;

        vm.mockCall(
            address(pool), abi.encodeCall(pool.observe, (secondsAgos)), abi.encode(tickCumulatives, secondPerLiquidity)
        );
        vm.expectCall(address(pool), abi.encodeCall(pool.observe, (secondsAgos)));

        // Returned values to catch:
        JBPayHookSpecification[] memory allocationsReturned;
        uint256 weightReturned;

        // Test: call beforePayRecordedWith
        vm.prank(terminalStore);
        (weightReturned, allocationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // Bypass testing uniswap oracle lib
        uint256 twapAmountOut = hook.ForTest_getQuote(projectId, address(projectToken), 1 ether, address(weth));

        // Mint pathway if more token received when minting:
        if (tokenCount >= twapAmountOut) {
            // No delegate allocation returned
            assertEq(allocationsReturned.length, 0);

            // weight unchanged
            assertEq(weightReturned, tokenCount);
        }
        // Swap pathway (set the mutexes and return the delegate allocation)
        else {
            assertEq(allocationsReturned.length, 1);
            assertEq(address(allocationsReturned[0].hook), address(hook));
            assertEq(allocationsReturned[0].amount, 1 ether);

            assertEq(
                allocationsReturned[0].metadata,
                abi.encode(false, address(projectToken) < address(weth), 0, twapAmountOut),
                "wrong metadata"
            );

            assertEq(weightReturned, 0);
        }
    }

    /**
     * @notice Test beforePayRecordedWith with a twap but locked pool, which should then mint
     */
    function test_beforePayRecordedContext_useTwapLockedPool(uint256 tokenCount) public {
        tokenCount = bound(tokenCount, 1, type(uint120).max);

        // Set the relevant context
        beforePayRecordedContext.weight = tokenCount;
        beforePayRecordedContext.metadata = "";

        // Mock the pool being unlocked
        vm.mockCall(address(pool), abi.encodeCall(pool.slot0, ()), abi.encode(0, 0, 0, 0, 0, 0, false));
        vm.expectCall(address(pool), abi.encodeCall(pool.slot0, ()));

        // Returned values to catch:
        JBPayHookSpecification[] memory allocationsReturned;
        uint256 weightReturned;

        // Test: call beforePayRecorded
        vm.prank(terminalStore);
        (weightReturned, allocationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);

        // No delegate allocation returned
        assertEq(allocationsReturned.length, 0);

        // weight unchanged
        assertEq(weightReturned, tokenCount);
    }

    /**
     * @notice Test beforePayRecordedWith when an amount to swap with greather than the token send is passed
     */
    function test_beforePayRecorded_RevertIfTryingToOverspend(uint256 swapOutCount, uint256 amountIn) public {
        // Use anything more than the amount sent
        amountIn = bound(amountIn, beforePayRecordedContext.amount.value + 1, type(uint128).max);

        uint256 weight = 1 ether;

        uint256 tokenCount = mulDiv(amountIn, weight, 10 ** 18);

        // Avoid accidentally using the twap (triggered if out == 0)
        swapOutCount = bound(swapOutCount, tokenCount + 1, type(uint256).max);

        // Pass the quote as metadata
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(amountIn, swapOutCount);

        // Pass the delegate id
        bytes4[] memory ids = new bytes4[](1);
        ids[0] = bytes4(bytes20(address(hook)));

        // Generate the metadata
        bytes memory metadata = metadataHelper.createMetadata(ids, data);

        // Set the relevant context
        beforePayRecordedContext.weight = weight;
        beforePayRecordedContext.metadata = metadata;

        // Returned values to catch:
        JBPayHookSpecification[] memory allocationsReturned;
        uint256 weightReturned;

        vm.expectRevert(JBBuybackHook.JuiceBuyback_InsufficientPayAmount.selector);

        // Test: call beforePayRecorded
        vm.prank(terminalStore);
        (weightReturned, allocationsReturned) = hook.beforePayRecordedWith(beforePayRecordedContext);
    }

    /**
     * @notice Test afterPayRecordedWith with token received from swapping, within slippage and no leftover in the
     * delegate
     */
    function test_didPay_swap_ETH(uint256 tokenCount, uint256 twapQuote) public {
        // Bound to avoid overflow and insure swap quote > mint quote
        tokenCount = bound(tokenCount, 2, type(uint256).max - 1);
        twapQuote = bound(twapQuote, tokenCount + 1, type(uint256).max);

        afterPayRecordedContext.weight = twapQuote;

        // The metadata coming from beforePayRecordedContext(..)
        afterPayRecordedContext.hookMetadata = abi.encode(
            true, // use quote
            address(projectToken) < address(weth),
            0,
            tokenCount
        );

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            ),
            abi.encode(-int256(twapQuote), -int256(twapQuote))
        );
        vm.expectCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            )
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // mock the burn call
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, "")),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, ""))
        );

        // mock the minting call
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            )
        );

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(
            afterPayRecordedContext.projectId,
            afterPayRecordedContext.amount.value,
            pool,
            twapQuote,
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /**
     * @notice Test afterPayRecordedWith with token received from swapping, within slippage and no leftover in the
     * delegate
     */
    function test_didPay_swap_ETH_with_extrafunds(uint256 tokenCount, uint256 twapQuote) public {
        // Bound to avoid overflow and insure swap quote > mint quote
        tokenCount = bound(tokenCount, 2, type(uint256).max - 1);
        twapQuote = bound(twapQuote, tokenCount + 1, type(uint256).max);

        afterPayRecordedContext.weight = twapQuote;

        // The metadata coming from beforePayRecordedWith(..)
        afterPayRecordedContext.hookMetadata = abi.encode(
            true, // use quote
            address(projectToken) < address(weth),
            0,
            twapQuote
        );

        // mock the swap call
        vm.mockCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            ),
            abi.encode(-int256(twapQuote), -int256(twapQuote))
        );
        vm.expectCall(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, JBConstants.NATIVE_TOKEN)
                )
            )
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // mock the burn call
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, "")),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, ""))
        );

        // mock the minting call
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            )
        );

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(
            afterPayRecordedContext.projectId,
            afterPayRecordedContext.amount.value,
            pool,
            twapQuote,
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /**
     * @notice Test afterPayRecordedWith with token received from swapping
     */
    function test_didPay_swap_ERC20(uint256 tokenCount, uint256 twapQuote, uint256 decimals) public {
        // Bound to avoid overflow and insure swap quote > mint quote
        tokenCount = bound(tokenCount, 2, type(uint256).max - 1);
        twapQuote = bound(twapQuote, tokenCount + 1, type(uint256).max);

        decimals = bound(decimals, 1, 18);

        afterPayRecordedContext.amount =
            JBTokenAmount({token: address(randomTerminalToken), value: 1 ether, decimals: decimals, currency: 1});
        afterPayRecordedContext.forwardedAmount =
            JBTokenAmount({token: address(randomTerminalToken), value: 1 ether, decimals: decimals, currency: 1});
        afterPayRecordedContext.projectId = randomId;
        afterPayRecordedContext.weight = twapQuote;

        // The metadata coming from beforePayRecordedWith(..)
        afterPayRecordedContext.hookMetadata = abi.encode(
            true, // use quote
            address(projectToken) < address(weth),
            0,
            tokenCount
        );

        // mock the swap call
        vm.mockCall(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(hook),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(1 ether),
                    address(otherRandomProjectToken) < address(randomTerminalToken)
                        ? TickMath.MAX_SQRT_RATIO - 1
                        : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, randomTerminalToken)
                )
            ),
            abi.encode(-int256(twapQuote), -int256(twapQuote))
        );
        vm.expectCall(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(hook),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(1 ether),
                    address(otherRandomProjectToken) < address(randomTerminalToken)
                        ? TickMath.MAX_SQRT_RATIO - 1
                        : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, randomTerminalToken)
                )
            )
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // mock the burn call
        vm.mockCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, "")),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(controller.burnTokensOf, (address(hook), afterPayRecordedContext.projectId, twapQuote, ""))
        );

        // mock the minting call
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf, (afterPayRecordedContext.projectId, twapQuote, address(dude), "", true)
            )
        );

        // No leftover
        vm.mockCall(
            address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(hook))), abi.encode(0)
        );
        vm.expectCall(address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(hook))));

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Swap(
            afterPayRecordedContext.projectId,
            afterPayRecordedContext.amount.value,
            randomPool,
            twapQuote,
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /**
     * @notice Test afterPayRecordedWith with swap reverting / returning 0, while a non-0 quote was provided
     */
    function test_didPay_swapRevertWithQuote(uint256 tokenCount) public {
        tokenCount = bound(tokenCount, 1, type(uint256).max - 1);

        afterPayRecordedContext.weight = 1 ether; // weight - unused

        // The metadata coming from beforePayRecordedWith(..)
        afterPayRecordedContext.hookMetadata = abi.encode(
            true, // use quote
            address(projectToken) < address(weth),
            0,
            tokenCount
        );

        // mock the swap call reverting
        vm.mockCallRevert(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(1 ether),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, weth)
                )
            ),
            abi.encode("no swap")
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        vm.expectRevert(JBBuybackHook.JuiceBuyback_MaximumSlippage.selector);

        vm.prank(address(multiTerminal));
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /**
     * @notice Test afterPayRecordedWith with swap reverting while using the twap, should then mint with the delegate
     * balance, random
     * erc20 is terminal token
     */
    function test_didPay_swapRevertWithoutQuote_ERC20(
        uint256 tokenCount,
        uint256 weight,
        uint256 decimals,
        uint256 extraMint
    )
        public
    {
        // The current weight
        weight = bound(weight, 1, 1 ether);

        // The amount of termminal token in this delegate (avoid overflowing when mul by weight)
        tokenCount = bound(tokenCount, 2, type(uint128).max);

        // An extra amount of token to mint, based on fund which stayed in the terminal
        extraMint = bound(extraMint, 2, type(uint128).max);

        // The terminal token decimal
        decimals = bound(decimals, 1, 18);

        afterPayRecordedContext.amount =
            JBTokenAmount({token: address(randomTerminalToken), value: tokenCount, decimals: decimals, currency: 1});
        afterPayRecordedContext.forwardedAmount =
            JBTokenAmount({token: address(randomTerminalToken), value: tokenCount, decimals: decimals, currency: 1});
        afterPayRecordedContext.projectId = randomId;
        afterPayRecordedContext.weight = weight;

        // The metadata coming from beforePayRecordedWith(..)
        afterPayRecordedContext.hookMetadata = abi.encode(
            false, // use quote
            address(otherRandomProjectToken) < address(randomTerminalToken),
            extraMint, // extra amount to mint with
            tokenCount
        );

        // mock the swap call reverting
        vm.mockCallRevert(
            address(randomPool),
            abi.encodeCall(
                randomPool.swap,
                (
                    address(hook),
                    address(randomTerminalToken) < address(otherRandomProjectToken),
                    int256(tokenCount),
                    address(otherRandomProjectToken) < address(randomTerminalToken)
                        ? TickMath.MAX_SQRT_RATIO - 1
                        : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(randomId, randomTerminalToken)
                )
            ),
            abi.encode("no swap")
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // Mock the balance check
        vm.mockCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.balanceOf, (address(hook))),
            abi.encode(tokenCount)
        );
        vm.expectCall(address(randomTerminalToken), abi.encodeCall(randomTerminalToken.balanceOf, (address(hook))));

        // mock the minting call - this uses the weight and not the (potentially faulty) quote or twap
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (
                    afterPayRecordedContext.projectId,
                    mulDiv(tokenCount, weight, 10 ** decimals) + mulDiv(extraMint, weight, 10 ** decimals),
                    afterPayRecordedContext.beneficiary,
                    "",
                    true
                )
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (
                    afterPayRecordedContext.projectId,
                    mulDiv(tokenCount, weight, 10 ** decimals) + mulDiv(extraMint, weight, 10 ** decimals),
                    afterPayRecordedContext.beneficiary,
                    "",
                    true
                )
            )
        );

        // Mock the approval for the addToBalance
        vm.mockCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.approve, (address(multiTerminal), tokenCount)),
            abi.encode(true)
        );
        vm.expectCall(
            address(randomTerminalToken),
            abi.encodeCall(randomTerminalToken.approve, (address(multiTerminal), tokenCount))
        );

        // mock the add to balance adding the terminal token back to the terminal
        vm.mockCall(
            address(multiTerminal),
            abi.encodeCall(
                IJBTerminal(address(multiTerminal)).addToBalanceOf,
                (afterPayRecordedContext.projectId, address(randomTerminalToken), tokenCount, false, "", "")
            ),
            ""
        );
        vm.expectCall(
            address(multiTerminal),
            abi.encodeCall(
                IJBTerminal(address(multiTerminal)).addToBalanceOf,
                (afterPayRecordedContext.projectId, address(randomTerminalToken), tokenCount, false, "", "")
            )
        );

        // expect event - only for the non-extra mint
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Mint(
            afterPayRecordedContext.projectId,
            tokenCount,
            mulDiv(tokenCount, weight, 10 ** decimals),
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /**
     * @notice Test afterPayRecordedWith with swap reverting while using the twap, should then mint with the delegate
     * balance, random
     * erc20 is terminal token
     */
    function test_didPay_swapRevertWithoutQuote_ETH(
        uint256 tokenCount,
        uint256 weight,
        uint256 decimals,
        uint256 extraMint
    )
        public
    {
        // The current weight
        weight = bound(weight, 1, 1 ether);

        // The amount of termminal token in this delegate (avoid overflowing when mul by weight)
        tokenCount = bound(tokenCount, 2, type(uint128).max);

        // An extra amount of token to mint, based on fund which stayed in the terminal
        extraMint = bound(extraMint, 2, type(uint128).max);

        // The terminal token decimal
        decimals = bound(decimals, 1, 18);

        afterPayRecordedContext.amount =
            JBTokenAmount({token: JBConstants.NATIVE_TOKEN, value: tokenCount, decimals: decimals, currency: 1});

        afterPayRecordedContext.forwardedAmount =
            JBTokenAmount({token: JBConstants.NATIVE_TOKEN, value: tokenCount, decimals: decimals, currency: 1});

        afterPayRecordedContext.weight = weight;

        // The metadata coming from beforePayRecordedwith(..)
        afterPayRecordedContext.hookMetadata = abi.encode(
            false, // use quote
            address(projectToken) < address(weth),
            extraMint,
            tokenCount
        );

        // mock the swap call reverting
        vm.mockCallRevert(
            address(pool),
            abi.encodeCall(
                pool.swap,
                (
                    address(hook),
                    address(weth) < address(projectToken),
                    int256(tokenCount),
                    address(projectToken) < address(weth) ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1,
                    abi.encode(projectId, weth)
                )
            ),
            abi.encode("no swap")
        );

        // mock call to pass the authorization check
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(multiTerminal)))
            )
        );

        // Mock the balance check
        vm.deal(address(hook), tokenCount);

        // mock the minting call - this uses the weight and not the (potentially faulty) quote or twap
        vm.mockCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (
                    afterPayRecordedContext.projectId,
                    mulDiv(tokenCount, weight, 10 ** decimals) + mulDiv(extraMint, weight, 10 ** decimals),
                    afterPayRecordedContext.beneficiary,
                    "",
                    true
                )
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(controller),
            abi.encodeCall(
                controller.mintTokensOf,
                (
                    afterPayRecordedContext.projectId,
                    mulDiv(tokenCount, weight, 10 ** decimals) + mulDiv(extraMint, weight, 10 ** decimals),
                    afterPayRecordedContext.beneficiary,
                    "",
                    true
                )
            )
        );

        // mock the add to balance adding the terminal token back to the terminal
        vm.mockCall(
            address(multiTerminal),
            tokenCount,
            abi.encodeCall(
                IJBTerminal(address(multiTerminal)).addToBalanceOf,
                (afterPayRecordedContext.projectId, JBConstants.NATIVE_TOKEN, tokenCount, false, "", "")
            ),
            ""
        );
        vm.expectCall(
            address(multiTerminal),
            tokenCount,
            abi.encodeCall(
                IJBTerminal(address(multiTerminal)).addToBalanceOf,
                (afterPayRecordedContext.projectId, JBConstants.NATIVE_TOKEN, tokenCount, false, "", "")
            )
        );

        // expect event
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_Mint(
            afterPayRecordedContext.projectId,
            tokenCount,
            mulDiv(tokenCount, weight, 10 ** decimals),
            address(multiTerminal)
        );

        vm.prank(address(multiTerminal));
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /**
     * @notice Test afterPayRecordedWith revert if wrong caller
     */
    function test_didPay_revertIfWrongCaller(address notTerminal) public {
        vm.assume(notTerminal != address(multiTerminal));

        // mock call to fail at the authorization check since directory has no bytecode
        vm.mockCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(notTerminal)))
            ),
            abi.encode(false)
        );
        vm.expectCall(
            address(directory),
            abi.encodeCall(
                directory.isTerminalOf, (afterPayRecordedContext.projectId, IJBTerminal(address(notTerminal)))
            )
        );

        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JuiceBuyback_Unauthorized.selector));

        vm.prank(notTerminal);
        hook.afterPayRecordedWith(afterPayRecordedContext);
    }

    /**
     * @notice Test uniswapCallback
     *
     * @dev    2 branches: project token is 0 or 1 in the pool slot0
     */
    function test_uniswapCallback() public {
        int256 delta0 = -2 ether;
        int256 delta1 = 1 ether;

        IWETH9 terminalToken = weth;

        /**
         * First branch: terminal token = ETH, project token = random IERC20
         */
        hook = new ForTest_JBBuybackHook({
            weth: terminalToken,
            factory: uniswapFactory,
            directory: directory,
            controller: controller
        });

        // Init with weth (as weth is stored in the pool of mapping)
        hook.ForTest_initPool(pool, projectId, secondsAgo, twapDelta, address(projectToken), address(terminalToken));

        // If project is token0, then received is delta0 (the negative value)
        (delta0, delta1) = address(projectToken) < address(terminalToken) ? (delta0, delta1) : (delta1, delta0);

        // mock and expect _terminalToken calls, this should transfer from delegate to pool (positive delta in the
        // callback)
        vm.mockCall(address(terminalToken), abi.encodeCall(terminalToken.deposit, ()), "");
        vm.expectCall(address(terminalToken), abi.encodeCall(terminalToken.deposit, ()));

        vm.mockCall(
            address(terminalToken),
            abi.encodeCall(
                terminalToken.transfer,
                (address(pool), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(terminalToken),
            abi.encodeCall(
                terminalToken.transfer,
                (address(pool), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0))
            )
        );

        vm.deal(address(hook), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0));
        vm.prank(address(pool));
        hook.uniswapV3SwapCallback(delta0, delta1, abi.encode(projectId, JBConstants.NATIVE_TOKEN));

        /**
         * Second branch: terminal token = random IERC20, project token = weth (as another random ierc20)
         */

        // Invert both contract addresses, to swap token0 and token1
        (projectToken, terminalToken) = (JBERC20(address(terminalToken)), IWETH9(address(projectToken)));

        // If project is token0, then received is delta0 (the negative value)
        (delta0, delta1) = address(projectToken) < address(terminalToken) ? (delta0, delta1) : (delta1, delta0);

        hook = new ForTest_JBBuybackHook({
            weth: terminalToken,
            factory: uniswapFactory,
            directory: directory,
            controller: controller
        });

        hook.ForTest_initPool(pool, projectId, secondsAgo, twapDelta, address(projectToken), address(terminalToken));

        vm.mockCall(
            address(terminalToken),
            abi.encodeCall(
                terminalToken.transfer,
                (address(pool), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0))
            ),
            abi.encode(true)
        );
        vm.expectCall(
            address(terminalToken),
            abi.encodeCall(
                terminalToken.transfer,
                (address(pool), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0))
            )
        );

        vm.deal(address(hook), uint256(address(projectToken) < address(terminalToken) ? delta1 : delta0));
        vm.prank(address(pool));
        hook.uniswapV3SwapCallback(delta0, delta1, abi.encode(projectId, address(terminalToken)));
    }

    /**
     * @notice Test uniswapCallback revert if wrong caller
     */
    function test_uniswapCallback_revertIfWrongCaller() public {
        int256 delta0 = -1 ether;
        int256 delta1 = 1 ether;

        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JuiceBuyback_Unauthorized.selector));
        hook.uniswapV3SwapCallback(delta0, delta1, abi.encode(projectId, weth, address(projectToken) < address(weth)));
    }

    /**
     * @notice Test adding a new pool (deployed or not)
     */
    function test_setPoolFor(
        uint256 _secondsAgo,
        uint256 _twapDelta,
        address _terminalToken,
        address _projectToken,
        uint24 _fee
    )
        public
    {
        vm.assume(_terminalToken != address(0) && _projectToken != address(0) && _fee != 0);
        vm.assume(_terminalToken != _projectToken);

        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();

        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        _twapDelta = bound(_twapDelta, MIN_TWAP_SLIPPAGE_TOLERANCE, MAX_TWAP_SLIPPAGE_TOLERANCE);
        _secondsAgo = bound(_secondsAgo, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);

        address _pool = PoolAddress.computeAddress(
            hook.UNISWAP_V3_FACTORY(), PoolAddress.getPoolKey(_terminalToken, _projectToken, _fee)
        );

        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(_projectToken));

        // check: correct events?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_TwapWindowChanged(projectId, 0, _secondsAgo, owner);

        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_TwapSlippageToleranceChanged(projectId, 0, _twapDelta, owner);

        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_PoolAdded(
            projectId,
            _terminalToken == JBConstants.NATIVE_TOKEN ? address(weth) : _terminalToken,
            address(_pool),
            owner
        );

        vm.prank(owner);
        address newPool = address(hook.setPoolFor(projectId, _fee, uint32(_secondsAgo), _twapDelta, _terminalToken));

        // Check: correct params stored?
        assertEq(hook.twapWindowOf(projectId), _secondsAgo);
        assertEq(hook.twapSlippageToleranceOf(projectId), _twapDelta);
        assertEq(
            address(hook.poolOf(projectId, _terminalToken == JBConstants.NATIVE_TOKEN ? address(weth) : _terminalToken)),
            _pool
        );
        assertEq(newPool, _pool);
    }

    /**
     * @notice Test if trying to add an existing pool revert
     *
     * @dev    This is to avoid bypassing the twap delta and period authorisation. A new fee-tier results in a new pool
     */
    function test_setPoolFor_revertIfPoolAlreadyExists(
        uint256 _secondsAgo,
        uint256 _twapDelta,
        address _terminalToken,
        address _projectToken,
        uint24 _fee
    )
        public
    {
        vm.assume(_terminalToken != address(0) && _projectToken != address(0) && _fee != 0);
        vm.assume(_terminalToken != _projectToken);

        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();

        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        _twapDelta = bound(_twapDelta, MIN_TWAP_SLIPPAGE_TOLERANCE, MAX_TWAP_SLIPPAGE_TOLERANCE);
        _secondsAgo = bound(_secondsAgo, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);

        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(_projectToken));

        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(_secondsAgo), _twapDelta, _terminalToken);

        vm.expectRevert(JBBuybackHook.JuiceBuyback_PoolAlreadySet.selector);
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(_secondsAgo), _twapDelta, _terminalToken);
    }

    /**
     * @notice Revert if not called by project owner or authorised sender
     */
    function test_setPoolFor_revertIfWrongCaller() public {
        vm.mockCall(
            address(permissions),
            abi.encodeCall(permissions.hasPermission, (dude, owner, projectId, JBBuybackHookPermissionIds.CHANGE_POOL)),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(permissions.hasPermission, (dude, owner, projectId, JBBuybackHookPermissionIds.CHANGE_POOL))
        );

        vm.mockCall(
            address(permissions),
            abi.encodeCall(permissions.hasPermission, (dude, owner, 0, JBBuybackHookPermissionIds.CHANGE_POOL)),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(permissions.hasPermission, (dude, owner, 0, JBBuybackHookPermissionIds.CHANGE_POOL))
        );

        // check: revert?
        vm.expectRevert(abi.encodeWithSignature("UNAUTHORIZED()"));

        vm.prank(dude);
        hook.setPoolFor(projectId, 100, uint32(10), 10, address(0));
    }

    /**
     * @notice Test if only twap delta and periods between the extrema's are allowed
     */
    function test_setPoolFor_revertIfWrongParams(address _terminalToken, address _projectToken, uint24 _fee) public {
        vm.assume(_terminalToken != address(0) && _projectToken != address(0) && _fee != 0);
        vm.assume(_terminalToken != _projectToken);

        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();

        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(_projectToken));

        // Check: seconds ago too low
        vm.expectRevert(JBBuybackHook.JuiceBuyback_InvalidTwapWindow.selector);
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(MIN_TWAP_WINDOW - 1), MIN_TWAP_SLIPPAGE_TOLERANCE + 1, _terminalToken);

        // Check: seconds ago too high
        vm.expectRevert(JBBuybackHook.JuiceBuyback_InvalidTwapWindow.selector);
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(MAX_TWAP_WINDOW + 1), MIN_TWAP_SLIPPAGE_TOLERANCE + 1, _terminalToken);

        // Check: min twap deviation too low
        vm.expectRevert(JBBuybackHook.JuiceBuyback_InvalidTwapSlippageTolerance.selector);
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(MIN_TWAP_WINDOW + 1), MIN_TWAP_SLIPPAGE_TOLERANCE - 1, _terminalToken);

        // Check: max twap deviation too high
        vm.expectRevert(JBBuybackHook.JuiceBuyback_InvalidTwapSlippageTolerance.selector);
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(MIN_TWAP_WINDOW + 1), MAX_TWAP_SLIPPAGE_TOLERANCE + 1, _terminalToken);
    }

    /**
     * @notice Reverts if the project hasn't emitted a token (yet), as the pool address isn't unreliable then
     */
    function test_setPoolFor_revertIfNoProjectToken(
        uint256 _secondsAgo,
        uint256 _twapDelta,
        address _terminalToken,
        address _projectToken,
        uint24 _fee
    )
        public
    {
        vm.assume(_terminalToken != address(0) && _projectToken != address(0) && _fee != 0);
        vm.assume(_terminalToken != _projectToken);

        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();

        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        _twapDelta = bound(_twapDelta, MIN_TWAP_SLIPPAGE_TOLERANCE, MAX_TWAP_SLIPPAGE_TOLERANCE);
        _secondsAgo = bound(_secondsAgo, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);

        vm.mockCall(address(tokens), abi.encodeCall(tokens.tokenOf, (projectId)), abi.encode(address(0)));

        vm.expectRevert(JBBuybackHook.JuiceBuyback_NoProjectToken.selector);
        vm.prank(owner);
        hook.setPoolFor(projectId, _fee, uint32(_secondsAgo), _twapDelta, _terminalToken);
    }

    /**
     * @notice Test increase seconds ago
     */
    function test_setTwapWindowOf(uint256 _newValue) public {
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();
        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();

        _newValue = bound(_newValue, MIN_TWAP_WINDOW, MAX_TWAP_WINDOW);

        // check: correct event?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_TwapWindowChanged(projectId, hook.twapWindowOf(projectId), _newValue, owner);

        // Test: change seconds ago
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, uint32(_newValue));

        // Check: correct seconds ago?
        assertEq(hook.twapWindowOf(projectId), _newValue);
    }

    /**
     * @notice Test increase seconds ago revert if wrong caller
     */
    function test_setTwapWindowOf_revertIfWrongCaller(address notOwner) public {
        vm.assume(owner != notOwner);

        vm.mockCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (notOwner, owner, projectId, JBBuybackHookPermissionIds.SET_POOL_PARAMS)
            ),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (notOwner, owner, projectId, JBBuybackHookPermissionIds.SET_POOL_PARAMS)
            )
        );

        vm.mockCall(
            address(permissions),
            abi.encodeCall(permissions.hasPermission, (notOwner, owner, 0, JBBuybackHookPermissionIds.SET_POOL_PARAMS)),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(permissions.hasPermission, (notOwner, owner, 0, JBBuybackHookPermissionIds.SET_POOL_PARAMS))
        );

        // check: revert?
        vm.expectRevert(abi.encodeWithSignature("UNAUTHORIZED()"));

        // Test: change seconds ago (left uninit/at 0)
        vm.startPrank(notOwner);
        hook.setTwapWindowOf(projectId, 999);
    }

    /**
     * @notice Test increase seconds ago reverting on boundary
     */
    function test_setTwapWindowOf_revertIfNewValueTooBigOrTooLow(uint256 newValueSeed) public {
        uint256 MAX_TWAP_WINDOW = hook.MAX_TWAP_WINDOW();
        uint256 MIN_TWAP_WINDOW = hook.MIN_TWAP_WINDOW();

        uint256 newValue = bound(newValueSeed, MAX_TWAP_WINDOW + 1, type(uint32).max);

        // Check: revert?
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JuiceBuyback_InvalidTwapWindow.selector));

        // Test: try to change seconds ago
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, uint32(newValue));

        newValue = bound(newValueSeed, 0, MIN_TWAP_WINDOW - 1);

        // Check: revert?
        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JuiceBuyback_InvalidTwapWindow.selector));

        // Test: try to change seconds ago
        vm.prank(owner);
        hook.setTwapWindowOf(projectId, uint32(newValue));
    }

    /**
     * @notice Test set twap delta
     */
    function test_setTwapSlippageToleranceOf(uint256 newDelta) public {
        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();
        newDelta = bound(newDelta, MIN_TWAP_SLIPPAGE_TOLERANCE, MAX_TWAP_SLIPPAGE_TOLERANCE);

        // Check: correct event?
        vm.expectEmit(true, true, true, true);
        emit BuybackDelegate_TwapSlippageToleranceChanged(
            projectId, hook.twapSlippageToleranceOf(projectId), newDelta, owner
        );

        // Test: set the twap
        vm.prank(owner);
        hook.setTwapSlippageToleranceOf(projectId, newDelta);

        // Check: correct twap?
        assertEq(hook.twapSlippageToleranceOf(projectId), newDelta);
    }

    /**
     * @notice Test set twap delta reverts if wrong caller
     */
    function test_setTwapSlippageToleranceOf_revertWrongCaller(address notOwner) public {
        vm.assume(owner != notOwner);

        vm.mockCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (notOwner, owner, projectId, JBBuybackHookPermissionIds.SET_POOL_PARAMS)
            ),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                permissions.hasPermission, (notOwner, owner, projectId, JBBuybackHookPermissionIds.SET_POOL_PARAMS)
            )
        );

        vm.mockCall(
            address(permissions),
            abi.encodeCall(permissions.hasPermission, (notOwner, owner, 0, JBBuybackHookPermissionIds.SET_POOL_PARAMS)),
            abi.encode(false)
        );
        vm.expectCall(
            address(permissions),
            abi.encodeCall(permissions.hasPermission, (notOwner, owner, 0, JBBuybackHookPermissionIds.SET_POOL_PARAMS))
        );

        // check: revert?
        vm.expectRevert(abi.encodeWithSignature("UNAUTHORIZED()"));

        // Test: set the twap
        vm.prank(notOwner);
        hook.setTwapSlippageToleranceOf(projectId, 1);
    }

    /**
     * @notice Test set twap delta
     */
    function test_setTwapSlippageToleranceOf_revertIfInvalidNewValue(uint256 newDeltaSeed) public {
        uint256 MIN_TWAP_SLIPPAGE_TOLERANCE = hook.MIN_TWAP_SLIPPAGE_TOLERANCE();
        uint256 MAX_TWAP_SLIPPAGE_TOLERANCE = hook.MAX_TWAP_SLIPPAGE_TOLERANCE();

        uint256 newDelta = bound(newDeltaSeed, 0, MIN_TWAP_SLIPPAGE_TOLERANCE - 1);

        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JuiceBuyback_InvalidTwapSlippageTolerance.selector));

        // Test: set the twap
        vm.prank(owner);
        hook.setTwapSlippageToleranceOf(projectId, newDelta);

        newDelta = bound(newDeltaSeed, MAX_TWAP_SLIPPAGE_TOLERANCE + 1, type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(JBBuybackHook.JuiceBuyback_InvalidTwapSlippageTolerance.selector));

        // Test: set the twap
        vm.prank(owner);
        hook.setTwapSlippageToleranceOf(projectId, newDelta);
    }

    /**
     * @notice Test if using the delegate as a redemption delegate (which shouldn't be) doesn't influence redemption
     */
    function test_redeemParams_unchangedRedemption(uint256 amountIn) public {
        JBBeforeRedeemRecordedContext memory beforeRedeemRecordedContext = JBBeforeRedeemRecordedContext({
            terminal: makeAddr("terminal"),
            holder: makeAddr("hooldooor"),
            projectId: 69,
            rulesetId: 420,
            redeemCount: 4,
            totalSupply: 5,
            surplus: 6,
            reclaimAmount: JBTokenAmount(address(1), amountIn, 2, 3),
            useTotalSurplus: true,
            redemptionRate: 7,
            metadata: ""
        });

        (uint256 amountOut, JBRedeemHookSpecification[] memory allocationOut) =
            hook.beforeRedeemRecordedWith(beforeRedeemRecordedContext);

        assertEq(amountOut, amountIn);
        assertEq(allocationOut.length, 0);
    }

    function test_supportsInterface(bytes4 random) public {
        vm.assume(
            random != type(IJBBuybackHook).interfaceId && random != type(IJBRulesetDataHook).interfaceId
                && random != type(IJBPayHook).interfaceId && random != type(IERC165).interfaceId
        );

        assertTrue(ERC165Checker.supportsInterface(address(hook), type(IJBRulesetDataHook).interfaceId));
        assertTrue(ERC165Checker.supportsInterface(address(hook), type(IJBPayHook).interfaceId));
        assertTrue(ERC165Checker.supportsInterface(address(hook), type(IJBBuybackHook).interfaceId));
        assertTrue(ERC165Checker.supportsERC165(address(hook)));

        assertFalse(ERC165Checker.supportsInterface(address(hook), random));
    }
}

contract ForTest_JBBuybackHook is JBBuybackHook {
    constructor(
        IWETH9 weth,
        address factory,
        IJBDirectory directory,
        IJBController controller
    )
        JBBuybackHook(weth, factory, directory, controller)
    {}

    function ForTest_getQuote(
        uint256 projectId,
        address projectToken,
        uint256 amountIn,
        address terminalToken
    )
        external
        view
        returns (uint256 amountOut)
    {
        return _getQuote(projectId, projectToken, amountIn, terminalToken);
    }

    function ForTest_initPool(
        IUniswapV3Pool pool,
        uint256 projectId,
        uint32 secondsAgo,
        uint256 twapDelta,
        address projectToken,
        address terminalToken
    )
        external
    {
        _twapParamsOf[projectId] = twapDelta << 128 | secondsAgo;
        projectTokenOf[projectId] = projectToken;
        poolOf[projectId][terminalToken] = pool;
    }
}
