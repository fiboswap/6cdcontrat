// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../utils/SafeToken.sol";
import "../interface/IPair.sol";

import "hardhat/console.sol";


// 减少路径，改库仅做计算，避免了买卖全权漏洞 和 0.001 最小转账剩余问题

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract TrimV2 {
    using SafeToken for address;
    // 0.01%
    uint256 private constant EPX = 10000; 
    bytes private constant EMPTY_DATA = bytes("");

    IFactory private factory;

    // 每次使用该库是初始化 lp 和 方向
    // 每次调用需要频繁【4次以上】调用 getPair 接口
    // 频繁调用接口 的 gas 比 写入内存缓存值的 gas 贵
    // 一次判断 比 一次覆盖便宜
    address private _pair_;
    address private _token0_;
    address private _token1_;
    bool private _isReversed_;

    function initFactory(IFactory _factory) internal {
        factory = _factory;
    }
    
    // 不频繁改变币对的情况下【设置一次 复用4次】比每次调用 lp 接口划算
    // 不改变 币对的情况下 比 调用接口节省很多gas
    function initPair(address token0, address token1) internal returns(address, bool) {
        // 优化 gas
        if ( _token0_ != token0 || _token1_ != token1 ) {
            (_pair_, _isReversed_) = getPair(token0, token1);
            _token0_ = token0; 
            _token1_ = token1; 
        }
        return (_pair_, _isReversed_);
    }

    function getPair(address token0, address token1) internal view returns(address pair, bool isReversed) {
        // 优化 gas
        pair = factory.getPair(token0, token1);
        isReversed = IPair(pair).token0() != token0;
    }

    function getReserves(address pair, bool isReversed) internal view returns(uint token0Reserve, uint token1Reserve) {
        (token0Reserve, token1Reserve,) = IPair(pair).getReserves();
        if ( isReversed ) {
            (token0Reserve, token1Reserve) = (token1Reserve, token0Reserve);
        }
    }

    function getReserves() internal view returns(uint token0Reserve, uint token1Reserve) {
        return getReserves(_pair_, _isReversed_);
    }

    /// @dev Compute optimal deposit amount
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amonut of token B desired to deposit
    /// @param resA amount of token A in reserve
    /// @param resB amount of token B in reserve
    function optimalDeposit(
        uint256 amtA,
        uint256 amtB,
        uint256 resA,
        uint256 resB,
        uint256 feeEPX
    ) internal pure returns (uint256 swapAmt, bool isReversed) {
        if (amtA * resB == amtB * resA) {
            swapAmt = 0;
            isReversed = false;
        }
        // else 可以节省 gas
        else if (amtA * resB > amtB * resA) {
            swapAmt = _optimalDepositA(amtA, amtB, resA, resB, feeEPX);
            isReversed = false;
        }
        else {
            swapAmt = _optimalDepositA(amtB, amtA, resB, resA, feeEPX);
            isReversed = true;
        }
    }

    function _optimalDepositA(
        uint256 amtA,
        uint256 amtB,
        uint256 resA,
        uint256 resB,
        uint256 feeEPX
    ) internal pure returns (uint256) {
        require(amtA * resB >= amtB * resA, "Reversed");
        uint256 a = feeEPX;
        uint256 b = (EPX + feeEPX) * resA;
        uint256 _c = amtA * resB - amtB * resA;
        uint256 c = _c * EPX  * resA / (amtB + resB);

        uint256 d = 4 * a * c;
        uint256 e = sqrt(b ** 2 + d);
        uint256 numerator = e - b;
        uint256 denominator = 2*a;
        return numerator / denominator;
    }

    // 数量即表示 token
    function _mintLpFor(
        address from,
        address to,
        uint amount0,
        uint amount1
    ) internal returns(uint256 moreLPAmount) {
        if ( _isReversed_ ) {
            (amount0, amount1) = (amount1, amount0);
        }
        if ( from == address(this) ) {
            _token0_.safeTransfer( _pair_, amount0);
            _token1_.safeTransfer( _pair_, amount1);
        } else {
            _token0_.safeTransferFrom(from, _pair_, amount0);
            _token1_.safeTransferFrom(from, _pair_, amount1);
        }
        moreLPAmount = IPair(_pair_).mint(to);
    }

    // returns(uint , uint)
    function _removeLpFor(address _from, address _to, uint _amount) internal {
        if ( _from == address(this) ) {
            _pair_.safeTransfer( _pair_, _amount);
        } else {
            _pair_.safeTransferFrom(_from, _pair_, _amount);
        }
        IPair(_pair_).burn(_to);
    }

    // for 的好处 省 gas
    // from 为自己时 调用 transfer
    function _swapFor(
        uint amountIn0,
        uint amountIn1,
        uint reserveIn,
        uint reserveOut,
        address from,
        address to,
        uint256 feeEPX
    ) internal returns(uint amount0Out, uint amount1Out) {
        address tokenIn;
        uint amountIn;
        bool outTokne1;
        uint _out;
        if ( amountIn1 == 0 ) {
            tokenIn = _token0_;
            amountIn = amountIn0;
            outTokne1 = true;
            _out = getAmountOut(amountIn, reserveIn, reserveOut, feeEPX);
        }
        else if ( amountIn0 == 0 ) {
            tokenIn = _token1_;
            amountIn = amountIn1;
            outTokne1 = false;
            _out = getAmountOut(amountIn, reserveOut, reserveIn, feeEPX);
        }
        else {
            require(false, "amountIn error");
        }

        
        if (outTokne1) {
            amount1Out = _out;
        } else {
            amount0Out = _out;
        }

        if ( from == address(this) ) {
            tokenIn.safeTransfer(_pair_, amountIn);
        } else {
            tokenIn.safeTransferFrom(from , _pair_, amountIn);
        }
        // 重新核对 token0 位置
        if ( _isReversed_ ) {
            (amount0Out, amount1Out) = (amount1Out, amount0Out);
        }
        IPair(_pair_).swap(amount0Out, amount1Out, to, EMPTY_DATA);
    }

    // isToken1 = true 表示 token1 多出来了 需要买入
    // swapAmt 表示 需要兑换出去的 token 数量
    // 
    function _calAndSwapFor(address _from, address _to, uint token0Amount, uint token1Amount, uint feeEPX) internal returns(bool isToken1, uint swapAmt) {
        (uint token0Reserve, uint token1Reserve) = getReserves();
        (swapAmt, isToken1) = optimalDeposit(token0Amount, token1Amount, token0Reserve, token1Reserve, feeEPX);
        if (swapAmt > 0) {
            uint amountIn0 = 0;
            uint amountIn1 = 0;
            if ( isToken1 ) {
                amountIn1 = swapAmt;
            } else {
                amountIn0 = swapAmt;
            }
            _swapFor(amountIn0, amountIn1, token0Reserve, token1Reserve, _from, _to, feeEPX);
        }
    }

    function _addLpFrom(address _from, address _to, uint token0Amount, uint token1Amount, uint minLp, uint feeEPX) internal returns(uint moreLPAmount) {
        
        // 买入配平的 token
        int balance0Before = int(_token0_.myBalance());
        int balance1Before = int(_token1_.myBalance());

        address _self = address(this);
        
        // 配平需要在预支代币
        if ( _from != _self ) {
            if (token0Amount > 0) {
                _token0_.safeTransferFrom(_from, _self, token0Amount);
            }

            if (token1Amount > 0) {
                _token1_.safeTransferFrom(_from, _self, token1Amount);
            }
        }
        _calAndSwapFor( _self, _self, token0Amount, token1Amount, feeEPX);

        int balance0After = int(_token0_.myBalance());
        int balance1After = int(_token1_.myBalance());
        // 计算 变量
        // from == _self 时，balance1 可能被卖出，所以用 int

        token0Amount = uint(int(token0Amount) + balance0After - balance0Before);
        token1Amount = uint(int(token1Amount) + balance1After - balance1Before);

        _token0_.safeTransfer(_pair_, token0Amount);
        _token1_.safeTransfer(_pair_, token1Amount);
        moreLPAmount = IPair(_pair_).mint(_to);

        require(moreLPAmount >= minLp, "insufficient tokens received");
    }

    function _buyFor(
        uint amountIn0,
        uint amountIn1,
        address from,
        address to,
        uint256 feeEPX
    ) internal returns(uint, uint) {
        (uint token0Reserve, uint token1Reserve) = getReserves();
        return _swapFor(amountIn0, amountIn1, token0Reserve, token1Reserve, from, to, feeEPX);
    }
    
    // 判断输入
    // p = reserve0 / reserve1
    // k = reserve0 * reserve1
    // p1 = (token0 + reserve0) / (token1 + reserve1)
    // x = sqrt( k * p1 )
    // dx = x - reserve0
    // dy = k / x

    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // feeEPX 9975
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint256 feeEPX) internal pure returns (uint amountOut) {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        uint amountInWithFee = amountIn * feeEPX;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = reserveIn * EPX + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function sqrt(uint x) public pure returns (uint) {
        if (x == 0) return 0;
        uint xx = x;
        uint r = 1;
    
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
    
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }
    
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1; // Seven iterations should be enough
        uint r1 = x / r;
        return (r < r1 ? r : r1);
    }
}


contract TrimV2Generic is TrimV2 {

    using SafeToken for address;

    constructor(IFactory _factory) {
        initFactory(_factory);
    }

    function _swapFor(
        address tokenIn,
        address tokenOut,
        uint amountIn,
        address from,
        address to,
        uint feeEPX
    ) internal returns(uint amount0Out, uint amount1Out) {
        (address pair, bool isReversed) = getPair(tokenIn, tokenOut);
        (uint tokenInReserve, uint tokenOutReserve) = getReserves(pair, isReversed);

        uint _out = getAmountOut(amountIn, tokenInReserve, tokenOutReserve, feeEPX);
        if (isReversed) {
            amount0Out = _out;
        } else {
            amount1Out = _out;
        }

        if ( from == address(this) ) {
            tokenIn.safeTransfer(pair, amountIn);
        } else {
            tokenIn.safeTransferFrom(from , pair, amountIn);
        }
        
        IPair(pair).swap(amount0Out, amount1Out, to, bytes(""));
    }

    function _safeTransferFrom(address _token, address _from, address _to, uint _amount) internal {
        if ( _from == address(this) ) {
            _token.safeTransfer(_to, _amount);
        } else {
            _token.safeTransferFrom(_from , _to, _amount);
        }
    }

}