// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

import "./INFT.sol";

interface ITreasury {
    function auctionEscrow(address currency) external returns (uint256);

    function claimableFunds(address account, address currency)
        external
        returns (uint256);

    function updateClaimableFunds(
        address account,
        address currency,
        uint256 newClaimableFunds
    ) external;

    function claimFunds(address tokenAddress) external;

    function claimSaleNfts(uint256 saleId) external;

    function proceedAuctionFunds(
        uint256 auctionId,
        uint256 fundsToPay,
        address nftAddress
    ) external;

    function transferERC721To(
        address nftAddress,
        address recipient,
        uint256 nftId
    ) external;

    function transferERC1155To(
        address nftAddress,
        address recipient,
        uint256 nftId,
        uint256 amount
    ) external;

    function updateAuctionEscrow(address currency, uint256 newEscrowAmount)
        external;
}
