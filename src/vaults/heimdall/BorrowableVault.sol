// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.19;

import "../../interfaces/IIRM.sol";
import "../../interfaces/IPriceOracle.sol";
import "../solmate/VaultSimpleBorrowable.sol";

/// @title VaultRegularBorrowable
/// @notice This contract extends VaultSimpleBorrowable with additional features like interest rate accrual and
/// recognition of external collateral vaults and liquidations.
contract BorrowableVault is VaultSimpleBorrowable {
    using FixedPointMathLib for uint256;

    uint256 internal constant COLLATERAL_FACTOR_SCALE = 100;
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE = 20;
    uint256 internal constant TARGET_HEALTH_FACTOR = 125;
    uint256 internal constant ONE = 1e27;

    uint96 internal interestRate;
    uint256 internal lastInterestUpdate;
    uint256 internal interestAccumulator;
    mapping(address account => uint256) internal userInterestAccumulator;
    mapping(address asset => uint256) internal collateralFactor;

    // IRM
    IIRM public irm;

    // oracle
    ERC20 public referenceAsset; // This is the asset that we use to calculate the value of all other assets
    IPriceOracle public oracle;

    error InvalidCollateralFactor();
    error SelfLiquidation();
    error VaultStatusCheckDeferred();
    error ViolatorStatusCheckDeferred();
    error NoLiquidationOpportunity();
    error RepayAssetsInsufficient();
    error RepayAssetsExceeded();
    error CollateralDisabled();

    constructor(
        IEVC _evc,
        ERC20 _asset,
        IIRM _irm,
        IPriceOracle _oracle,
        ERC20 _referenceAsset,
        string memory _name,
        string memory _symbol
    ) VaultSimpleBorrowable(_evc, _asset, _name, _symbol) {
        irm = _irm;
        oracle = _oracle;
        referenceAsset = _referenceAsset;
        lastInterestUpdate = block.timestamp;
        interestAccumulator = ONE;
    }

    /// @notice Sets the IRM of the vault.
    /// @param _irm The new IRM.
    function setIRM(IIRM _irm) external onlyOwner {
        irm = _irm;
    }

    /// @notice Sets the reference asset of the vault.
    /// @param _referenceAsset The new reference asset.
    function setReferenceAsset(ERC20 _referenceAsset) external onlyOwner {
        referenceAsset = _referenceAsset;
    }

    /// @notice Sets the price oracle of the vault.
    /// @param _oracle The new price oracle.
    function setOracle(IPriceOracle _oracle) external onlyOwner {
        oracle = _oracle;
    }

    /// @notice Sets the collateral factor of an asset.
    /// @param _asset The asset.
    /// @param _collateralFactor The new collateral factor.
    function setCollateralFactor(address _asset, uint256 _collateralFactor) external onlyOwner {
        if (_collateralFactor > COLLATERAL_FACTOR_SCALE) {
            revert InvalidCollateralFactor();
        }

        collateralFactor[_asset] = _collateralFactor;
    }

    /// @notice Gets the current interest rate of the vault.
    /// @dev Reverts if the vault status check is deferred because the interest rate is calculated in the
    /// checkVaultStatus().
    /// @return The current interest rate.
    function getInterestRate() external view returns (uint256) {
        if (isVaultStatusCheckDeferred(address(this))) {
            revert VaultStatusCheckDeferred();
        }

        return interestRate;
    }

    /// @notice Gets the collateral factor of an asset.
    /// @param _asset The asset.
    /// @return The collateral factor.
    function getCollateralFactor(address _asset) external view returns (uint256) {
        return collateralFactor[_asset];
    }

    /// @notice Liquidates a violator account.
    /// @param violator The violator account.
    /// @param collateral The collateral of the violator.
    /// @param repayAssets The assets to repay.
    function liquidate(
        address violator,
        address collateral,
        uint256 repayAssets
    ) external callThroughEVC nonReentrant {
        address msgSender = _msgSenderForBorrow();

        if (msgSender == violator) {
            revert SelfLiquidation();
        }

        if (repayAssets == 0) {
            revert RepayAssetsInsufficient();
        }

        // due to later violator's account check forgiveness,
        // the violator's account must be fully settled when liquidating
        if (isAccountStatusCheckDeferred(violator)) {
            revert ViolatorStatusCheckDeferred();
        }

        // sanity check: the violator must be under control of the EVC
        if (!isControllerEnabled(violator, address(this))) {
            revert ControllerDisabled();
        }

        createVaultSnapshot();

        uint256 seizeAssets = _calculateAssetsToSeize(violator, collateral, repayAssets);

        _decreaseOwed(violator, repayAssets);
        _increaseOwed(msgSender, repayAssets);

        emit Repay(msgSender, violator, repayAssets);
        emit Borrow(msgSender, msgSender, repayAssets);

        if (collateral == address(this)) {
            // if the liquidator tries to seize the assets from this vault,
            // we need to be sure that the violator has enabled this vault as collateral
            if (!isCollateralEnabled(violator, collateral)) {
                revert CollateralDisabled();
            }

            balanceOf[violator] -= seizeAssets;
            balanceOf[msgSender] += seizeAssets;

            emit Transfer(violator, msgSender, seizeAssets);
        } else {
            // if external assets are being seized, the EVC will take care of safety
            // checks during the collateral control
            liquidateCollateralShares(collateral, violator, msgSender, seizeAssets);

            // there's a possibility that the liquidation does not bring the violator back to
            // a healthy state or the liquidator chooses not to repay enough to bring the violator
            // back to health. hence, the account status check that is scheduled during the
            // controlCollateral may fail reverting the liquidation. hence, as a controller, we
            // can forgive the account status check for the violator allowing it to end up in
            // an unhealthy state after the liquidation.
            // IMPORTANT: the account status check forgiveness must be done with care!
            // a malicious collateral could do some funky stuff during the controlCollateral
            // leading to withdrawal of more collateral than specified, or withdrawal of other
            // collaterals, leaving us with bad debt. to prevent that, we ensure that only
            // collaterals with cf > 0 can be seized which means that only vetted collaterals
            // are seizable and cannot do any harm during the controlCollateral.
            // the other option would be to snapshot the balances of all the collaterals
            // before the controlCollateral and compare them with expected balances after the
            // controlCollateral. however, this is out of scope for this playground.
            forgiveAccountStatusCheck(violator);
        }

        requireAccountAndVaultStatusCheck(msgSender);
    }

    /// @notice Calculates the liability and collateral of an account.
    /// @param account The account.
    /// @param collaterals The collaterals of the account.
    /// @param skipCollateralIfNoLiability A flag indicating whether to skip collateral calculation if the account has
    /// no liability.
    /// @return liabilityAssets The liability assets.
    /// @return liabilityValue The liability value.
    /// @return collateralValue The risk-adjusted collateral value.
    function _calculateLiabilityAndCollateral(
        address account,
        address[] memory collaterals,
        bool skipCollateralIfNoLiability
    )
        internal
        view
        virtual
        override
        returns (uint256 liabilityAssets, uint256 liabilityValue, uint256 collateralValue)
    {
        liabilityAssets = _debtOf(account);

        if (liabilityAssets == 0 && skipCollateralIfNoLiability) {
            return (0, 0, 0);
        } else if (liabilityAssets > 0) {
            // Calculate the value of the liability in terms of the reference asset
            liabilityValue = IPriceOracle(oracle).getQuote(liabilityAssets, address(asset), address(referenceAsset));
        }

        // Calculate the aggregated value of the collateral in terms of the reference asset
        for (uint256 i = 0; i < collaterals.length; ++i) {
            address collateral = collaterals[i];
            uint256 cf = collateralFactor[collateral];

            // Collaterals with a collateral factor of 0 are worthless
            if (cf != 0) {
                //for now treat ERC721s as they all have the same value. BalanceOf functions should have the same signature for both ERC20 and ERC721.
                uint256 collateralAssets = ERC20(collateral).balanceOf(account);

                if (collateralAssets > 0) {
                    collateralValue += (
                        IPriceOracle(oracle).getQuote(collateralAssets, collateral, address(referenceAsset)) * cf
                    ) / COLLATERAL_FACTOR_SCALE;
                }
            }
        }
    }

    /// @notice Calculates the amount of assets to seize from a violator's account during a liquidation event.
    /// @dev This function is used during the liquidation process to determine the amount of collateral to seize.
    /// @param violator The address of the violator's account.
    /// @param collateral The address of the collateral to be seized.
    /// @param repayAssets The amount of assets the liquidator is attempting to repay.
    /// @return The amount of collateral shares to seize from the violator's account.
    function _calculateAssetsToSeize(
        address violator,
        address collateral,
        uint256 repayAssets
    ) internal view returns (uint256) {
        // do not allow to seize the assets for collateral without a collateral factor.
        // note that a user can enable any address as collateral, even if it's not recognized
        // as such (cf == 0)
        uint256 cf = collateralFactor[collateral];
        if (cf == 0) {
            revert CollateralDisabled();
        }

        (uint256 liabilityAssets, uint256 liabilityValue, uint256 collateralValue) =
            _calculateLiabilityAndCollateral(violator, getCollaterals(violator), true);

        // trying to repay more than the violator owes
        if (repayAssets > liabilityAssets) {
            revert RepayAssetsExceeded();
        }

        // check if violator's account is unhealthy
        if (collateralValue >= liabilityValue) {
            revert NoLiquidationOpportunity();
        }

        // calculate dynamic liquidation incentive
        uint256 liquidationIncentive = 100 - (100 * collateralValue) / liabilityValue;

        if (liquidationIncentive > MAX_LIQUIDATION_INCENTIVE) {
            liquidationIncentive = MAX_LIQUIDATION_INCENTIVE;
        }

        // calculate the max repay value that will bring the violator back to target health factor
        uint256 maxRepayValue = (TARGET_HEALTH_FACTOR * liabilityValue - 100 * collateralValue)
            / (TARGET_HEALTH_FACTOR - (cf * (100 + liquidationIncentive)) / 100);

        // get the desired value of repay assets
        uint256 repayValue = IPriceOracle(oracle).getQuote(repayAssets, address(asset), address(referenceAsset));

        // check if the liquidator is not trying to repay too much.
        // this prevents the liquidator from liquidating entire position if not necessary.
        // if the at least half of the debt needs to be repaid to bring the account back to target health factor,
        // the liquidator can repay the entire debt.
        if (repayValue > maxRepayValue && maxRepayValue < liabilityValue / 2) {
            revert RepayAssetsExceeded();
        }

        // the liquidator will be transferred the collateral value of the repaid debt + the liquidation incentive
        uint256 seizeValue = (repayValue * (100 + liquidationIncentive)) / 100;
        uint256 shareUnit = 10 ** ERC20(collateral).decimals();

        uint256 seizeAssets =
            (seizeValue * shareUnit) / IPriceOracle(oracle).getQuote(shareUnit, collateral, address(referenceAsset));

        if (seizeAssets == 0) {
            revert RepayAssetsInsufficient();
        }

        return seizeAssets;
    }

    /// @notice Increases the owed amount of an account.
    /// @dev This function is overridden to snapshot the interest accumulator for the account.
    /// @param account The account.
    /// @param assets The assets.
    function _increaseOwed(address account, uint256 assets) internal virtual override {
        super._increaseOwed(account, assets);
        userInterestAccumulator[account] = interestAccumulator;
    }

    /// @notice Decreases the owed amount of an account.
    /// @dev This function is overridden to snapshot the interest accumulator for the account.
    /// @param account The account.
    /// @param assets The assets.
    function _decreaseOwed(address account, uint256 assets) internal virtual override {
        super._decreaseOwed(account, assets);
        userInterestAccumulator[account] = interestAccumulator;
    }

    /// @notice Returns the debt of an account.
    /// @dev This function is overridden to take into account the interest rate accrual.
    /// @param account The account.
    /// @return The debt of the account.
    function _debtOf(address account) internal view virtual override returns (uint256) {
        uint256 debt = owed[account];

        if (debt == 0) return 0;

        (, uint256 currentInterestAccumulator,) = _accrueInterestCalculate();

        return debt * currentInterestAccumulator / userInterestAccumulator[account];
    }

    /// @notice Accrues interest.
    /// @return The current values of total borrowed and interest accumulator.
    function _accrueInterest() internal virtual override returns (uint256, uint256) {
        (uint256 currentTotalBorrowed, uint256 currentInterestAccumulator, bool shouldUpdate) =
            _accrueInterestCalculate();

        if (shouldUpdate) {
            _totalBorrowed = currentTotalBorrowed;
            interestAccumulator = currentInterestAccumulator;
            lastInterestUpdate = block.timestamp;
        }

        return (currentTotalBorrowed, currentInterestAccumulator);
    }

    /// @notice Calculates the accrued interest.
    /// @return The total borrowed amount, the interest accumulator and a boolean value that indicates whether the data
    /// should be updated.
    function _accrueInterestCalculate() internal view virtual override returns (uint256, uint256, bool) {
        uint256 timeElapsed = block.timestamp - lastInterestUpdate;
        uint256 oldTotalBorrowed = _totalBorrowed;
        uint256 oldInterestAccumulator = interestAccumulator;

        if (timeElapsed == 0) {
            return (oldTotalBorrowed, oldInterestAccumulator, false);
        }

        uint256 newInterestAccumulator =
            (FixedPointMathLib.rpow(uint256(interestRate) + ONE, timeElapsed, ONE) * oldInterestAccumulator) / ONE;

        uint256 newTotalBorrowed = oldTotalBorrowed * newInterestAccumulator / oldInterestAccumulator;

        return (newTotalBorrowed, newInterestAccumulator, true);
    }

    /// @notice Updates the interest rate.
    function _updateInterest() internal virtual override {
        uint256 borrowed = _totalBorrowed;
        uint256 poolAssets = _totalAssets + borrowed;

        uint32 utilisation;
        if (poolAssets != 0) {
            utilisation = uint32((borrowed * type(uint32).max) / poolAssets);
        }

        interestRate = irm.computeInterestRate(address(this), address(asset), utilisation);
    }
}
