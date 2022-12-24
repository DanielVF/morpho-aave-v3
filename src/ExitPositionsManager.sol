// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {IPool} from "./interfaces/aave/IPool.sol";

import {MarketLib} from "./libraries/Libraries.sol";
import {Types} from "./libraries/Types.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {Constants} from "./libraries/Constants.sol";
import {MarketLib} from "./libraries/MarketLib.sol";
import {PoolInteractions} from "./libraries/PoolInteractions.sol";
import {Math} from "@morpho-utils/math/Math.sol";
import {PercentageMath} from "@morpho-utils/math/PercentageMath.sol";

import {PositionsManagerInternal} from "./PositionsManagerInternal.sol";
import {ERC20, SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";

contract ExitPositionsManager is PositionsManagerInternal {
    using SafeTransferLib for ERC20;
    using PoolInteractions for IPool;
    using PercentageMath for uint256;

    function withdrawLogic(address poolToken, uint256 amount, address supplier, address receiver, uint256 maxLoops)
        external
        returns (uint256 withdrawn)
    {
        _updateIndexes(poolToken);
        amount = Math.min(_getUserSupplyBalance(poolToken, supplier), amount);
        _validateWithdraw(poolToken, supplier, receiver, amount);

        (uint256 onPool, uint256 inP2P, uint256 toBorrow, uint256 toWithdraw) =
            _executeWithdraw(poolToken, supplier, amount, maxLoops);

        address underlying = _market[poolToken].underlying;
        if (toWithdraw > 0) {
            _pool.withdrawFromPool(underlying, poolToken, toWithdraw);
        }
        if (toBorrow > 0) _pool.borrowFromPool(underlying, toBorrow);
        ERC20(underlying).safeTransfer(receiver, amount);

        emit Events.Withdrawn(supplier, receiver, poolToken, amount, onPool, inP2P);
        return amount;
    }

    // TODO: Implement
    function withdrawCollateralLogic(address poolToken, uint256 amount, address supplier, address receiver)
        external
        returns (uint256 withdrawn)
    {
        return 0;
    }

    function repayLogic(address poolToken, uint256 amount, address repayer, address onBehalf, uint256 maxLoops)
        external
        returns (uint256 repaid)
    {
        Types.Market storage market = _market[poolToken];
        _updateIndexes(poolToken);
        amount = Math.min(_getUserBorrowBalance(poolToken, onBehalf), amount);
        _validateRepay(poolToken, amount);

        ERC20 underlyingToken = ERC20(market.underlying);
        underlyingToken.safeTransferFrom(repayer, address(this), amount);

        (uint256 onPool, uint256 inP2P, uint256 toRepay, uint256 toSupply) =
            _executeRepay(poolToken, onBehalf, amount, maxLoops);

        if (toRepay > 0) _pool.repayToPool(market.underlying, toRepay);
        if (toSupply > 0) _pool.supplyToPool(market.underlying, toSupply);

        emit Events.Repaid(repayer, onBehalf, poolToken, amount, onPool, inP2P);
        return amount;
    }

    struct LiquidateVars {
        uint256 closeFactor;
        uint256 amountToLiquidate;
        uint256 amountToSeize;
        uint256 toSupply;
        uint256 toRepay;
        uint256 toBorrow;
        uint256 toWithdraw;
    }

    function liquidateLogic(
        address poolTokenBorrowed,
        address poolTokenCollateral,
        uint256 amount,
        address borrower,
        address liquidator
    ) external returns (uint256 liquidated, uint256 seized) {
        LiquidateVars memory vars;

        _updateIndexes(poolTokenBorrowed);
        _updateIndexes(poolTokenCollateral);

        vars.closeFactor = _validateLiquidate(poolTokenBorrowed, poolTokenCollateral, borrower);

        vars.amountToLiquidate = Math.min(
            amount,
            _getUserBorrowBalance(poolTokenBorrowed, borrower).percentMul(vars.closeFactor) // Max liquidatable debt.
        );
        vars.amountToSeize;

        (vars.amountToLiquidate, vars.amountToSeize) =
            _calculateAmountToSeize(poolTokenBorrowed, poolTokenCollateral, borrower, vars.amountToLiquidate);

        ERC20(_market[poolTokenBorrowed].underlying).safeTransferFrom(liquidator, address(this), vars.amountToLiquidate);

        (,, vars.toSupply, vars.toRepay) = _executeRepay(poolTokenBorrowed, borrower, vars.amountToLiquidate, 0);
        (,, vars.toBorrow, vars.toWithdraw) = _executeWithdraw(poolTokenCollateral, borrower, vars.amountToSeize, 0);

        _pool.supplyToPool(_market[poolTokenBorrowed].underlying, vars.toSupply);
        _pool.repayToPool(_market[poolTokenBorrowed].underlying, vars.toRepay);
        _pool.borrowFromPool(_market[poolTokenCollateral].underlying, vars.toBorrow);
        _pool.withdrawFromPool(_market[poolTokenCollateral].underlying, poolTokenCollateral, vars.toWithdraw);

        ERC20(_market[poolTokenCollateral].underlying).safeTransfer(liquidator, vars.amountToSeize);

        emit Events.Liquidated(
            liquidator, borrower, poolTokenBorrowed, vars.amountToLiquidate, poolTokenCollateral, vars.amountToSeize
            );
        return (vars.amountToLiquidate, vars.amountToSeize);
    }
}
