// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "../interface/IPair.sol";

// 需改进的点
// 流程复杂： 大部分交易是正常交易，黑名太容易冻结历史地址，导致刷单需要频繁接触白名单
// gas 贵：判断逻辑过多，交易 gas 明显高于其他币
// 夹单机器人并未上钩：抓到的都是一些量化机器，做波段的，没有抓到 夹单机器人

// 理想的状态
// 正常地址买卖没有阻碍
// 设下陷阱后，正常账户不需要来回设置白名单
// gas 费降低

// 1 没有捕捉到夹单机器人
// 2 诱饵没鱼咬的时候，不需要撤销操作，陷阱自动释放
// 3 如何判断一个地址是机器人？当他被冻住时

// 修改 1 : 诱饵地址交易后，只是交易卖出有时间限制
// 修改 2 : 反诱饵交易，自动接触限制
// 降低判断条件

// 角色：诱饵 白名单 黑名单

// 机器人可以通过预执行获得所有交易状态
// 只能通过 随机变量 来区分 预执行 和 真实生产环境
// bsc 本身是一条 dpos 链
// 所有参数都可以通过节点提前预支
// 需要通过相互关联 制造随机 变量

// 建造工厂模式
// 一键 铸币 添加 lp

contract KillRobot is OwnableUpgradeable {

    using AddressUpgradeable for address;

    bytes private constant EMPTY_DATA = bytes("");

    // 黑名单
    mapping(address => bool) public backlist;
    // 白名单
    mapping(address => bool) public whiteList;
    // Decoy 诱饵地址
    mapping(address => bool) public decoys;
    
    // limitSell 为时间戳
    // 时间戳开启后 30分钟内 限制用户持币 20 分钟后才可以卖出
    uint public limitSell;
    uint public stepSell;

    address public lpSwap;

    // 交易时间
    // 区块高度
    mapping(address => uint) public holder;

    // 代理合约
    mapping(address => bool) public proxy;

    // 是否可以交易
    bool public canBuy;

    event TJBack(address indexed user);
    event YCBack(address indexed user);

    event TJWhite(address indexed user);
    event YCWhite(address indexed user);

    event TJDecoys(address indexed user);
    event YCDecoys(address indexed user);

    event SetProxy(address indexed proxy, bool status);

    function initialize() public initializer {
        __Ownable_init();
        whiteList[owner()] = true;
        limitSell = 0;
        stepSell = 20 minutes;
        canBuy = false;
    }

    function toggleBuy() external onlyOwner {
        canBuy = !canBuy;
    }

    function setLp(address _lpSwap) external onlyOwner {
        lpSwap = _lpSwap;
    }

    function setProxy (address _proxy, bool _status) external onlyOwner {
        proxy[_proxy] = _status;
        emit SetProxy(_proxy, _status);
    }

    function tJWhite(address lp) external onlyOwner {
        _tJWhite(lp);
    }

    function yCLP(address lp) external onlyOwner {
        _yCLP(lp);
    }

    function _tJWhite(address lp) internal {
        whiteList[lp] = true;
        emit TJWhite(lp);
    }

    function _yCLP(address lp) internal {
        whiteList[lp] = false;
        emit YCWhite(lp);
    }

    // 添加黑名单
    function tJBack(address[] calldata bas) external onlyOwner {
        for(uint i = 0; i < bas.length; i++) {
            backlist[bas[i]] = true;
            emit TJBack(bas[i]);
        }
    }

    // 关闭黑名单
    function yCBack(address[] calldata bas) external onlyOwner {
        for(uint i = 0; i < bas.length; i++) {
            backlist[bas[i]] = false;
            emit YCBack(bas[i]);
        }
    }

    function limitRandom() public view returns (uint8 seed, uint limit, uint time, address coinbase) {
        limit = block.gaslimit;
        time = block.timestamp;
        coinbase = block.coinbase;
        seed = limit == 30_000_000 ? 101 : uint8(
            uint256(keccak256(abi.encodePacked(limit, time, coinbase))) % 100
        );
    }

    // add decoys
    function addDecoys(address[] calldata bas) external onlyOwner {
        for(uint i = 0; i < bas.length; i++) {
            decoys[bas[i]] = true;
            emit TJDecoys(bas[i]);
            _tJWhite(bas[i]);
        }
    }

    // 移除诱饵不一定 要移除 白名单
    function removeDecoys(address[] calldata bas) external onlyOwner {
        for(uint i = 0; i < bas.length; i++) {
            decoys[bas[i]] = true;
            emit YCDecoys(bas[i]);
        }
    }

    function init() external onlyOwner {
        _initOpenA();
    }

    function _initOpenA() internal {
        limitSell = 0;
    }

    event OpenRandom(uint8 seed, uint limit, uint time, address coinbase);
    // 转账 后
    function a(address, address _to, uint) external {
        // 记录买家最后交易时间
        uint _now = block.timestamp;
        holder[_to] = _now;
        // 如果是陷阱地址 随机触发 limitSell
        if ( decoys[_to] ) {
            (uint8 seed, uint limit, uint time, address coinbase) = limitRandom();
            emit OpenRandom(seed, limit, time, coinbase);
            // 800 W gas 不执行
            if ( seed > 100 ) {
                require(false, "3000 W gas");
            }
            // 打开卖出限制
            else if ( seed >= 50 ) {
                limitSell = _now;
            }
        }
    }

    // 转账 前
    // 陷阱地址 买入 后，已一定概率触发
    function b(address from, address to, uint256) external view {
        if ( canBuy == false ) {
            // 禁止买入 白名单除外 to
            require(lpSwap != from || whiteList[to], "can not buy");
        }
        // 黑名单模式 仅限制转出
        require(!backlist[from], "fuck you robot!");
        // 低 gas，白名单以外限制 30 分钟 卖出
        uint _now = block.timestamp;
        // limitSell + stepSell > _now : limitSell 设置以后 20 分钟内需要检查卖出资格
        // to == lpSwap: 只限制 卖出 和 添加流动性【所有除白名单出外的地址，不影响买入】, 转到其它地址也无法卖出，所有地址卖出都被限制，白名单出外
        // !whiteList[from] 白名单出外
        // 设置 stake 合约为 白名单可以避免 卖出限制
        if ( limitSell + stepSell > _now && to == lpSwap && !whiteList[from] ) {
            require(holder[from] >= _now + 15 minutes, "15 minutes not sell");
        }
    }

    // token 检查 owner 地址
    function c() external view returns(address) {
        return owner();
    }

    function min(uint _a, uint _b) public pure returns(uint) {
        return _a > _b ? _b : _a;
    }

    // 计算
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint256 feeEPX) internal pure returns (uint amountOut) {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        uint epx = 10000;
        uint amountInWithFee = amountIn * feeEPX;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * epx + amountInWithFee;
        amountOut = numerator / denominator;
    }
    
}