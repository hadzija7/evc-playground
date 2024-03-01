// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.19;

import "openzeppelin/token/ERC721/ERC721.sol";
import "openzeppelin/utils/ReentrancyGuard.sol";
import "evc/utils/EVCUtil.sol";

/// @title ERC20Collateral
/// @notice It extends the ERC721 token standard to add the EVC authentication and account status checks so that the
/// token contract can be used as collateral in the EVC ecosystem.
abstract contract ERC721Collateral is EVCUtil, ERC721, ReentrancyGuard {
    constructor(IEVC _evc_, string memory _name_, string memory _symbol_) EVCUtil(_evc_) ERC721(_name_, _symbol_) {}

    /// @notice Transfers an NFT with specified id to the recipient.
    /// @dev Overriden to add re-entrancy protection.
    /// @param from The sender of the transfer.
    /// @param to The recipient of the transfer.
    /// @param id The id of NFT to transfer.
    function transferFrom(
        address from,
        address to,
        uint256 id
    ) public virtual override nonReentrant {
        super.transferFrom(from, to, id);
    }

    /// @notice Transfers an nft with specified id to the `to`address.
    /// @dev Overriden to require account status checks on transfers from non-zero addresses. The account status check
    /// must be required on any operation that reduces user's balance. Note that the user balance cannot be modified
    /// after the account status check is required. If that's the case, the contract must be modified so that the
    /// account status check is required as the very last operation of the function.
    /// @param to The address to which tokens are transferred or minted.
    /// @param id The id of NFT to be transferred.
    function _update(address to, uint256 id, address auth) internal virtual override returns (address a) {
        a = super._update(to, id, auth);

        if (auth != address(0)) {
            evc.requireAccountStatusCheck(auth);
        }
    }

    /// @notice Retrieves the message sender in the context of the EVC.
    /// @dev Overriden due to the conflict with the Context definition.
    /// @dev This function returns the account on behalf of which the current operation is being performed, which is
    /// either msg.sender or the account authenticated by the EVC.
    /// @return The address of the message sender.
    function _msgSender() internal view virtual override (EVCUtil, Context) returns (address) {
        return EVCUtil._msgSender();
    }
}
