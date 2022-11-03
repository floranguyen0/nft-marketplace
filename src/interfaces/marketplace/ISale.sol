// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

interface ISale {
    struct Sale {
        uint256 id; // id of sale
        address owner; // address of NFT owner
        address nftContract;
        uint256 nftId;
        uint256 amount; // amount of NFTs being sold
        uint256 purchased; // amount of NFTs purchased thus far
        uint256 startTime;
        uint256 endTime;
        uint256 price;
        uint256 maxBuyAmount;
        address currency; // use zero address or 0xaaa for ETH
    }

    event NewSale(uint256 indexed id, Sale newSale);
    event SaleCancelled(uint256 indexed saleId);
    event Purchase(
        uint256 saleId,
        address purchaser,
        address recipient,
        uint256 quantity
    );
    event NFTsReclaimed(
        uint256 indexed id,
        address indexed owner,
        uint256 indexed amount
    );
    event BalanceUpdated(
        address indexed accountOf,
        address indexed tokenAddress,
        uint256 indexed newBalance
    );

    /// @notice Returns a struct with an sale's details
    /// @param saleId the index of the sale being queried
    /// @return an "Sale" struct with the details of the sale requested
    function getSaleDetails(uint256 saleId) external view returns (Sale memory);

    /// @notice Returns the status of a particular sale
    /// @dev statuses are: PENDING, CANCELLED, ACTIVE, ENDED
    /// @param saleId the index of the sale being queried
    /// @return a string of the sale's status
    function getSaleStatus(uint256 saleId)
        external
        view
        returns (string memory);

    /// @notice Returns the in-contract balance of a specific address for a specific token
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param account the address to query the balance of
    /// @param token the address of the token to query the balance for
    /// @return the uint256 balance of the token queired for the address queried
    function getClaimableBalance(address account, address token)
        external
        view
        returns (uint256);

    /// @notice Creates a sale of ERC1155 NFTs
    /// @dev NFT contract must be ERC2981-compliant and recognized by Registry
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param nftContract the address of the NFT contract
    /// @param id the id of the NFTs on the NFT contract
    /// @param startTime uint256 timestamp when the sale should commence
    /// @param endTime uint256 timestamp when sale should end
    /// @param price the price for each NFT
    /// @param maxBuyAmount the maximum amount one address can purchase
    /// @param currency address of the token bids should be made in
    /// @return the index of the sale being created
    function createSale(
        address nftContract,
        uint256 id,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        uint256 price,
        uint256 maxBuyAmount,
        address currency
    ) external returns (uint256);

    /// @notice Allows purchase of NFTs from a sale
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @dev automatically calculates system fee and royalties (where applicable)
    /// @param saleId the index of the sale to purchase from
    /// @param amountToBuy the number of NFTs to purchase
    /// @param amountFromBalance the amount to spend from msg.sender's balance in this contract
    /// @return a bool indicating success
    function buy(
        uint256 saleId,
        address recipient,
        uint256 amountToBuy,
        uint256 amountFromBalance
    ) external payable returns (bool);

    /// @notice Allows seller to reclaim unsold NFTs
    /// @dev sale must be cancelled or ended
    /// @param saleId the index of the sale to claim from
    function claimNfts(uint256 saleId) external;

    /// @notice Withdraws in-contract balance of a particular token
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param tokenContract the address of the token to claim
    function claimFunds(address tokenContract) external;

    /// @notice Allows contract owner or seller to cancel a pending or active sale
    /// @param saleId the index of the sale to cancel
    function cancelSale(uint256 saleId) external;

    /// @notice allows contract to receive ERC1155 NFTs
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes memory data
    ) external pure returns (bytes4);
}
