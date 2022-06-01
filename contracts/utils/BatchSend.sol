//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import "./SafeToken.sol";

contract BatchSender {
    using SafeToken for address;
    struct Tran {
        address to;
        uint256 amount;
    }
    function transferBatch( address token, Tran[] memory trs ) external  {
        for(uint i = 0; i < trs.length; i++) {
            token.safeTransferFrom(msg.sender, trs[i].to, trs[i].amount);
        }
    }
}