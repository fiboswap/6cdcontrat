// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// import "@openzeppelin/contracts/access/Ownable.sol";
// import "@openzeppelin/contracts/access/AccessControl.sol";

contract TestCoin is ERC20 {
    
    // uint256 public MAX_TOTAL_SUPPLY = 210240000 * 1e8;
    string public _name_;
    constructor (string memory name_,string memory symbol_) ERC20(_name_, symbol_) {
        super._mint(msg.sender, 100000000 * 1e18);
        _name_ = name_;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function name() public view override returns (string memory) {
        return _name_;
    }

    function mint(address _to, uint256 _amount) external {
        super._mint(_to, _amount);
        // require( totalSupply() <= MAX_TOTAL_SUPPLY ,"MAX_TOTAL_SUPPLY 210240000 * 1e8");
    }

    function burn( uint256 _amount) external {
        super._burn(_msgSender(), _amount);
    }

    function timestamp() external view returns(uint256) {
        return block.timestamp;
    }

}


contract USDT is ERC20 {
    constructor () ERC20("USDT", "USDT") {
        _mint(msg.sender, 100000000 * 1e18);
    }
    function mint(address to, uint amount) external {
        _mint( to, amount);
    }
}