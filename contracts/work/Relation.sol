// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface IRelation {
    function umbrella(address) external view returns(address[] memory);
    function umbrellaNumOf(address) external view returns(uint);
    function referrer(address) external view returns(address);
    function getReferrerFor(address, uint) external view returns(address[] memory);
}

contract Relation is Ownable {

    using Address for address;

    uint256 public maxNmbrella;
    // 子 查 父
    mapping(address => address) private _referrers;
    // 父 查 子
    mapping(address => address[]) private _umbrellas;

    // 代理
    mapping(address => bool) public relProxy;

    // 父级 -> 子级    
    event CreateReferrer(address indexed referrers, address indexed user);
    event SetProxy(address indexed proxy, bool indexed status);

    constructor( ) {
        // 合约本身可以被推荐
        _referrers[address(this)] = address(1);
    }

    function setProxy(address _proxy, bool _status) external onlyOwner {
        relProxy[_proxy] = _status;
        emit SetProxy(_proxy, _status);
    } 
    
    function setMaxNmber(uint256 _maxNmbrella) external onlyOwner {
        maxNmbrella =  _maxNmbrella;
    }

    function umbrellaNumOf(address _owner) public view returns(uint256) {
        return _umbrellas[_owner].length;
    }

    function umbrella(address _owner) external view returns(address[] memory) {
        return _umbrellas[_owner];
    }

    function referrer(address _owner) external view returns(address) {
        return _referrers[_owner];
    }

    function getReferrerFor(address _owner, uint _size) external view returns(address[] memory refs) {
        address[] memory _refs = new address[](_size);
        uint len = 0;
        address ownerRefs = _owner;
        for(uint256 i = 0; i < _size; i++) {
            if ( ownerRefs == address(1) ) break;
            ownerRefs = _referrers[ownerRefs];
            _refs[i] = ownerRefs;
            len++;
        }
        refs = new address[](len);
        for(uint256 i = 0; i < len; i++) {
            refs[i] = _refs[i];
        }
    }
    
    // 自推模式
    function addReferrer(address _referrer_) external {
        _addReferrerFor(_msgSender(),_referrer_);
    }

    // 代理模式
    function addRelByProxy(address _owner, address _referrer) external {
        require(relProxy[_msgSender()], "only proxy call");
        _addReferrerFor(_owner, _referrer);
    }

    // _owner 子级
    // _referrer_ 父级
    function _addReferrerFor(address _owner, address _referrer_) internal {
        address _referrer2 = _referrers[_referrer_];
        address _referrer1 = _referrers[_owner];
        // 推荐人 必须有 推荐人
        // 避免 自我推荐【子级没有父级】子级一定没有 父级，父级一定有父级，那父级的父级一定不会是子级，父级不能改，避免了重置为子级
        // 循环推荐 避免条件: 不在网体里的用户无法 被推荐，网体里的用户无法被更改
        // 0x 地址不可能有推荐人
        // 不在网体的用户 无法被推荐
        require(_referrer2 != address(0), "referrer not Referrered");
        // 已推荐的用户无法被更改
        require(_referrer1 == address(0), "owner Referrered");

        // 父级加一个
        _umbrellas[_referrer_].push(_owner);
        // 子级 认领 父级
        _referrers[_owner] = _referrer_;
        
        require(maxNmbrella == 0 || umbrellaNumOf(_referrer_) <= maxNmbrella, "maxNmbrella overflow");
        emit CreateReferrer(_referrer_, _owner);
    }

    function work(address[] calldata traget, bytes[] calldata data) external onlyOwner {
        uint len = traget.length;
        for(uint i = 0; i < len; i++) {
            traget[i].functionCall(data[i]);
        }
        
    }
}