// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITrimLp {
    function addLP(address token0, address token1, uint token0Amount, uint token1Amount, uint minLp, uint feeEPX, address to) external returns(uint);
    function buy(address tokenIn, address tokenOut, uint amountIn, uint, address to, uint feeEPX) external;
    function removeLp(address token0, address token1, address to) external;
    function getPair(address token0, address token1) external view returns (address);
    function skim(address token, address to) external;
}