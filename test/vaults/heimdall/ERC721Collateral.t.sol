// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import "evc/EthereumVaultConnector.sol";
import "../../../src/vaults/open-zeppelin/VaultRegularBorrowable.sol";
import "../../../src/vaults/heimdall/NFTVault.sol";
import "../../../src/ERC20/ERC20Collateral.sol";
import "../../../src/vaults/heimdall/ERC721Collateral.sol";
import {IRMMock} from "../../mocks/IRMMock.sol";
import {PriceOracleMock} from "../../mocks/PriceOracleMock.sol";
import "forge-std/console.sol";

// ERC721Collateral is abstract hence we need to create a contract that inherits from it
contract MockERC721Collateral is ERC721Collateral {
    constructor(
        IEVC _evc,
        string memory _name_,
        string memory _symbol_
    ) ERC721Collateral(_evc, _name_, _symbol_) {}

    function mint(address account, uint256 id) public {
        _mint(account, id);
    }
}

contract ERC721CollateralTest is Test {
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    IEVC evc;
    MockERC20 referenceAsset;
    MockERC20 liabilityAsset;
    MockERC20 collateralAsset1;
    MockERC721Collateral collateralAsset2;
    IRMMock irm;
    PriceOracleMock oracle;

    VaultRegularBorrowable liabilityVault;
    VaultSimple collateralVault1;

    function setUp() public {
        evc = new EthereumVaultConnector();
        referenceAsset = new MockERC20("Reference Asset", "RA", 18);
        liabilityAsset = new MockERC20("Liability Asset", "LA", 18);
        collateralAsset1 = new MockERC20("Collateral Asset 1", "CA1", 18);
        collateralAsset2 = new MockERC721Collateral(evc, "Collateral Asset 2", "CA2");
        irm = new IRMMock();
        oracle = new PriceOracleMock();

        liabilityVault = new VaultRegularBorrowable(
            evc, IERC20(address(liabilityAsset)), irm, oracle, ERC20(address(referenceAsset)), "Liability Vault", "LV"
        );

        collateralVault1 = new VaultSimple(evc, IERC20(address(collateralAsset1)), "Collateral Vault 1", "CV1");

        collateralVault2 = new NFTVault(evc, IERC721(address(collateralAsset2)), "Collateral Vault 2", "CV2");

        irm.setInterestRate(10); // 10% APY

        oracle.setResolvedAsset(address(liabilityVault));
        oracle.setResolvedAsset(address(collateralVault1));
        oracle.setPrice(address(liabilityAsset), address(referenceAsset), 1e17); // 1 LA = 0.1 RA
        oracle.setPrice(address(collateralAsset1), address(referenceAsset), 1e16); // 1 CA1 = 0.01 RA
        oracle.setPrice(address(collateralAsset2), address(referenceAsset), 50e18); // 1 CA2 = 0.1 RA
    }

    function mintAndApprove(address alice, address bob) public {
        liabilityAsset.mint(alice, 100e18);
        collateralAsset1.mint(bob, 100e18);
        collateralAsset2.mint(bob, 1);
        assertEq(liabilityAsset.balanceOf(alice), 100e18);
        assertEq(collateralAsset1.balanceOf(bob), 100e18);
        assertEq(collateralAsset2.balanceOf(bob), 1);
        console.log(collateralAsset2.balanceOf(bob));

        vm.prank(alice);
        liabilityAsset.approve(address(liabilityVault), type(uint256).max);

        vm.prank(bob);
        collateralAsset1.approve(address(collateralVault1), type(uint256).max);
    }

    function test_RegularBorrowRepay(address alice, address bob) public {
        vm.assume(alice != address(0) && bob != address(0) && !evc.haveCommonOwner(alice, bob));
        vm.assume(
            alice != address(evc) && alice != address(liabilityVault) && alice != address(collateralVault1)
                && alice != address(collateralAsset2)
        );
        vm.assume(
            bob != address(evc) && bob != address(liabilityVault) && bob != address(collateralVault1)
                && bob != address(collateralAsset2)
        );

        mintAndApprove(alice, bob);

        // liabilityVault.setCollateralFactor(address(liabilityVault), 100); // cf = 1, self-collateralization
        // liabilityVault.setCollateralFactor(address(collateralVault1), 100); // cf = 1
        // liabilityVault.setCollateralFactor(address(collateralAsset2), 50); // cf = 0.5

        // // alice deposits 50 LA
        // vm.prank(alice);
        // liabilityVault.deposit(50e18, alice);
        // assertEq(liabilityAsset.balanceOf(alice), 50e18);
        // assertEq(liabilityVault.maxWithdraw(alice), 50e18);

        // // bob deposits 100 CA1 which lets him borrow 10 LA
        // vm.prank(bob);
        // collateralVault1.deposit(100e18, bob);
        // assertEq(collateralAsset1.balanceOf(bob), 0);
        // assertEq(collateralVault1.maxWithdraw(bob), 100e18);

        // // bob transfers some CA2 to alice and after that he holds 50 CA2 which which lets him borrow 25 LA
        // vm.prank(bob);
        // collateralAsset2.transfer(alice, 50e6);
        // assertEq(collateralAsset2.balanceOf(alice), 50e6);
        // assertEq(collateralAsset2.balanceOf(bob), 50e6);

        // // controller and collateral not enabled, hence borrow unsuccessful
        // vm.prank(bob);
        // vm.expectRevert(abi.encodeWithSelector(EVCUtil.ControllerDisabled.selector));
        // liabilityVault.borrow(35e18, bob);

        // vm.prank(bob);
        // evc.enableController(bob, address(liabilityVault));

        // // collateral still not enabled, hence borrow unsuccessful
        // vm.prank(bob);
        // vm.expectRevert(abi.encodeWithSelector(VaultRegularBorrowable.AccountUnhealthy.selector));
        // liabilityVault.borrow(35e18, bob);

        // vm.prank(bob);
        // evc.enableCollateral(bob, address(collateralVault1));

        // // too much borrowed because only one collateral enabled, hence borrow unsuccessful
        // vm.prank(bob);
        // vm.expectRevert(abi.encodeWithSelector(VaultRegularBorrowable.AccountUnhealthy.selector));
        // liabilityVault.borrow(35e18, bob);

        // vm.prank(bob);
        // evc.enableCollateral(bob, address(collateralAsset2));

        // // too much borrowed, hence borrow unsuccessful
        // vm.prank(bob);
        // vm.expectRevert(abi.encodeWithSelector(VaultRegularBorrowable.AccountUnhealthy.selector));
        // liabilityVault.borrow(35e18 + 0.01e18, bob);

        // // finally borrow is successful
        // vm.prank(bob);
        // liabilityVault.borrow(35e18, bob);
        // assertEq(liabilityAsset.balanceOf(bob), 35e18);
        // assertEq(liabilityVault.debtOf(bob), 35e18);
        // assertEq(liabilityVault.maxWithdraw(alice), 15e18);

        // // jump one year ahead, bob's liability increased by 10% APY.
        // // his account is no longer healthy
        // vm.warp(block.timestamp + 365 days);
        // assertEq(liabilityAsset.balanceOf(bob), 35e18);
        // assertEq(liabilityVault.debtOf(bob), 35e18 + 3.680982126514837395e18);
        // assertEq(liabilityVault.maxWithdraw(alice), 15e18);
        // vm.expectRevert(abi.encodeWithSelector(VaultRegularBorrowable.AccountUnhealthy.selector));
        // evc.requireAccountStatusCheck(bob);

        // // bob repays only some of his debt, his account is still unhealthy
        // vm.prank(bob);
        // liabilityAsset.approve(address(liabilityVault), type(uint256).max);

        // vm.prank(bob);
        // liabilityVault.repay(2.680982126514837395e18, bob);
        // assertEq(liabilityAsset.balanceOf(bob), 35e18 - 2.680982126514837395e18);
        // assertEq(liabilityVault.debtOf(bob), 35e18 + 1e18);
        // assertEq(liabilityVault.maxWithdraw(alice), 15e18 + 2.680982126514837395e18);
        // vm.expectRevert(abi.encodeWithSelector(VaultRegularBorrowable.AccountUnhealthy.selector));
        // evc.requireAccountStatusCheck(bob);

        // // alice kicks in to liquidate bob. first enable controller and collaterals
        // vm.prank(alice);
        // evc.enableController(alice, address(liabilityVault));

        // vm.prank(alice);
        // evc.enableCollateral(alice, address(liabilityVault));

        // vm.prank(alice);
        // evc.enableCollateral(alice, address(collateralVault1));

        // vm.prank(alice);
        // evc.enableCollateral(alice, address(collateralAsset2));

        // // liquidation fails multiple times as alice tries to liquidate too much
        // vm.prank(alice);
        // vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, bob, 100e18, 309e18));
        // liabilityVault.liquidate(bob, address(collateralVault1), 30e18);

        // vm.prank(alice);
        // vm.expectRevert(VaultRegularBorrowable.RepayAssetsExceeded.selector);
        // liabilityVault.liquidate(bob, address(collateralAsset2), 30e18);

        // // finally liquidation is successful
        // vm.prank(alice);
        // liabilityVault.liquidate(bob, address(collateralAsset2), 6e18);

        // assertEq(liabilityAsset.balanceOf(bob), 35e18 - 2.680982126514837395e18); // bob's LA balance stays unchanged
        // assertEq(liabilityVault.debtOf(bob), 30e18); // bob's debt decreased by 6 LA due to liquidation
        // assertEq(collateralVault1.maxWithdraw(bob), 100e18); // bob's CA1 deposit stays unchanged
        // assertEq(collateralAsset2.balanceOf(bob), 50e6 - 6.18e6); // bob's CA2 balance decreased by 6.18 CA2 due
        //     // to liquidation
        // assertEq(liabilityVault.debtOf(alice), 6e18); // alices's debt increased to 6 LA due to liquidation (she took on
        //     // bob's debt)
        // assertEq(liabilityVault.maxWithdraw(alice), 15e18 + 2.680982126514837395e18); // alice's ability to withdraw LA
        //     // didn't change
        // assertEq(collateralVault1.maxWithdraw(alice), 0); // alices's CA1 deposit stays unchanged
        // assertEq(collateralAsset2.balanceOf(alice), 50e6 + 6.18e6); // alices's CA2 balance increased by 6.18 CA2 due
        //     // to liquidation (she took on bob's collateral)
        // evc.requireAccountStatusCheck(alice);
        // evc.requireAccountStatusCheck(bob);

        // // alice repays her debt taken on from bob
        // vm.prank(alice);
        // liabilityVault.repay(6e18, alice);
        // assertEq(liabilityAsset.balanceOf(alice), 50e18 - 6e18);
        // assertEq(liabilityVault.debtOf(alice), 0);

        // // she disables collaterals and controller
        // vm.prank(alice);
        // liabilityVault.disableController();

        // vm.prank(alice);
        // evc.disableCollateral(alice, address(liabilityVault));

        // vm.prank(alice);
        // evc.disableCollateral(alice, address(collateralVault1));

        // vm.prank(alice);
        // evc.disableCollateral(alice, address(collateralAsset2));

        // // bob repays the rest of his debt
        // vm.prank(bob);
        // liabilityVault.repay(30e18, bob);
        // assertEq(liabilityAsset.balanceOf(bob), 35e18 - 2.680982126514837395e18 - 30e18);
        // assertEq(liabilityVault.debtOf(bob), 0);

        // // he disables collaterals and controller
        // vm.prank(bob);
        // liabilityVault.disableController();

        // vm.prank(bob);
        // evc.disableCollateral(bob, address(collateralVault1));

        // vm.prank(bob);
        // evc.disableCollateral(bob, address(collateralAsset2));

        // // finally, bob withdraws his collateral
        // vm.prank(bob);
        // collateralVault1.withdraw(100e18, bob, bob);
        // assertEq(collateralAsset1.balanceOf(bob), 100e18);
        // assertEq(collateralVault1.maxWithdraw(bob), 0);

        // // alice withdraws her LA deposit, account for rounding
        // vm.prank(alice);
        // liabilityVault.withdraw(50e18 - 35e18 + 2.680982126514837395e18 + 6e18 + 30e18 - 1, alice, alice);
        // assertEq(liabilityAsset.balanceOf(alice), 100e18 - 35e18 + 2.680982126514837395e18 + 30e18 - 1);
        // assertEq(liabilityVault.maxWithdraw(alice), 0);

        // // final checks
        // assertEq(liabilityAsset.balanceOf(address(liabilityVault)), 1);
        // assertEq(liabilityAsset.balanceOf(address(alice)), 100e18 - 35e18 + 2.680982126514837395e18 + 30e18 - 1);
        // assertEq(liabilityAsset.balanceOf(address(bob)), 35e18 - 2.680982126514837395e18 - 30e18);
        // assertEq(liabilityVault.maxWithdraw(alice), 0);
        // assertEq(liabilityVault.maxWithdraw(bob), 0);
        // assertEq(liabilityVault.debtOf(alice), 0);
        // assertEq(liabilityVault.debtOf(bob), 0);

        // assertEq(collateralAsset1.balanceOf(address(collateralVault1)), 0);
        // assertEq(collateralAsset1.balanceOf(address(alice)), 0);
        // assertEq(collateralAsset1.balanceOf(address(bob)), 100e18);
        // assertEq(collateralVault1.maxWithdraw(alice), 0);
        // assertEq(collateralVault1.maxWithdraw(bob), 0);

        // assertEq(collateralAsset2.totalSupply(), 100e6);
        // assertEq(collateralAsset2.balanceOf(address(alice)), 50e6 + 6.18e6);
        // assertEq(collateralAsset2.balanceOf(address(bob)), 50e6 - 6.18e6);
    }

    // function test_RegularBorrowRepayWithBatch(address alice, address bob) public {
    //     vm.assume(alice != address(0) && bob != address(0) && !evc.haveCommonOwner(alice, bob));
    //     vm.assume(
    //         alice != address(evc) && alice != address(liabilityVault) && alice != address(collateralVault1)
    //             && alice != address(collateralAsset2)
    //     );
    //     vm.assume(
    //         bob != address(evc) && bob != address(liabilityVault) && bob != address(collateralVault1)
    //             && bob != address(collateralAsset2)
    //     );

    //     mintAndApprove(alice, bob);

    //     liabilityVault.setCollateralFactor(address(liabilityVault), 100); // cf = 1, self-collateralization
    //     liabilityVault.setCollateralFactor(address(collateralVault1), 100); // cf = 1
    //     liabilityVault.setCollateralFactor(address(collateralAsset2), 50); // cf = 0.5

    //     // alice deposits 50 LA
    //     vm.prank(alice);
    //     liabilityVault.deposit(50e18, alice);
    //     assertEq(liabilityAsset.balanceOf(alice), 50e18);
    //     assertEq(liabilityVault.maxWithdraw(alice), 50e18);

    //     // bob deposits collateral, enables collaterals, transfers some CA2 to alice, enables controller and borrows
    //     IEVC.BatchItem[] memory items = new IEVC.BatchItem[](6);
    //     items[0] = IEVC.BatchItem({
    //         targetContract: address(collateralVault1),
    //         onBehalfOfAccount: bob,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultSimple.deposit.selector, 100e18, bob)
    //     });
    //     items[1] = IEVC.BatchItem({
    //         targetContract: address(collateralAsset2),
    //         onBehalfOfAccount: bob,
    //         value: 0,
    //         data: abi.encodeWithSelector(ERC20.transfer.selector, alice, 50e6)
    //     });
    //     items[2] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.enableController.selector, bob, address(liabilityVault))
    //     });
    //     items[3] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.enableCollateral.selector, bob, address(collateralVault1))
    //     });
    //     items[4] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.enableCollateral.selector, bob, address(collateralAsset2))
    //     });
    //     items[5] = IEVC.BatchItem({
    //         targetContract: address(liabilityVault),
    //         onBehalfOfAccount: bob,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultRegularBorrowable.borrow.selector, 35e18 + 0.01e18, bob)
    //     });

    //     // it will revert because of the borrow amount being to high
    //     vm.prank(bob);
    //     vm.expectRevert(abi.encodeWithSelector(VaultRegularBorrowable.AccountUnhealthy.selector));
    //     evc.batch(items);

    //     items[5] = IEVC.BatchItem({
    //         targetContract: address(liabilityVault),
    //         onBehalfOfAccount: bob,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultRegularBorrowable.borrow.selector, 35e18, bob)
    //     });

    //     // now it will succeed
    //     vm.prank(bob);
    //     evc.batch(items);

    //     assertEq(liabilityAsset.balanceOf(address(liabilityVault)), 15e18);
    //     assertEq(liabilityAsset.balanceOf(address(alice)), 50e18);
    //     assertEq(liabilityAsset.balanceOf(address(bob)), 35e18);
    //     assertEq(liabilityVault.maxWithdraw(alice), 15e18);
    //     assertEq(liabilityVault.maxWithdraw(bob), 0);
    //     assertEq(liabilityVault.debtOf(alice), 0);
    //     assertEq(liabilityVault.debtOf(bob), 35e18);

    //     assertEq(collateralAsset1.balanceOf(address(collateralVault1)), 100e18);
    //     assertEq(collateralAsset1.balanceOf(address(alice)), 0);
    //     assertEq(collateralAsset1.balanceOf(address(bob)), 0);
    //     assertEq(collateralVault1.maxWithdraw(alice), 0);
    //     assertEq(collateralVault1.maxWithdraw(bob), 100e18);

    //     assertEq(collateralAsset2.totalSupply(), 100e6);
    //     assertEq(collateralAsset2.balanceOf(address(alice)), 50e6);
    //     assertEq(collateralAsset2.balanceOf(address(bob)), 50e6);

    //     // jump one year ahead, bob's liability increased by 10% APY.
    //     // his account is no longer healthy
    //     vm.warp(block.timestamp + 365 days);
    //     assertEq(liabilityAsset.balanceOf(bob), 35e18);
    //     assertEq(liabilityVault.debtOf(bob), 35e18 + 3.680982126514837395e18);
    //     assertEq(liabilityVault.maxWithdraw(alice), 15e18);
    //     vm.expectRevert(abi.encodeWithSelector(VaultRegularBorrowable.AccountUnhealthy.selector));
    //     evc.requireAccountStatusCheck(bob);

    //     // bob repays only some of his debt, his account is still unhealthy
    //     vm.prank(bob);
    //     liabilityAsset.approve(address(liabilityVault), type(uint256).max);

    //     vm.prank(bob);
    //     liabilityVault.repay(2.680982126514837395e18, bob);
    //     assertEq(liabilityAsset.balanceOf(bob), 35e18 - 2.680982126514837395e18);
    //     assertEq(liabilityVault.debtOf(bob), 35e18 + 1e18);
    //     assertEq(liabilityVault.maxWithdraw(alice), 15e18 + 2.680982126514837395e18);
    //     vm.expectRevert(abi.encodeWithSelector(VaultRegularBorrowable.AccountUnhealthy.selector));
    //     evc.requireAccountStatusCheck(bob);

    //     // alice kicks in to liquidate bob, repay the debt and withdraw seized collateral
    //     items = new IEVC.BatchItem[](10);
    //     items[0] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.enableController.selector, alice, address(liabilityVault))
    //     });
    //     items[1] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.enableCollateral.selector, alice, address(liabilityVault))
    //     });
    //     items[2] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.enableCollateral.selector, alice, address(collateralVault1))
    //     });
    //     items[3] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.enableCollateral.selector, alice, address(collateralAsset2))
    //     });
    //     items[4] = IEVC.BatchItem({
    //         targetContract: address(liabilityVault),
    //         onBehalfOfAccount: alice,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultRegularBorrowable.liquidate.selector, bob, address(collateralAsset2), 6e18)
    //     });
    //     items[5] = IEVC.BatchItem({
    //         targetContract: address(liabilityVault),
    //         onBehalfOfAccount: alice,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultRegularBorrowable.repay.selector, 6e18, alice)
    //     });
    //     items[6] = IEVC.BatchItem({
    //         targetContract: address(liabilityVault),
    //         onBehalfOfAccount: alice,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultRegularBorrowable.disableController.selector)
    //     });
    //     items[7] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.disableCollateral.selector, alice, address(liabilityVault))
    //     });
    //     items[8] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.disableCollateral.selector, alice, address(collateralVault1))
    //     });
    //     items[9] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.disableCollateral.selector, alice, address(collateralAsset2))
    //     });

    //     vm.prank(alice);
    //     evc.batch(items);

    //     assertEq(liabilityAsset.balanceOf(address(liabilityVault)), 50e18 - 35e18 + 2.680982126514837395e18 + 6e18);
    //     assertEq(liabilityAsset.balanceOf(address(alice)), 50e18 - 6e18);
    //     assertEq(liabilityAsset.balanceOf(address(bob)), 35e18 - 2.680982126514837395e18);
    //     assertEq(liabilityVault.maxWithdraw(alice), 50e18 - 35e18 + 2.680982126514837395e18 + 6e18);
    //     assertEq(liabilityVault.maxWithdraw(bob), 0);
    //     assertEq(liabilityVault.debtOf(alice), 0);
    //     assertEq(liabilityVault.debtOf(bob), 30e18);

    //     assertEq(collateralAsset1.balanceOf(address(collateralVault1)), 100e18);
    //     assertEq(collateralAsset1.balanceOf(address(alice)), 0);
    //     assertEq(collateralAsset1.balanceOf(address(bob)), 0);
    //     assertEq(collateralVault1.maxWithdraw(alice), 0);
    //     assertEq(collateralVault1.maxWithdraw(bob), 100e18);

    //     assertEq(collateralAsset2.totalSupply(), 100e6);
    //     assertEq(collateralAsset2.balanceOf(address(alice)), 50e6 + 6.18e6);
    //     assertEq(collateralAsset2.balanceOf(address(bob)), 50e6 - 6.18e6);

    //     // bob repays his debt and withdraws his collaterals
    //     items = new IEVC.BatchItem[](5);
    //     items[0] = IEVC.BatchItem({
    //         targetContract: address(liabilityVault),
    //         onBehalfOfAccount: bob,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultRegularBorrowable.repay.selector, 30e18, bob)
    //     });
    //     items[1] = IEVC.BatchItem({
    //         targetContract: address(liabilityVault),
    //         onBehalfOfAccount: bob,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultRegularBorrowable.disableController.selector)
    //     });
    //     items[2] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.disableCollateral.selector, bob, address(collateralVault1))
    //     });
    //     items[3] = IEVC.BatchItem({
    //         targetContract: address(evc),
    //         onBehalfOfAccount: address(0),
    //         value: 0,
    //         data: abi.encodeWithSelector(IEVC.disableCollateral.selector, bob, address(collateralAsset2))
    //     });
    //     items[4] = IEVC.BatchItem({
    //         targetContract: address(collateralVault1),
    //         onBehalfOfAccount: bob,
    //         value: 0,
    //         data: abi.encodeWithSelector(VaultSimple.withdraw.selector, 100e18, bob, bob)
    //     });

    //     vm.prank(bob);
    //     evc.batch(items);

    //     // alice withdraws her LA deposit
    //     vm.prank(alice);
    //     liabilityVault.withdraw(50e18 - 35e18 + 2.680982126514837395e18 + 6e18 + 30e18 - 1, alice, alice);

    //     // final checks
    //     assertEq(liabilityAsset.balanceOf(address(liabilityVault)), 1);
    //     assertEq(liabilityAsset.balanceOf(address(alice)), 100e18 - 35e18 + 2.680982126514837395e18 + 30e18 - 1);
    //     assertEq(liabilityAsset.balanceOf(address(bob)), 35e18 - 2.680982126514837395e18 - 30e18);
    //     assertEq(liabilityVault.maxWithdraw(alice), 0);
    //     assertEq(liabilityVault.maxWithdraw(bob), 0);
    //     assertEq(liabilityVault.debtOf(alice), 0);
    //     assertEq(liabilityVault.debtOf(bob), 0);

    //     assertEq(collateralAsset1.balanceOf(address(collateralVault1)), 0);
    //     assertEq(collateralAsset1.balanceOf(address(alice)), 0);
    //     assertEq(collateralAsset1.balanceOf(address(bob)), 100e18);
    //     assertEq(collateralVault1.maxWithdraw(alice), 0);
    //     assertEq(collateralVault1.maxWithdraw(bob), 0);

    //     assertEq(collateralAsset2.totalSupply(), 100e6);
    //     assertEq(collateralAsset2.balanceOf(address(alice)), 50e6 + 6.18e6);
    //     assertEq(collateralAsset2.balanceOf(address(bob)), 50e6 - 6.18e6);
    // }
}
