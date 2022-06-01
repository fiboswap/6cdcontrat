// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


struct Asset {
    mapping(address => uint) asset;
    address[] assetMap;
}

library AssetMap {

    function addAsset(Asset storage ass, address token, uint amount) internal {
        ass.asset[token] = amount;
        ass.assetMap.push(token);
    }

    function setAsset(Asset storage ass, address token, uint amount) internal {
        ass.asset[token] = amount;
    }

    function removeAsset(Asset storage ass, address token) internal {
        address[] memory assList = ass.assetMap;
        uint len = assList.length;
        for(uint i = 0; i < len; i++) {
            if ( assList[i] == token ) {
                ass.assetMap[i] = assList[len - 1];
                ass.assetMap.pop();
                break;
            }
        }
        ass.asset[token] = 0;
    }

    function assetFor(Asset storage ass) internal view returns(address[] memory assetList, uint[] memory assetAmount) {
        assetList = ass.assetMap;
        uint len = assetList.length;
        for(uint i = 0; i < len; i++) {
            assetAmount[i] = ass.asset[assetList[i]];
        }
    }
}
