// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

import "./INFT.sol";

interface ISale {
    struct SaleInfo {
        bool isERC721;
        address nftAddress;
        uint256 nftId;
        address owner;
        uint256 amount; // amount of NFTs being sold
        uint256 purchased; // amount of NFTs purchased thus far
        uint256 startTime;
        uint256 endTime;
        uint256 price;
        address currency;
    }

    function saleInfo(uint256 saleId) external returns (SaleInfo memory);

    function updateSalePurchased(uint256 saleId, uint256 newPurchased) external;

    function getSaleStatus(uint256 saleId) external returns (bytes32);
}
