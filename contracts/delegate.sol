// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBController.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBFundingCycleStore.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBConstants.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBFundingCycleMetadataResolver.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/libraries/JBTokens.sol'; 
import '@jbx-protocol/juice-contracts-v3/contracts/structs/JBDidPayData.sol';
import '@jbx-protocol/juice-contracts-v3/contracts/structs/JBPayParamsData.sol';

import '@openzeppelin/contracts/interfaces/IERC20.sol';

import '@paulrberg/contracts/math/PRBMath.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

import './interfaces/external/IWETH9.sol';

/**
  @title
  Delegate buyback
  
  @notice
  Based on the amount received by minting versus swapped on Uniswap V3, provide the best
  quote for the user when contributing to a project.
*/

contract JuiceBuyback is IJBFundingCycleDataSource, IJBPayDelegate, IUniswapV3SwapCallback {
  using JBFundingCycleMetadataResolver for JBFundingCycle;
  //*********************************************************************//
  // --------------------------- custom errors ------------------------- //
  //*********************************************************************//
  error JuiceBuyback_Unauthorized();

  //*********************************************************************//
  // --------------------------- unherited events----------------------- //
  //*********************************************************************//

  //*********************************************************************//
  // --------------------- private constant properties ----------------- //
  //*********************************************************************//

  /**
    @notice
    Address project token < address terminal token ?
  */
  bool private immutable _projectTokenIsZero;

  /**
    @notice
    The unit of the max slippage (expressed in 1/10000th)
  */
  uint256 private constant SLIPPAGE_DENOMINATOR = 10000;

  //*********************************************************************//
  // --------------------- public constant properties ------------------ //
  //*********************************************************************//
  /**
    @notice
    The other token paired with the project token in the Uniswap pool/the terminal currency.
  */
  IERC20 public immutable terminalToken;

  /**
    @notice
    The project token address
  */
  IERC20 public immutable projectToken;

  /**
    @notice
    The uniswap pool corrsponding to the project token-other token market
  */
  IUniswapV3Pool public immutable pool;

  /**
    @notice
    The projectId terminal using this extension
  */
  IJBPayoutRedemptionPaymentTerminal public immutable jbxTerminal;

  //*********************************************************************//
  // --------------------- public stored properties -------------------- //
  //*********************************************************************//

  //*********************************************************************//
  // --------------------- private stored properties ------------------- //
  //*********************************************************************//

  constructor(IERC20 _projectToken, IERC20 _terminalToken, IUniswapV3Pool _pool, IJBPayoutRedemptionPaymentTerminal _jbxTerminal) {
    projectToken = _projectToken;
    terminalToken = _terminalToken;
    pool = _pool;
    jbxTerminal = _jbxTerminal;
    _projectTokenIsZero = address(_projectToken) < address(_terminalToken);
  }
    
  //*********************************************************************//
  // ---------------------- external functions ------------------------- //
  //*********************************************************************//

  /**
    @notice
    The datasource implementation
    @dev   
    @param _data the data passed to the data source in terminal.pay(..). _data.metadata need to have the Uniswap quote
    @return weight the weight to use (the one passed if not max reserved rate, 0 if swapping or the one corresponding
            to the reserved token to mint if minting)
    @return memo the original memo passed
    @return delegateAllocations The amount to send to delegates instead of adding to the local balance.
  */
  function payParams(JBPayParamsData calldata _data)
    external
    override
    returns (
      uint256 weight,
      string memory memo,
      JBPayDelegateAllocation[] memory delegateAllocations
    )
    {
        // Find the total number of tokens to mint, as a fixed point number with as many decimals as `weight` has.
        uint256 _tokenCount = PRBMath.mulDiv(_data.amount.value, _data.weight, 10**_data.amount.decimals);

        // Unpack the quote from the pool
        (uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (uint256, uint256));

        // If the amount minted is bigger than the lowest received when swapping, do not use the delegate and use the fc weight
        if (_tokenCount >= _quote * _slippage / SLIPPAGE_DENOMINATOR) {
          return (_data.weight, _data.memo, new JBPayDelegateAllocation[](0));
        }
        else { // swapping gather more token, use the delegate and do not mint in the terminal
          delegateAllocations = new JBPayDelegateAllocation[](1);
          delegateAllocations[0] = JBPayDelegateAllocation({
              delegate: IJBPayDelegate(this),
              amount: _data.amount.value
          });

          return (0, _data.memo, delegateAllocations);
        }
    }

  /**
      @notice
      Delegate to either swap to the beneficiary (the mint to reserved being done by the delegate function, via
      the weight) - this function is only called if swapping gather more token (delegate is bypassed if not)
      @param _data the delegate data passed by the terminal
  */
  function didPay(JBDidPayData calldata _data) external payable override {

      (uint256 _quote, uint256 _slippage) = abi.decode(_data.metadata, (uint256, uint256));
      bool __projectTokenIsZero = _projectTokenIsZero;

      uint256 _amountReceived;

      // Pull and approve token for swap
      if(_data.amount.token != JBTokens.ETH)


      // Try swapping, no price limit as slippage is tested on amount received
      try pool.swap({
        recipient: address(this),
         zeroForOne: __projectTokenIsZero,
         amountSpecified: int256(_data.amount.value),
         sqrtPriceLimitX96: 0,
         data: abi.encode(msg.sender, _quote * _slippage / SLIPPAGE_DENOMINATOR)
      }) returns (int256 amount0, int256 amount1) {

        _amountReceived = uint256(__projectTokenIsZero ? amount0 : amount1);

      } catch {
        // If swap is not successfull, mint the token to the beneficiary

        // Get the current fc to retrieve the weight
        IJBController controller = jbxTerminal.directory().controllerOf(_data.projectId);
        IJBFundingCycleStore fundingCycleStore = jbxTerminal.store().fundingCycleStore();
        JBFundingCycle memory _currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);

        uint256 _tokenCount = PRBMath.mulDiv(_data.amount.value, _currentFundingCycle.weight(), 10**_data.amount.decimals);

        // Mint with the reserved rate (datasource has authorization via controller)
        controller.mintTokensOf({
          _projectId: _data.projectId,
          _tokenCount: _tokenCount,
          _beneficiary: _data.beneficiary,
          _memo: _data.memo,
          _preferClaimedTokens: _data._preferClaimedTokens,
          _useReservedRate: true
          });
      }

      IJBController controller = jbxTerminal.directory().controllerOf(_data.projectId);

      // Get current weight
      IJBFundingCycleStore fundingCycleStore = jbxTerminal.store().fundingCycleStore();
      JBFundingCycle memory _currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);

      // Get the net amount (without reserve rate)
      uint256 _nonReservedToken = PRBMath.mulDiv(
        _amountReceived,
        JBConstants.MAX_RESERVED_RATE - _currentFundingCycle.reservedRate(),
        JBConstants.MAX_RESERVED_RATE);


      // split and send/approve
  }

    function redeemParams(JBRedeemParamsData calldata _data)
        external
        override
    returns (
            uint256 reclaimAmount,
            string memory memo,
            JBRedemptionDelegateAllocation[] memory delegateAllocations
    ) {}

  /**
    @notice
    The Uniswap V3 pool callback (where token transfer should happens)
    @dev the twap-spot deviation is checked in this callback.
  */
  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata data
  ) external override {

    // Check if this is really a callback
    if(msg.sender != address(_pool)) revert JuiceBuyback_Unauthorized();

    (address _recipient, uint256 _minimumAmountReceived) = abi.decode(data, (address, uint256));

    // If _minimumAmountReceived > amount0 or 1, revert max slippage (this is handled by the try-catch)

    // Pull fund from _recipient + eth case
  }

  //*********************************************************************//
  // ---------------------- internal functions ------------------------- //
  //*********************************************************************//

  /**
    @notice
    Swap the token out and a part of the overflow, for the beneficiary and the reserved tokens
    @dev
    Only a share of the token in are swapped and then sent to the beneficiary. The corresponding
    token are swapped using a part of the project treasury. Both token in are used via an overflow
    allowance.
    The reserved token are received in this contract, burned and then minted for the reserved token.
    @param _data the didPayData passed by the terminal
  */
  function _swap(JBDidPayData calldata _data) internal {
  }

  //*********************************************************************//
  // ---------------------- peripheral functions ----------------------- //
  //*********************************************************************//

  function supportsInterface(bytes4 _interfaceId) external pure override returns (bool) {
    return
      _interfaceId == type(IJBFundingCycleDataSource).interfaceId ||
      _interfaceId == type(IJBPayDelegate).interfaceId;
  }

  //*********************************************************************//
  // ---------------------- setter functions --------------------------- //
  //*********************************************************************//
}