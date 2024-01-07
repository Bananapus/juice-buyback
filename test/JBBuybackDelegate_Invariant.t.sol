// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

// import "./helpers/TestBaseWorkflowV3.sol";

// import {JBConstants} from "lib/juice-contracts-v4/src/libraries/JBConstants.sol";
// import {MetadataResolverHelper} from "lib/juice-contracts-v4/test/helpers/MetadataResolverHelper.sol";
// import {PoolTestHelper} from "lib/uniswap-v3-foundry-pool/src/PoolTestHelper.sol";

// /**
//  * @notice Invariant tests for the JBBuybackHook contract.
//  *
//  * @dev    Invariant tested:
//  *          - BBD1: totalSupply after pay == total supply before pay + (amountIn * weight / 10^18)
//  */
// contract TestJBBuybackHook_Invariant is TestBaseWorkflowV3, PoolTestHelper {
//     BBDHandler handler;
//     MetadataResolverHelper metadataHelper = new MetadataResolverHelper();

//     /**
//      * @notice Set up a new JBX project and use the buyback delegate as the datasource
//      */
//     function setUp() public override {
//         // super is the Jbx V3 fixture: deploy full protocol, launch project 1, emit token, deploy delegate, set the
//         // pool
//         super.setUp();

//         handler = new BBDHandler(jbMultiTerminal, projectId, pool, hook);

//         PoolTestHelper helper = new PoolTestHelper();
//         IUniswapV3Pool newPool = IUniswapV3Pool(
//             address(
//                 helper.createPool(
//                     address(weth),
//                     address(jbController.tokenStore().tokenOf(projectId)),
//                     fee,
//                     1000 ether,
//                     PoolTestHelper.Chains.Mainnet
//                 )
//             )
//         );

//         targetContract(address(handler));
//     }

//     function invariant_BBD1() public {
//         uint256 amountIn = handler.ghost_accumulatorAmountIn();

//         assertEq(jbController.totalOutstandingTokensOf(projectId), amountIn * weight / 10 ** 18);
//     }

//     function test_inv() public {
//         assert(true);
//     }
// }

// contract BBDHandler is Test {
//     MetadataResolverHelper immutable METADATa_HELPER;
//     JBMultiTerminal immutable TERMINAL;
//     IUniswapV3Pool immutable POOL;
//     IJBBuybackHook immutable HOOK;
//     uint256 immutable PROJECT_ID;

//     address public BENEFICIARY;

//     uint256 public ghost_accumulatorAmountIn;
//     uint256 public ghost_liquidityProvided;
//     uint256 public ghost_liquidityToUse;

//     modifier useLiquidity(uint256 _seed) {
//         ghost_liquidityToUse = bound(_seed, 1, ghost_liquidityProvided);
//         _;
//     }

//     constructor(JBMultiTerminal terminal, uint256 projectId, IUniswapV3Pool pool, IJBBuybackHook hook) {
//         metadataHelper = new MetadataResolverHelper();

//         TERMINAL = terminal;
//         PROJECT_ID = projectId;
//         POOL = pool;
//         HOOK = hook;

//         BENEFICIARY = makeAddr("_beneficiary");
//     }

//     function trigger_pay(uint256 amountIn) public {
//         amountIn = bound(amountIn, 0, 10_000 ether);

//         bool zeroForOne = TERMINAL.token() > address(JBConstants.NATIVE_TOKEN);

//         vm.mockCall(
//             address(POOL),
//             abi.encodeCall(
//                 IUniswapV3PoolActions.swap,
//                 (
//                     address(HOOK),
//                     zeroForOne,
//                     int256(amountIn),
//                     zeroForOne
//                         ? TickMath.MIN_SQRT_RATIO + 1
//                         : TickMath.MAX_SQRT_RATIO - 1,
//                     abi.encode(PROJECT_ID, JBConstants.NATIVE_TOKEN)
//                 )
//             ),
//             abi.encode(0, 0)
//         );

//         vm.deal(address(this), amountIn);
//         ghost_accumulatorAmountIn += amountIn;

//         uint256 quote = 1;

//         // set only valid metadata
//         bytes[] memory quoteData = new bytes[](1);
//         quoteData[0] = abi.encode(amountIn, quote);

//         // Pass the delegate id
//         bytes4[] memory ids = new bytes4[](1);
//         ids[0] = bytes4(hex"69");

//         // Generate the metadata
//         bytes memory delegateMetadata = metadataHelper.createMetadata(ids, quoteData);

//         TERMINAL.pay{value: amountIn}(
//             PROJECT_ID,
//             amountIn,
//             address(0),
//             BENEFICIARY,
//             /* _minReturnedTokens */
//             0,
//             /* _preferClaimedTokens */
//             true,
//             /* _memo */
//             "Take my money!",
//             /* _delegateMetadata */
//             delegateMetadata
//         );
//     }

//     function addLiquidity(uint256 _amount0, uint256 _amount1, int24 _lowerTick, int24 _upperTick) public {
//         // ghost_liquidityProvided += pool.addLiquidity()
//     }
// }
