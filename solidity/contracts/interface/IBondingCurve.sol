pragma solidity ^0.6.6;

interface IBondingCurve {
  function allocate (  ) external; 
  function purchase (address to, uint256 amountIn ) external payable returns ( uint256 amountOut );
}
