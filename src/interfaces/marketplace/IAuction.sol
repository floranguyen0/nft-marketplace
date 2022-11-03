// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

interface IAuction {
    struct Auction {
        uint256 id; // id of auction
        address owner; // address of NFT owner
        address nftContract;
        uint256 nftId;
        uint256 startTime;
        uint256 endTime;
        uint256 reservePrice; // may need to be made private
        address currency; // use zero address or 0xeee for ETH
    }

    struct Bid {
        uint256 auctionId;
        address bidder;
        uint256 amount;
        uint256 timestamp;
    }

    event NewAuction(uint256 indexed auctionId, Auction newAuction);
    event AuctionCancelled(uint256 indexed auctionId);
    event BidPlaced(uint256 auctionId, uint256 amount);
    event ClaimNFT(
        uint256 auctionId,
        address winner,
        address recipient,
        uint256 amount
    );
    event BalanceUpdated(
        address indexed accountOf,
        address indexed tokenAddress,
        uint256 indexed newBalance
    );

    /// @notice Returns a struct with an auction's details
    /// @param auctionId the index of the auction being queried
    /// @return an "Auction" struct with the details of the auction requested
    function getAuctionDetails(uint256 auctionId)
        external
        view
        returns (Auction memory);

    /// @notice Returns the status of a particular auction
    /// @dev statuses are: PENDING, CANCELLED, ACTIVE, ENDED, ENDED & CLAIMED
    /// @param auctionId the index of the auction being queried
    /// @return a string of the auction's status
    function getAuctionStatus(uint256 auctionId)
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

    /// @notice Returns details of a specific bid
    /// @dev the amount of an outbid bid is reduced to zero
    /// @param auctionId the index of the auction the bid was places in
    /// @param bidder the address of the bidder
    /// @return a Bid struct with details of a specific bid
    function getBidDetails(uint256 auctionId, address bidder)
        external
        view
        returns (Bid memory);

    /// @notice Returns the address of the current highest bidder in a particular auction
    /// @param auctionId the index of the auction being queried
    /// @return the address of the highest bidder
    function getHighestBidder(uint256 auctionId)
        external
        view
        returns (address);

    /// @notice Creates a first-price auction for a ERC1155 NFT
    /// @dev NFT contract must be ERC2981-compliant and recognized by Registry
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param nftContract the address of the NFT contract
    /// @param id the id of the NFT on the NFT contract
    /// @param startTime uint256 timestamp when the auction should commence
    /// @param endTime uint256 timestamp when auction should end
    /// @param reservePrice minimum price for bids
    /// @param currency address of the token bids should be made in
    /// @return the index of the auction being created
    function createAuction(
        address nftContract,
        uint256 id,
        uint256 startTime,
        uint256 endTime,
        uint256 reservePrice,
        address currency
    ) external returns (uint256);

    /// @notice Allows bidding on a specifc auction
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param auctionId the index of the auction to bid on
    /// @param amountFromBalance the amount to bid from msg.sender's balance in this contract
    /// @param externalFunds the amount to bid from funds in msg.sender's personal balance
    /// @return a bool indicating success
    function bid(
        uint256 auctionId,
        uint256 amountFromBalance,
        uint256 externalFunds
    ) external payable returns (bool);

    /// @notice Allows the winner of the auction to claim their NFT
    /// @notice Alternatively, allows auctioner to reclaim on an unsuccessful auction
    /// @dev this function delivers the NFT and moves the bid to the auctioner's claimable balance
    ///   and also accounts for the system fee and royalties (if applicable)
    /// @param auctionId the index of the auction to bid on
    /// @param recipient the address the NFT should be sent to
    /// @return a bool indicating success
    function claimNft(uint256 auctionId, address recipient)
        external
        returns (bool);

    /// @notice Withdraws in-contract balance of a particular token
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param tokenContract the address of the token to claim
    function claimFunds(address tokenContract) external;

    /// @notice Allows contract owner to send NFT to auction winner and funds to auctioner's balance
    /// @dev prevents assets from being stuck if winner does not claim
    /// @param auctionId the index of the auction to resolve
    function resolveAuction(uint256 auctionId) external;

    /// @notice Allows contract owner or auctioner to cancel a pending or active auction
    /// @param auctionId the index of the auction to cancel
    function cancelAuction(uint256 auctionId) external;

    /// @notice allows contract to receive ERC1155 NFTs
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes memory data
    ) external pure returns (bytes4);
}
