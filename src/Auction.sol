// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/INFT.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ITreasury.sol";

/// @title Marketplace
/// @author Linum Labs
/// @notice Allows auctioning of ERC721, ERC1155 NFTs in a first-price auction
contract Auction is Ownable {
    using SafeERC20 for IERC20;

    // address alias for using ETH as a currency
    address constant ETH = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);

    uint256 public auctionIdCounter; // _autionId starts from 1
    IRegistry immutable registry;
    ITreasury immutable treasury;

    event NewAuction(uint256 indexed auctionId, AuctionInfo newAuction);
    event AuctionCancelled(uint256 indexed auctionId);
    event BidPlaced(uint256 auctionId, uint256 amount);
    event ClaimAuctionNFT(
        uint256 indexed auctionId,
        address indexed claimer,
        address indexed recipient,
        uint256 amount
    );

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

    struct Bid {
        uint256 amount;
        uint256 timestamp;
    }

    mapping(uint256 => AuctionInfo) public auctionInfo;
    mapping(uint256 => bool) public cancelledAuction;
    mapping(uint256 => bool) public claimed;
    mapping(uint256 => address) public highestBidder;
    // auctionId => bidderAddress => Bid
    mapping(uint256 => mapping(address => Bid)) public bids;

    constructor(address registryAddress, address treasuryAddress) {
        registry = IRegistry(registryAddress);
        treasury = ITreasury(treasuryAddress);
    }

    /// @notice Creates a first-price auction for ERC721 & ERC1155 NFT
    /// @param startTime uint256 timestamp when the auction should commence
    /// @param endTime uint256 timestamp when auction should end
    /// @param reservePrice minimum price for bids
    /// @param currency address of the token bids should be made in
    function createAuction(
        bool isERC721,
        address nftAddress,
        uint256 nftId,
        uint256 startTime,
        uint256 endTime,
        uint256 reservePrice,
        address currency
    ) external returns (uint256) {
        _beforeAuction(nftAddress, startTime, endTime, currency);
        INFT nftContract = INFT(nftAddress);

        // transfer the nft to the platform
        if (isERC721) {
            nftContract.safeTransferFrom(
                msg.sender,
                address(treasury),
                nftId,
                ""
            );
        } else {
            nftContract.safeTransferFrom(
                msg.sender,
                address(treasury),
                nftId,
                1,
                ""
            );
        }

        // save auction info
        unchecked {
            auctionIdCounter += 1;
        }
        uint256 auctionId = auctionIdCounter;

        auctionInfo[auctionId] = AuctionInfo({
            isERC721: isERC721,
            id: auctionId,
            owner: msg.sender,
            nftAddress: nftAddress,
            nftId: nftId,
            startTime: startTime,
            endTime: endTime,
            reservePrice: reservePrice,
            currency: currency
        });

        emit NewAuction(auctionId, auctionInfo[auctionId]);
        return auctionId;
    }

    /// @notice Allows bidding on a specifc auction
    /// @param amountFromBalance the amount to bid from msg.sender's balance in this contract
    /// @param externalFunds the amount to bid from funds in msg.sender's personal balance
    function bid(
        uint256 auctionId,
        uint256 amountFromBalance,
        uint256 externalFunds
    ) external payable {
        require(
            registry.platformContracts(address(this)) == true,
            "This contract is deprecated"
        );
        require(
            getAuctionStatus(auctionId) == "ACTIVE",
            "Auction is not active"
        );
        uint256 totalAmount = amountFromBalance +
            externalFunds +
            // this allows the top bidder to top off their bid
            bids[auctionId][msg.sender].amount;
        require(
            totalAmount > bids[auctionId][highestBidder[auctionId]].amount,
            "Bid is not high enough"
        );
        require(
            totalAmount >= auctionInfo[auctionId].reservePrice,
            "Bid is lower than the reserve price"
        );
        address currency = auctionInfo[auctionId].currency;
        uint256 claimableFunds = treasury.claimableFunds(msg.sender, currency);
        require(amountFromBalance <= claimableFunds, "Not enough balance");

        if (currency != ETH) {
            IERC20 token = IERC20(currency);
            token.safeTransferFrom(
                msg.sender,
                address(treasury),
                externalFunds
            );
        } else {
            require(msg.value == externalFunds, "Mismatch of value and args");
        }

        // next highest bid can be made claimable now,
        // also helps for figuring out how much more net is in escrow
        address lastHighestBidder = highestBidder[auctionId];
        uint256 lastHighestAmount = bids[auctionId][lastHighestBidder].amount;
        uint256 escrowAmount = treasury.auctionEscrow(currency);
        treasury.updateAuctionEscrow(
            currency,
            escrowAmount + totalAmount - lastHighestAmount
        );

        // last bidder can claim their fund now
        if (lastHighestBidder != msg.sender) {
            delete bids[auctionId][lastHighestBidder].amount;
            treasury.updateClaimableFunds(
                lastHighestBidder,
                currency,
                claimableFunds + lastHighestAmount
            );
        }
        if (amountFromBalance > 0) {
            treasury.updateClaimableFunds(
                msg.sender,
                currency,
                claimableFunds - amountFromBalance
            );
        }
        bids[auctionId][msg.sender].amount = totalAmount;
        bids[auctionId][msg.sender].timestamp = block.timestamp;
        highestBidder[auctionId] = msg.sender;

        emit BidPlaced(auctionId, totalAmount);
    }

    /// @notice Send NFT to auction winner and funds to auctioner's balance
    /// @notice Alternatively, allows auctioner to reclaim on an unsuccessful auction
    /// @dev this function delivers the NFT and moves the bid to the auctioner's claimable balance
    ///   and also accounts for the system fee and royalties (if applicable)
    function resolveAuction(uint256 auctionId) external {
        bytes32 status = getAuctionStatus(auctionId);
        require(
            status == "CANCELLED" || status == "ENDED",
            "Can only resolve after the auction ends or is cancelled"
        );

        AuctionInfo memory auctionInfo_ = auctionInfo[auctionId];
        address highestBidder_ = highestBidder[auctionId];
        uint256 winningBid = bids[auctionId][highestBidder_].amount;
        uint256 totalFundsToPay = msg.sender == auctionInfo_.owner
            ? 0
            : winningBid;

        // accounting logic
        address recipient;
        if (totalFundsToPay > 0) {
            treasury.proceedAuctionFunds(
                auctionId,
                winningBid,
                auctionInfo_.nftAddress
            );
            recipient = highestBidder_;
        } else {
            recipient = auctionInfo_.owner;
        }
        if (auctionInfo_.isERC721) {
            treasury.transferERC721To(
                auctionInfo_.nftAddress,
                recipient,
                auctionInfo_.nftId
            );
        } else {
            treasury.transferERC1155To(
                auctionInfo_.nftAddress,
                recipient,
                auctionInfo_.nftId,
                1
            );
        }
        claimed[auctionId] = true;

        emit ClaimAuctionNFT(
            auctionInfo_.id,
            msg.sender,
            recipient,
            bids[auctionId][highestBidder_].amount
        );
    }

    /// @notice Allows contract owner or auctioner to cancel a pending or active auction
    function cancelAuction(uint256 auctionId) external {
        require(
            msg.sender == auctionInfo[auctionId].owner || msg.sender == owner(),
            "Only owner or sale creator"
        );
        require(
            getAuctionStatus(auctionId) == "ACTIVE" ||
                getAuctionStatus(auctionId) == "PENDING",
            "Must be active or pending"
        );
        cancelledAuction[auctionId] = true;

        address currency = auctionInfo[auctionId].currency;
        address highestBidder_ = highestBidder[auctionId];
        uint256 highestBid = bids[auctionId][highestBidder_].amount;
        uint256 claimableFunds = treasury.claimableFunds(
            highestBidder_,
            currency
        );
        uint256 escrowAmount = treasury.auctionEscrow(currency);

        // current highest bid moves from escrow to being reclaimable
        treasury.updateAuctionEscrow(currency, escrowAmount - highestBid);
        treasury.updateClaimableFunds(
            highestBidder_,
            currency,
            claimableFunds + highestBid
        );

        emit AuctionCancelled(auctionId);
    }

    function getAuctionStatus(uint256 auctionId) public view returns (bytes32) {
        require(
            auctionId <= auctionIdCounter && auctionId > 0,
            "Auction does not exist"
        );
        if (
            cancelledAuction[auctionId] ||
            !registry.platformContracts(address(this))
        ) return "CANCELLED";
        if (claimed[auctionId]) return "ENDED & CLAIMED";
        if (block.timestamp < auctionInfo[auctionId].startTime)
            return "PENDING";
        if (
            block.timestamp >= auctionInfo[auctionId].startTime &&
            block.timestamp < auctionInfo[auctionId].endTime
        ) return "ACTIVE";
        if (block.timestamp > auctionInfo[auctionId].endTime) return "ENDED";
        revert("error");
    }

    function _beforeAuction(
        address nftAddress,
        uint256 startTime,
        uint256 endTime,
        address currency
    ) private {
        require(
            registry.platformContracts(nftAddress),
            "NFT is not in approved contract"
        );
        require(
            registry.platformContracts(address(this)),
            "This contract is deprecated"
        );
        require(
            registry.approvedCurrencies(currency),
            "Currency is not supported"
        );
        require(
            INFT(nftAddress).supportsInterface(0x2a55205a),
            "Contract must support ERC2981"
        );
        require(endTime > startTime, "Error in start/end params");
    }
}
