// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

import "./INFT.sol";

interface IAuction {
    struct AuctionInfo {
        bool isERC721;
        uint256 id; // id of auction
        address owner; // address of NFT owner
        address nftAddress;
        uint256 nftId;
        uint256 startTime;
        uint256 endTime;
        uint256 reservePrice; // may need to be made private
        address currency; // use zero address or 0xeee for ETH
    }

    function auctionInfo(uint256 auctionId)
        external
        returns (AuctionInfo calldata);
}
