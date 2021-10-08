// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

/**
 * @title IAaveOracle interface
 * @notice Interface for the Aave oracle.
 **/

interface IAaveOracle {
  function BASE_CURRENCY() external view returns (address);
  function BASE_CURRENCY_UNIT() external view returns (address);
  function WETH() external view returns (address);

  /***********
    @dev returns the asset price in ETH
     */
  function getAssetPrice(address asset) external view returns (uint256);
}