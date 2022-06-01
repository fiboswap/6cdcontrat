// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../utils/SafeToken.sol";
import "../utils/Math64x64.sol";

// import "../interface/ITrimLp.sol";

import {IRelation} from "./Relation.sol";

import {AssetCustody} from "../utils/Asset.sol";
import {IFactory, TrimV2} from "../utils/TrimLp.sol";

import "hardhat/console.sol";

// 交易模式

interface IBurn {
    function burnedUsdtFor(address _owner) external view returns(uint256);
}

interface IMiner {
    function mining(uint256) external view returns(uint256);
    function startTime() external view returns(uint256);
}

contract StakeLp is OwnableUpgradeable, TrimV2 {

    using Math64x64 for int128;
    using SafeToken for address;

    ///////////// 常量 /////////////
    uint256 public constant EPX = 1 << 112;
    uint256 public constant EPX64 = 1 << 64;
    uint256 public constant EPX_RATE = 1e8;
    uint256 public constant MAX = type(uint256).max;

    ///////////// 常量 /////////////
    // 开始时间
    uint256 public startTime;

    ///////////// 状态 /////////////
    // 分红率
    uint256 public bonusRateEPX_RATE;
    // 生态率
    uint256 public ecologyRateEPX_RATE;
    // 折扣池分配率
    uint256 public discountRateEPX_RATE;    

    // 动态总算力 = share * shareMultiplierEPX_RATE / EPX_RATE
    uint256 public totalShare;
    // 总存款
    uint256 public totalDeposits;
    // 总 usdt 存款
    uint256 public totalUsdt;
    
    // 动态总净值
    uint256 public shareNetEPX;
    // 动态分红率
    uint256 public shareNetRateEPX_RATE;

    // 静态总净值
    uint256 public depositsNetEPX;

    // 上一次结算的余额
    uint256 public beforeEarnTokenBalance;
    // 上一次分配的余额
    uint256 public lasteSettlementBalance;
    // beforeEarnTokenBalance - lasteSettlementBalance = 应收矿税

    // 用户仓位
    // deposits 存款算力 不是 存的 U 的数量
    // share 分享纯算力【不含杠杠】
    // availableRewards 可用收益
    // depositsNetEPX 存款净值
    // shareNetEPX 分享净值
    // shareMultiplierEPX 分享算力倍数【销毁倍数】
    // depositsMultiplierEPX 存款倍数 只有时间乘数【单笔累积，没有倍数】
    // unlockTime 解锁时间[销毁挖矿 没有这个字段]
    // burnedUsdt 累积销毁 usdt 数量
    // teamUsdt 团队销毁的 USDT 数量
    // lpWei 销毁的 lp 数量
    struct Staked {
        uint256 deposits;
        uint256 share;
        uint256 availableRewards;
        uint256 depositsNetEPX;
        uint256 shareNetEPX;
        uint256 teamUsdt;
        uint256 shareMultiplierEPX_RATE;
        // uint256 depositsMultiplierEPX_RATE;
        // uint256 unlockTime;
        uint256 lpWei;
        uint256 burnedUsdt;
    }
    mapping (address => Staked) private _staked;

    ///////////// api /////////////
    // 矿池 挖矿
    // 独立计算出块 方便更新算法
    address public minerPool;
    // 销毁地址
    address public burnProxy;
    
    // 社区激励
    AssetCustody public bonus;
    // 技术
    AssetCustody public ecology;
    // 运营
    AssetCustody public discount;
    // 国库
    AssetCustody public treasury;

    // 国库资管
    // AssetCustody public assetCustody;

    IRelation public relation;

    address public usdt;
    address public sixcd;

    modifier checkBind() {
        address _rel = relation.referrer(_msgSender());
        require(_rel != address(0), "Not Invited");
        _;
    }

    event ClaimError(uint256 balance, uint256 rewards);
    
    function initialize(
        address _usdt,
        address _sixcd,
        address _burnProxy,
        IRelation _relation,
        IFactory _factory
    ) public initializer {

        __Ownable_init();

        relation = _relation;

        // 配置 trim
        initFactory(_factory);
        initPair(_sixcd, _usdt);
        // 资管
        // assetCustody = new AssetCustody(address(this));

        treasury = new AssetCustody(owner());
        // // 社区激励 10%
        // AssetCustody public bonus;
        // // 技术 10%
        // AssetCustody public ecology;
        // // 运营 20%
        // AssetCustody public discount;
        bonus = new AssetCustody(owner());
        ecology = new AssetCustody(owner());
        discount = new AssetCustody(owner());

        bonusRateEPX_RATE = EPX_RATE / 10;
        ecologyRateEPX_RATE = EPX_RATE / 10;
        discountRateEPX_RATE = EPX_RATE / 5;

        // 修改该部分数据只能 update 合约
        usdt = _usdt;
        sixcd = _sixcd;
        burnProxy = _burnProxy;

        // 默认动态 60
        shareNetRateEPX_RATE = EPX_RATE * 7 / 10;

        startTime = 0;
    }

    // 拆开设置 开发 方便
    function setLp(
        IFactory _factory,
        address _usdt,
        address _sixcd
    ) external onlyOwner {
        usdt = _usdt;
        sixcd = _sixcd;
        initFactory(_factory);
        initPair(_sixcd, _usdt);
    }

    // 修改 分享分红比例
    function setShareNetRate(uint256 _rate) external onlyOwner {
        upDateNet();
        shareNetRateEPX_RATE = _rate;
    }

    // 矿池
    function setMiner(address _minerPool) external onlyOwner {
        minerPool = _minerPool;
    }

    // 50W U 以内 mint 模式【不包含50W U】
    function isMint() public view returns(bool) {
        return totalUsdt < 500_000 * 1e18;
    }

    /////////// 销毁 ///////////
    // 质押仓位
    function stakeBalanceFor(address _owner) external view returns(Staked memory) {
        return _staked[_owner];
    }

    // 销毁倍数
    // < 500 U
    //     x 0.5
    // < 800 U
    //     x 1
    // < 1500 U
    //     x 2
    // < 3000 U
    //     x 3
    // < 5000 U
    //     x 4
    // >= 5000 U
    //     x 5
    function getBurnMultiplierEPXRATE(uint256 _usdtAmount) public pure returns(uint256) {
        _usdtAmount = _usdtAmount / 1e18;
        if ( _usdtAmount < 500 ) {
            return 5 * EPX_RATE / 10;
        }
        else if ( _usdtAmount < 800 ) {
            return EPX_RATE;
        }
        else if ( _usdtAmount < 1500 ) {
            return 2 * EPX_RATE;
        }
        else if ( _usdtAmount < 3000 ) {
            return 3 * EPX_RATE;
        }
        else if ( _usdtAmount < 5000 ) {
            return 4 * EPX_RATE;
        }
        else {
            return 5 * EPX_RATE;
        }
    }

    // 获取 倍数 销毁
    function getBurnEPXRATEFor(address _owner) public view returns(uint256) {
        return getBurnMultiplierEPXRATE(
            IBurn(burnProxy).burnedUsdtFor(_owner)
        );
    }

    // 不需要判断 caller
    // 已限定数据源
    // 这里需要销毁了 才会回调
    // 而初始值 是 0
    // 需求是 不销毁 有 0.5 的倍数
    // 现在没有销毁，就不会 调用 burncall
    // 不调用 burncall 就没有 倍数
    // 需要在 stake后 主动 更新一次 burncall
    function burnCall(address _owner) external {
        // 更新净值
        upDateNet();
        _updetaBurn(_owner);
    }

    function _updetaBurn(address _owner) internal {
        // 结算个人收益更新 净值
        Staked storage _burn = _staked[_owner];
        _upDateStakeRewards(_burn);
        
        // 不会被 _staked 影响
        uint256 newBurnEPX_RATE = getBurnEPXRATEFor(_owner);
        // 全量 增加 总分享算力
        // 没有存款 没有共享算力收益
        // 不影响 总共享算力
        if ( _burn.deposits > 0 ) {
            totalShare = (totalShare * EPX_RATE + _burn.share * (newBurnEPX_RATE - _burn.shareMultiplierEPX_RATE)) / EPX_RATE;
        }
        // 更新 倍数
        _burn.shareMultiplierEPX_RATE = newBurnEPX_RATE;
    }

    // 只有 shareMultiplierEPX_RATE 为 0 时需要初始化
    // 初始化 是 shareMultiplierEPX_RATE 为 0
    // 只增加 shareMultiplierEPX_RATE 倍数
    // 注入到 stake 接口
    // 用户 没有 deposits 时
    // shareMultiplierEPX_RATE 为 0 不影响
    // 用户 有 deposits 时 需要先 stake stake 前 修改 shareMultiplierEPX_RATE
    // 第一次 stake 生效前，收益都没有到 shareMultiplierEPX_RATE 上
    // 应先 结算上一次 收益，而 user 在 更新收益前没有 收益 
    // 所以执行顺序 应为 结算对公 结算私人 充值，
    // 如果 有 deposits ， 增加 totalShare
    function _initBurn(address _owner) internal {
        Staked storage _burn = _staked[_owner];
        if ( _burn.shareMultiplierEPX_RATE == 0 ) {
            uint256 newBurnEPX_RATE = getBurnEPXRATEFor(_owner);
            // 更新 倍数
            _burn.shareMultiplierEPX_RATE = newBurnEPX_RATE;
        }
    } 

    // 设置时间倍数
    function timePowerEPX_RATE(uint256 _end) public view returns(uint256) {
        if (_end <= startTime || startTime == 0) return EPX_RATE;
        // 可以算 20 年
        int128 sc = int128(uint128((_end - startTime) << 64));
        int128 day = int128(uint128(2 days << 64));

        // 分子 a / b = 1.005
        int128 a = int128(uint128(1005 << 64));
        // 分母
        int128 b = int128(uint128(1000 << 64));
        
        uint256 pow = uint256(int256(power(a.div(b), sc.div(day))));
        return uint256(pow ** 2  * EPX_RATE ) >> 128;
    }

    // 更新 锁仓 和 存款倍数
    function _upDateStakeMultiplierFor(Staked storage _owner, uint _usdtWei) internal returns(uint _addDeposits) {
        uint _now = block.timestamp;
        uint256 multiplierEPX_RATE = timePowerEPX_RATE(_now);
        // 时间倍数 单币累加
        _addDeposits = _usdtWei * multiplierEPX_RATE / EPX_RATE;
        // mint 阶段 1.5 倍
        if ( isMint() ) {
            _addDeposits = _addDeposits * 3 / 2;
        }
        _owner.deposits += _addDeposits;
    }

    // 更新用户收益
    function _upDateStakeRewards(Staked storage _owner) internal {
        // 动态收益
        // 没有存款 总分享算力没有份额
        // 没有收益
        if ( _owner.deposits > 0 ) {
            uint256 _availableRewards = 0;
            _availableRewards = _owner.deposits * ( depositsNetEPX - _owner.depositsNetEPX ) / EPX;
            _availableRewards += _owner.share * _owner.shareMultiplierEPX_RATE * ( shareNetEPX - _owner.shareNetEPX ) / EPX / EPX_RATE;
            _owner.availableRewards += _availableRewards;
        }
        _owner.shareNetEPX = shareNetEPX;
        _owner.depositsNetEPX = depositsNetEPX;
    }

    /////////// swap ///////////
    // 配平模式
    // IMiner(minerPool).mining();
    function _transferLp(uint256 _usdtWei) internal returns(uint256 _lp) {

        address _self = address(this);
        usdt.safeTransferFrom(_msgSender(), _self, _usdtWei);

        if ( isMint() ) {
            // 直接配资
            (uint _sixRes, uint _usdtRes) = getReserves();
            uint _mintSix = _sixRes * _usdtWei / _usdtRes;

            // 仅只有本合约可以购买和添加流动性
            _lp = _mintLpFor( _self, address(treasury), _mintSix, _usdtWei );
        } else {
            // 买币
            _lp = _addLpFrom( _self, address(treasury), 0, _usdtWei, 0, 9975);
        }
    }

    // 存

    // deposits change
    function _depositisUsdtFor(address _owner, uint256 _usdtWei) internal {
        require(_usdtWei > 0, "usdt not 0");
        // 充 usdt 换成 mUSDT
        // 30% 转入国库
        uint _usdt1 = _usdtWei * 3 / 10;
        usdt.safeTransferFrom(_msgSender(), address(treasury), _usdt1);
        // 剩余 usdt
        _usdt1 = _usdtWei - _usdt1;
        // mint 模式
        // 更换 trim 控制不同模式
        uint256 lpWei = _transferLp(_usdt1);

        Staked storage _staker = _staked[_owner];
        // 更新
        _staker.lpWei += lpWei;
        // 销毁时 激活 share
        // 1. 初始化 shareMultiplierEPX_RATE
        // 2. 增加 totalShare
        // totalShare 和 shareMultiplierEPX_RATE 关联
        // burnedUsdt , share , shareMultiplierEPX_RATE 改变 更新 totalShare
        // _staker.burnedUsdt == 0 激活
        if ( _staker.burnedUsdt == 0 ) {
            if ( _staker.shareMultiplierEPX_RATE == 0 ) {
                // 不一定是 0.5 ，有可能销毁了 很多，再进来stake
                _staker.shareMultiplierEPX_RATE = getBurnEPXRATEFor(_owner);
            }
            // 存款时
            totalShare += _staker.share * _staker.shareMultiplierEPX_RATE / EPX_RATE;
        }
        
        
        //////////// 调整静态算力 ////////////

        // 不需要考虑时间倍数
        _staker.burnedUsdt += _usdtWei;
        // 最后增加 totalUSDT 为最后一笔 mint 完后 在开启交易模式
        totalUsdt += _usdtWei;
        //第一次 关闭mint，启动衰减
        bool _isMint = isMint();
        
        if ( _isMint ) {
            require(_staker.burnedUsdt <= 1e22, "burned need < 10000");
        } 
        
        if ( startTime == 0 && !_isMint ) {
            startTime = block.timestamp;
        } 
    }

    //////////// 算力 ////////////
    // function _lp() internal pure returns(address) {
    //     return 0xe825856f59766cc5db63db26b04A8981f23896C3;
    // }
    // 修改分享算力
    function _getShareMulEPX_RATE(uint i) internal pure returns(uint) {
        if ( i == 0 ) return EPX_RATE / 10;
        else if ( i == 1 ) return EPX_RATE / 20;
        else return 0;
    }

    function _changeShareFor(address _owner_, uint _deltaDeposits, uint _usdtWei) internal {
        // Staked storage _owner = _staked[_owner_];

        // totalShare = deposits[i] ? share[i] * shareMul[i] : 0
        // totalShare 依赖 deposits , share , shareMul
        uint _totalShare = totalShare;
        // 直接增加静态增量
        totalDeposits += _deltaDeposits;

        address _refOwner = _owner_;
        for(uint256 i = 0; i < 2; i ++) {
            // 出本体外的上面 30 人
            // console.log("1 _refOwner %s ", _refOwner);
            _refOwner = relation.referrer(_refOwner);
            // console.log("2 _refOwner %s ", _refOwner);

            // 推荐可约可以参与 算力
            if ( _refOwner == address(1) ) break;
            
            Staked storage _staker = _staked[_refOwner];

            _staker.teamUsdt += _usdtWei;

            // _staker.deposits > 0 时 已被初始化，不会执行 init Burn
            // _staker.deposits = 0 时 执行 init Burn，但 _upDateStakeRewards 并不计算收益
            // 所以这里不会 影响 _upDateStakeRewards，两者互斥
            // 这里 修改 shareMultiplierEPX_RATE 并没有影响 _totalShare ，因为 _totalShare 在 _staker.deposits = 0 时并不增加，与 init burn 互斥
            if ( _staker.shareMultiplierEPX_RATE == 0 ) {
                // 不一定是 0.5 ，有可能销毁了 很多，再进来stake
                _staker.shareMultiplierEPX_RATE = getBurnEPXRATEFor(_refOwner);
            }

            _upDateStakeRewards(_staker);            

            uint _deltaShare = _getShareMulEPX_RATE(i) * _deltaDeposits / EPX_RATE;
            // console.log("_getShareMulEPX_RATE %s | _deltaDeposits %s | _deltaShare %s ",_getShareMulEPX_RATE(i), _deltaDeposits, _deltaShare);
            // 净分享算力
            _staker.share += _deltaShare;
            // 只影响 _totalShare
            // share change
            // _staker 没有销毁 不享受 分享算力，在 claim 里限制了，这里只要排除 _totalShare 可以同步 净值
            
            if ( _staker.deposits > 0 ) {
                // _deltaShare * shareMultiplierEPX_RATE 不需要进行总量换算
                // shareMultiplierEPX_RATE 改变时 已重置 _totalShare
                // 与 init burn 互斥 所以不影响
                _totalShare += _deltaShare * _staker.shareMultiplierEPX_RATE / EPX_RATE;
            }
            
        }
        totalShare = _totalShare;
    
    }

    // 赎回
    // 销毁 lp 锁仓到 国库
    // 30% 转入国库
    // mint 阶段 mint 代币配平，不可交易【重点：需要限制 配平合约调用，防止被绕开】
    // 交易阶段 买入配平 【控制开关只能由 trim 合约买卖 token】
    // 算力增加 按时间倍数

    function stake(uint256 _usdtWei) external checkBind {
        
        // 更新净值
        upDateNet();
        // 剩余转入配平

        address _sender = _msgSender();
        Staked storage _owner = _staked[_sender];
        // 收取收益
        _upDateStakeRewards(_owner);

        // 更新 stake 倍数
        uint _addDeposits = _upDateStakeMultiplierFor(_owner, _usdtWei);
        // 存入 _usdtWei
        // 增加 用户 usdt 时，增加 totalUsdt 放到 upstak 下面，会影响 isMint
        _depositisUsdtFor(_sender,  _usdtWei);
        // 修改算力
        _changeShareFor(_sender, _addDeposits, _usdtWei);
        // 检查 算力
    }

    /////////// 挖矿 ///////////
    event Miner(uint256 deposits, uint256 share);

    function minerRate(
        uint256 _newEarn
    ) public view returns(
        uint256 _bonus,
        uint256 _ecology,
        uint256 _discount,
        uint256 _staker
    ) {
        _bonus = _newEarn * bonusRateEPX_RATE / EPX_RATE;
        _ecology = _newEarn * ecologyRateEPX_RATE / EPX_RATE;
        _discount = _newEarn * discountRateEPX_RATE / EPX_RATE;
        _staker = _newEarn - _bonus - _ecology - _discount;
    }
    // 更新净值
    // 拉取 新累积出块数
    // 计算出块
    // 修改净值
    // 更新 beforeEarnTokenBalance
    function upDateNet() public {

        // 计算挖矿差额
        uint256 _min = IMiner(minerPool).mining(block.timestamp);
        uint256 _newEarn = _min - beforeEarnTokenBalance;
        (,,,_newEarn) = minerRate(_newEarn);
        // 分红
        if ( _newEarn == 0 ) return;
        
        // 收益
        if ( _newEarn > 0 ) {
            // 静态 收益
            uint _deRewards;

            // 更新 存款净值
            if (shareNetRateEPX_RATE > EPX_RATE || shareNetRateEPX_RATE == 0) {
                // 按【自然】比例分配
                uint _total = totalDeposits + totalShare;
                _deRewards = _newEarn * totalDeposits / _total;
                _newEarn -= _deRewards;
            } else {
                _deRewards = (EPX_RATE - shareNetRateEPX_RATE) * _newEarn / EPX_RATE;
                // 扣除动态
                _newEarn -= _deRewards;
            }

            // 净值增加就是在分配
            // 有 _newEarn 但不增加净值
            // beforeEarnTokenBalance 已更新
            // 本次分配就未参与
            // 100 / 100 / 365 / 24 / 3600 * 2**64 = 584942417355 最大支持 5849424173 倍 算力 差
            if ( totalDeposits > 0 ) {
                depositsNetEPX += EPX * _deRewards / totalDeposits;
            }
            if ( totalShare > 0 ) {
                shareNetEPX += EPX * _newEarn / totalShare;
            }

            beforeEarnTokenBalance = _min;
            // // 更新 累积出块
            // // 出现 min 太小导致 净值不增加 造成 不出块就不更新 beforeEarnTokenBalance;
            // // 直至 min 增加到 一定量 可以出块 才更新 beforeEarnTokenBalance
            // // 解决算力过大 导致
            // beforeEarnTokenBalance = _min;
        }

        
    }
    function _sendRewardToken(address _to, uint _amount) internal {
        // console.log("assetCustody %s", address(assetCustody));
        // if ( _amount > 0 ) assetCustody.withdraw(sixcd, _to, _amount);
        // 节省 gas 本地调用
        if ( _amount > 0 ) sixcd.safeTransfer(_to, _amount);
    }
    // 结算 分发余额
    function _settlement() internal {
        uint256 _newEarn = beforeEarnTokenBalance - lasteSettlementBalance;
        (uint256 _bonus, uint256 _ecology, uint256 _discount,) = minerRate(_newEarn);
        if (_newEarn > 0) {
            _sendRewardToken(address(bonus), _bonus);
            _sendRewardToken(address(ecology), _ecology);
            _sendRewardToken(address(discount), _discount);
            lasteSettlementBalance = beforeEarnTokenBalance;
        }
    }

    function claimFor(address _owner_) external returns(uint256 rewrods) {
        upDateNet();
        _settlement();
        Staked storage _owner = _staked[_owner_];
        _upDateStakeRewards(_owner);
        rewrods = _owner.availableRewards;
        // assetCustody 币不足 会报错
        _owner.availableRewards -= rewrods;
        _sendRewardToken(_owner_, rewrods);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function power(int128 x, int128 y) internal pure returns(int128) {
        return (y.mul(x.log_2())).exp_2();
    }
}