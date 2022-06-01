// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAssetCustody {
    function withdraw(address token, address to, uint256 value) external;
}

contract AssetCustody {

    address private _owner;

    constructor(address _owner_) {
        _owner = _owner_;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "Asset caller only owner");
        _;
    }

    function setOwner(address _owner_) external onlyOwner {
        _owner = _owner_;
    }

    function withdraw(address token, address to, uint256 value) external onlyOwner {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "!Asset safeTransfer");
    }
}