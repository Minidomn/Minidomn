// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/fei/ITribeChief.sol";
import "../interfaces/curve/IStableSwap.sol";
import "../interfaces/uniswap/IUniswapV2Router.sol";
import "../interfaces/uniswap/IUniswapV2Pair.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    event Log();

    uint8 public immutable TRIBE_CHIEF_PID = 1;
    address public immutable TRIBE_ADDRESS =
        address(0xc7283b66Eb1EB5FB86327f08e1B5816b0720212B);
    address public immutable FEI_ADDRESS =
        address(0x956F47F50A910163D8BF957Cf5846D573E7f87CA);
    address public immutable WETH_ADDRESS =
        address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public immutable TRIBE_CHIEF_ADDRESS =
        address(0x9e1076cC0d19F9B0b8019F384B0a29E48Ee46f7f);
    address public immutable UNISWAP_V2_ROUTER_ADDRESS =
        address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    constructor(address _vault) public BaseStrategy(_vault) {
        // approve uniswap v2 router to use tribe held by the strategy
        IERC20(address(0xc7283b66Eb1EB5FB86327f08e1B5816b0720212B)).approve(
            address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D),
            uint256(-1)
        );
        // approve tribe chief to use want held by the strategy
        want.approve(
            address(0x9e1076cC0d19F9B0b8019F384B0a29E48Ee46f7f),
            uint256(-1)
        );
        // approve curve pool to use fei held by the strategy
        IERC20(0x956F47F50A910163D8BF957Cf5846D573E7f87CA).approve(
            address(want),
            uint256(-1)
        );
    }

    function name() external view override returns (string memory) {
        return "StrategyCurveFEI3CRV";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // liquid want balance
        uint256 _wantBalance = want.balanceOf(address(this));

        // staked want balance
        uint256 _stakedWant =
            ITribeChief(TRIBE_CHIEF_ADDRESS).getTotalStakedInPool(
                TRIBE_CHIEF_PID,
                address(this)
            );

        // getting pending and held tribe
        uint256 _pendingTribe =
            ITribeChief(TRIBE_CHIEF_ADDRESS).pendingRewards(
                TRIBE_CHIEF_PID,
                address(this)
            );
        uint256 _heldTribe = IERC20(TRIBE_ADDRESS).balanceOf(address(this));
        uint256 _totalTribe = _heldTribe.add(_pendingTribe);

        uint256 _gainedWant = 0;
        if (_totalTribe > 0) {
            // getting fei acquired from selling tribe
            address[] memory _path = new address[](2);
            _path[0] = TRIBE_ADDRESS;
            _path[1] = FEI_ADDRESS;
            uint256[] memory _amountsOut =
                IUniswapV2Router(UNISWAP_V2_ROUTER_ADDRESS).getAmountsOut(
                    _totalTribe,
                    _path
                );
            uint256 _feiAmount = _amountsOut[_amountsOut.length - 1];

            // getting the amount of lp tokens from lping on curve with the pending fei
            uint256[] memory _amounts = new uint256[](2);
            _amounts[0] = _feiAmount;
            _amounts[1] = 0;
            _gainedWant = IStableSwap(address(want)).calc_token_amount(
                _amounts,
                true
            );
        }

        return _wantBalance.add(_stakedWant).add(_gainedWant);
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 _wantBalance = IERC20(want).balanceOf(address(this));

        // harvest tribe rewards
        ITribeChief(TRIBE_CHIEF_ADDRESS).harvest(
            TRIBE_CHIEF_PID,
            address(this)
        );

        // if any rewards were harvested, sell them for fei and deposit them
        // on curve, getting back more want in the process
        uint256 _sellableTribe = IERC20(TRIBE_ADDRESS).balanceOf(address(this));
        if (_sellableTribe > 0) {
            // selling tribe
            address[] memory _path = new address[](2);
            _path[0] = TRIBE_ADDRESS;
            _path[1] = FEI_ADDRESS;
            uint256[] memory _swappedAmounts =
                IUniswapV2Router(UNISWAP_V2_ROUTER_ADDRESS)
                    .swapExactTokensForTokens(
                    _sellableTribe,
                    0,
                    _path,
                    address(this),
                    block.timestamp
                );

            // lping fei on curve to get back more want
            uint256[] memory _amounts = new uint256[](2);
            _amounts[0] = _swappedAmounts[_swappedAmounts.length - 1];
            _amounts[1] = 0;
            IStableSwap(address(want)).add_liquidity(_amounts, 0);
        }

        // calculate gross profit from rewards selling
        _profit = want.balanceOf(address(this)) - _wantBalance;

        // if the outstanding debt is not covered by the profit
        if (_debtOutstanding > _profit) {
            // liquidate part of the position to cover it
            uint256 _toLiquidate = _debtOutstanding.sub(_profit);
            (, uint256 _notLiquidated) = liquidatePosition(_toLiquidate);

            // if the liquidation incurred a loss, report it (in both cases when
            // the loss simply eats part of profit, or when it makes the overall
            // position a loss)
            if (_notLiquidated < _profit) _profit = _profit.sub(_notLiquidated);
            else {
                _loss = _notLiquidated.sub(_profit);
                _profit = 0;
            }
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory _protectedTokens = new address[](2);
        _protectedTokens[0] = TRIBE_ADDRESS;
        _protectedTokens[1] = FEI_ADDRESS;
        return _protectedTokens;
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        address[] memory _path = new address[](2);
        _path[0] = WETH_ADDRESS;
        _path[1] = FEI_ADDRESS;
        uint256[] memory _amounts =
            IUniswapV2Router(UNISWAP_V2_ROUTER_ADDRESS).getAmountsOut(
                1 ether,
                _path
            );
        uint256 _ethUsdPrice = _amounts[_amounts.length - 1];
        return
            _amtInWei
                .mul(_ethUsdPrice)
                .mul(IStableSwap(address(want)).get_virtual_price())
                .div(1e18);
    }

    function updateTribeUniswapV2RouterAllowance() external {
        IERC20(TRIBE_ADDRESS).approve(UNISWAP_V2_ROUTER_ADDRESS, uint256(-1));
    }

    function updateWantTribeChiefAllowance() external {
        want.approve(TRIBE_CHIEF_ADDRESS, uint256(-1));
    }

    function updateFeiCurvePoolAllowance() external {
        IERC20(FEI_ADDRESS).approve(address(want), uint256(-1));
    }
}
