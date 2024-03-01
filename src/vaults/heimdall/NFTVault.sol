// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.19;

import "solmate/auth/Owned.sol";
import "solmate/tokens/ERC4626.sol";
import "solmate/tokens/ERC721.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/FixedPointMathLib.sol";
import "../VaultBase.sol";

/// @title NFTVault
/// @dev ERC721 contract is used as a collateral for the vault.
/// @notice This is for test purposes only, do not use in production.
contract NFTVault is VaultBase, Owned {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed caller, address indexed owner, uint256 id);
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 id
    );
    event SupplyCapSet(uint256 newSupplyCap);

    error SnapshotNotTaken();
    error SupplyCapExceeded();

    uint256 public supplyCap;
    uint256 public totalSupply;
    ERC721 public immutable asset;

    constructor(
        IEVC _evc,
        ERC721 _asset
    ) VaultBase(_evc) Owned(msg.sender) {
        asset = _asset;
    }

    /// @notice Sets the supply cap of the vault (amount of NFTs that someone can deposit into the vault).
    /// @param newSupplyCap The new supply cap.
    function setSupplyCap(uint256 newSupplyCap) external onlyOwner {
        supplyCap = newSupplyCap;
        emit SupplyCapSet(newSupplyCap);
    }

    /// @notice Creates a snapshot of the vault.
    /// @dev This function is called before any action that may affect the vault's state.
    /// @return A snapshot of the vault's state.
    function doCreateVaultSnapshot() internal virtual override returns (bytes memory) {
        // make total supply snapshot here and return it:
        return totalSupply;
    }

    /// @notice Checks the vault's status.
    /// @dev This function is called after any action that may affect the vault's state.
    /// @param oldSnapshot The snapshot of the vault's state before the action.
    function doCheckVaultStatus(bytes memory oldSnapshot) internal virtual override {
        // sanity check in case the snapshot hasn't been taken
        if (oldSnapshot.length == 0) revert SnapshotNotTaken();

        // validate the vault state here:
        uint256 initialSupply = abi.decode(oldSnapshot, (uint256));
        uint256 finalSupply = totalSupply;

        if (supplyCap != 0 && finalSupply > supplyCap && finalSupply > initialSupply) {
            revert SupplyCapExceeded();
        }
    }

    /// @notice Checks the status of an account.
    /// @dev This function is called after any action that may affect the account's state.
    function doCheckAccountStatus(address, address[] calldata) internal view virtual override {
        // no need to do anything here because the vault does not allow borrowing
    }

    /// @notice Disables the controller.
    /// @dev The controller is only disabled if the account has no debt.
    function disableController() external virtual override nonReentrant {
        // this vault doesn't allow borrowing, so we can't check that the account has no debt.
        // this vault should never be a controller, but user errors can happen
        EVCClient.disableController(_msgSender());
    }

    /// @notice Approves a spender to spend a certain amount.
    /// @param spender The spender to approve.
    /// @param amount The amount to approve.
    /// @return A boolean indicating whether the approval was successful.
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address msgSender = _msgSender();

        address owner = _ownerOf[id];

        require(msgSender == owner || isApprovedForAll[owner][msgSender], "NOT_AUTHORIZED");

        getApproved[id] = spender;

        emit Approval(owner, spender, id);
    }

    /// @notice Transfers an NFT with certain ID to recipient.
    /// @param from Owner of the NFT with certain ID, or authorized third party
    /// @param to The recipient of the transfer.
    /// @param amount The amount shares to transfer.
    /// @return A boolean indicating whether the transfer was successful.
    function transferFrom(address from, address to, uint256 id) public virtual override callThroughEVC nonReentrant returns (bool) {
        address msgSender = _msgSender();

        createVaultSnapshot();

        require(from == _ownerOf[id], "WRONG_FROM");

        require(to != address(0), "INVALID_RECIPIENT");

        require(
            msgSender == from || isApprovedForAll[from][msgSender] || msgSender == getApproved[id],
            "NOT_AUTHORIZED"
        );

        // Underflow of the sender's balance is impossible because we check for
        // ownership above and the recipient's balance can't realistically overflow.
        unchecked {
            _balanceOf[from]--;

            _balanceOf[to]++;
        }

        _ownerOf[id] = to;

        delete getApproved[id];

        emit Transfer(from, to, id);

        // despite the fact that the vault status check might not be needed for shares transfer with current logic, it's
        // added here so that if anyone changes the snapshot/vault status check mechanisms in the inheriting contracts,
        // they will not forget to add the vault status check here
        requireAccountAndVaultStatusCheck(msgSender);

        return true;
    }

    /// @notice Deposits an NFT with the certain id to the receiver.
    /// @param id The id of NFT.
    /// @param receiver The receiver of the NFT.
    function deposit(
        uint256 id,
        address receiver
    ) public virtual override callThroughEVC nonReentrant {
        address msgSender = _msgSender();

        createVaultSnapshot();

        // Need to transfer before minting or ERC777s could reenter.
        asset.safeTransferFrom(msgSender, address(this), id);

        //increase the total amount of deposited NFTs
        totalSupply++;

        emit Deposit(msgSender, receiver, id);

        requireVaultStatusCheck();
    }

    /// @notice Withdraws an NFT with certain id.
    /// @param id The id of NFT.
    /// @param receiver The receiver of the withdrawal.
    /// @param owner The owner of the assets.
    function withdraw(
        uint256 id,
        address receiver,
        address owner
    ) public virtual override callThroughEVC nonReentrant {
        address msgSender = _msgSender();

        createVaultSnapshot();

        asset.safeTransferFrom(msgSender, receiver, id);

        totalSupply--;

        emit Withdraw(msgSender, receiver, owner, id);

        requireAccountAndVaultStatusCheck(owner);
    }   
}