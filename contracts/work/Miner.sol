//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

// 优化 init 接口
// 仅传入 dailyOutput 即可

// 挖矿合约 只做计算

contract Miner is Ownable {

    // 奖励数量
    uint public dailyOutput;
    uint public startTime;
    uint public initRearn;

    // _binary 比例
    // 调整产量会改变累积出块数
    // 要调整 累积出块
    // 从 节点几分 开始 已多少初始常量 开始挖矿
    // 更新可以 先 设个 长周期，部署完成，在设置开始时间
    constructor(
        uint _dailyOutput,
        uint _startTime,
        uint _initRearn
    ) {
        dailyOutput = _dailyOutput;
        initRearn = _initRearn;
        startTime = _startTime;
    }

    function initialize( uint _dailyOutput ) external onlyOwner {
        uint _startTime = block.timestamp;
        initRearn = mining(_startTime);
        startTime = _startTime;
        dailyOutput = _dailyOutput;
    }

    // 如果减产
    // 累积出块量就会减少
    function mining(uint256 _endTime) public view returns(uint256) {
        // uint256 _endTime = block.timestamp;
        // 未开始
        if (_endTime < startTime) return initRearn;
        return dailyOutput * (_endTime - startTime) / 1 days + initRearn;
    }
}
