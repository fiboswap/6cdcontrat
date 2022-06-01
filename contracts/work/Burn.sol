// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../utils/SafeToken.sol";

// 销毁 推送到 其它合约的 接口
interface ICall {
    function burnCall(address _owner) external;
}

interface IBurn {
    function burnedUsdtFor(address) external view returns(uint);
}

contract BurnProxy is Ownable {

    using SafeToken for address;
    
    address public burnToken;
    // 销毁接口地址
    address public treasury;

    address[] public calls;

    mapping (address => uint) private _burned;

    event Burn(address indexed owner, uint usdt);
    event AddCalls(address indexed calls);
    event RemoveCalls(address indexed calls);
    
    constructor ( address _burnToken) {
        burnToken = _burnToken;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function addCalls(address _calls) external onlyOwner {
        calls.push(_calls);
        emit AddCalls(_calls);
    }

    function closeCalls(address _calls) external onlyOwner {
        uint len = calls.length;
        for(uint i = 0; i < len; i++) {
            if ( calls[i] == _calls ) {
                calls[i] = calls[len - 1];
                calls.pop();
            }
        }
    }

    function getCallsAll() external view returns(address[] memory callsAll) {
        uint len = calls.length;
        callsAll = new address[](len);
        for(uint i = 0; i < len; i++) {
            callsAll[i] = calls[i];
        }
    }

    function burnedUsdtFor(address _owner) external view returns(uint) {
        return _burned[_owner];
    }

    function burn(uint _amount) external {
        _burn(_msgSender(), _amount);
    }

    function _burn(address _owner, uint256 _amount) internal {
        // 销毁
        burnToken.safeTransferFrom(_owner, treasury, _amount);
        _burned[_owner] += _amount;
        emit Burn(_owner, _amount);
        _burnCall(_owner);
    }

    function _burnCall(address _owner) internal {
        uint len = calls.length;
        for(uint256 i = 0; i < len; i++) {
            if ( calls[i] != address(0) ) {
                // 接口暴死会无法销毁
                // 不应该用 safe call
                ICall(calls[i]).burnCall(_owner);
            }
        }
    }
}