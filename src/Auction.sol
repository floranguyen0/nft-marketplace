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
    address private constant ETH =
        address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
    IRegistry private immutable _registry;
    ITreasury private immutable _treasury;

    uint128 public auctionIdCounter; // _autionId starts from 1

    event NewAuction(uint256 indexed auctionId, AuctionInfo newAuction);
    event AuctionCancelled(uint256 indexed auctionId);
    event BidPlaced(uint256 indexed auctionId, uint256 amount);
    event ClaimAuctionNFT(
        uint256 indexed auctionId,
        address indexed claimer,
        address indexed recipient,
        uint256 amount
    );
    event BalanceUpdated(
        address indexed accountOf,
        address indexed tokenAddress,
        uint256 indexed newBalance
    );

    error ContractIsDeprecated();
    error NotEnoughBalance();
    error AuctionIsNotActive();
    error BidIsNotHighEnough();
    error ArgumentsAndValueMismatch();
    error AuctionIsNotEndOrCancelled();
    error OnlyOwnerOrAuctionCreator();
    error AuctionMustBeActiveOrPending();
    error AuctionDoesNotExist();
    error NFTContractIsNotApproved();
    error CurrencyIsNotSupported();
    error ContractMustSupportERC2981();
    error EndTimeMustBeGreaterThanStartTime();

    struct AuctionInfo {
        uint128 id; // auctionId
        uint128 nftId;
        bool isERC721;
        address nftAddress;
        address owner; // NFT owner address
        address currency; // use zero address or 0xeee for ETH
        uint256 startTime;
        uint256 endTime;
        uint256 reservePrice; // may need to be made private
    }

    struct Bid {
        uint256 amount;
        uint256 timestamp;
    }

    mapping(uint256 => AuctionInfo) public auctionInfo; // auctionId => AuctionInfo
    mapping(uint256 => bool) public cancelledAuction; // auctionId => isCancelled
    mapping(uint256 => bool) public claimed; // auctionId => isClaimed
    mapping(uint256 => address) public highestBidder; // auctionId => highest bidder address
    // auctionId => bidderAddress => Bid
    mapping(uint256 => mapping(address => Bid)) public bids;

    constructor(address registryAddress, address treasuryAddress) {
        _registry = IRegistry(registryAddress);
        _treasury = ITreasury(treasuryAddress);
    }

    /// @notice Creates a first-price auction for a ERC1155 NFT
    /// @dev NFT contract must be ERC2981-compliant and recognized by Registry
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param nftAddress the address of the NFT contract
    /// @param nftId the id of the NFT on the NFT contract
    /// @param startTime uint256 timestamp when the auction should commence
    /// @param endTime uint256 timestamp when auction should end
    /// @param reservePrice minimum price for bids
    /// @param currency address of the token bids should be made in
    /// @return auctionId the index of the auction being created
    function createAuction(
        bool isERC721,
        address nftAddress,
        uint128 nftId,
        uint256 startTime,
        uint256 endTime,
        uint256 reservePrice,
        address currency
    ) external returns (uint256) {
        _beforeAuction(nftAddress, startTime, endTime, currency);
        INFT nftContract = INFT(nftAddress);

        // transfer the nft to the platform
        isERC721
            ? nftContract.safeTransferFrom(
                msg.sender,
                address(_treasury),
                nftId,
                ""
            )
            : nftContract.safeTransferFrom(
                msg.sender,
                address(_treasury),
                nftId,
                1,
                ""
            );

        // save auction info
        unchecked {
            ++auctionIdCounter;
        }
        uint128 auctionId = auctionIdCounter;

        auctionInfo[auctionId] = AuctionInfo({
            isERC721: isERC721,
            id: auctionId,
            owner: msg.sender,
            nftAddress: nftAddress,
            currency: currency,
            nftId: nftId,
            startTime: startTime,
            endTime: endTime,
            reservePrice: reservePrice
        });

        emit NewAuction(auctionId, auctionInfo[auctionId]);
        return auctionId;
    }

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
    ) external payable returns (bool) {
        if (!_registry.platformContracts(address(this)))
            revert ContractIsDeprecated();
        if (getAuctionStatus(auctionId) != "ACTIVE")
            revert AuctionIsNotActive();

        uint256 totalAmount = amountFromBalance +
            externalFunds +
            // this allows the top bidder to top off their bid
            bids[auctionId][msg.sender].amount;

        if (totalAmount <= bids[auctionId][highestBidder[auctionId]].amount)
            revert AuctionIsNotActive();
        if (totalAmount < auctionInfo[auctionId].reservePrice)
            revert BidIsNotHighEnough();

        address currency = auctionInfo[auctionId].currency;
        uint256 claimableFunds = _treasury.claimableFunds(msg.sender, currency);
        require(amountFromBalance <= claimableFunds, "Not enough balance");

        if (currency != ETH) {
            IERC20 token = IERC20(currency);
            token.safeTransferFrom(
                msg.sender,
                address(_treasury),
                externalFunds
            );
        } else {
            if (msg.value != externalFunds) revert ArgumentsAndValueMismatch();
        }

        // next highest bid can be made claimable now,
        // also helps for figuring out how much more net is in escrow
        address lastHighestBidder = highestBidder[auctionId];
        uint256 lastHighestAmount = bids[auctionId][lastHighestBidder].amount;
        uint256 escrowAmount = _treasury.auctionEscrow(currency);
        _treasury.updateAuctionEscrow(
            currency,
            escrowAmount + totalAmount - lastHighestAmount
        );

        // last bidder can claim their fund now
        if (lastHighestBidder != msg.sender) {
            delete bids[auctionId][lastHighestBidder].amount;
            _treasury.updateClaimableFunds(
                lastHighestBidder,
                currency,
                claimableFunds + lastHighestAmount
            );
        }
        if (amountFromBalance > 0) {
            _treasury.updateClaimableFunds(
                msg.sender,
                currency,
                claimableFunds - amountFromBalance
            );
        }
        bids[auctionId][msg.sender].amount = totalAmount;
        bids[auctionId][msg.sender].timestamp = block.timestamp;
        highestBidder[auctionId] = msg.sender;

        emit BidPlaced(auctionId, totalAmount);
        return true;
    }

    /// @notice Send NFT to auction winner and funds to auctioner's balance
    /// @notice Alternatively, allows auctioner to reclaim on an unsuccessful auction
    /// @dev this function delivers the NFT and moves the bid to the auctioner's claimable balance
    ///   and also accounts for the system fee and royalties (if applicable)
    function resolveAuction(uint256 auctionId) external {
        bytes32 status = getAuctionStatus(auctionId);
        if (status != "CANCELLED" && status != "ENDED")
            revert AuctionIsNotEndOrCancelled();

        AuctionInfo memory auctionInfo_ = auctionInfo[auctionId];
        address highestBidder_ = highestBidder[auctionId];
        uint256 winningBid = bids[auctionId][highestBidder_].amount;
        uint256 totalFundsToPay = msg.sender == auctionInfo_.owner
            ? 0
            : winningBid;

        // accounting logic
        address recipient;
        if (totalFundsToPay != 0) {
            _treasury.proceedAuctionFunds(
                auctionId,
                winningBid,
                auctionInfo_.nftAddress
            );
            recipient = highestBidder_;
        } else {
            recipient = auctionInfo_.owner;
        }

        auctionInfo_.isERC721
            ? _treasury.transferERC721To(
                auctionInfo_.nftAddress,
                recipient,
                auctionInfo_.nftId
            )
            : _treasury.transferERC1155To(
                auctionInfo_.nftAddress,
                recipient,
                auctionInfo_.nftId,
                1
            );

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
        if (msg.sender != auctionInfo[auctionId].owner && msg.sender != owner())
            revert OnlyOwnerOrAuctionCreator();

        bytes32 status = getAuctionStatus(auctionId);
        if (status != "ACTIVE" && status != "PENDING")
            revert AuctionMustBeActiveOrPending();

        cancelledAuction[auctionId] = true;

        address currency = auctionInfo[auctionId].currency;
        address highestBidder_ = highestBidder[auctionId];
        uint256 highestBid = bids[auctionId][highestBidder_].amount;
        uint256 claimableFunds = _treasury.claimableFunds(
            highestBidder_,
            currency
        );
        uint256 escrowAmount = _treasury.auctionEscrow(currency);

        // current highest bid moves from escrow to being reclaimable
        _treasury.updateAuctionEscrow(currency, escrowAmount - highestBid);
        _treasury.updateClaimableFunds(
            highestBidder_,
            currency,
            claimableFunds + highestBid
        );

        emit AuctionCancelled(auctionId);
    }

    function getAuctionStatus(uint256 auctionId) public view returns (bytes32) {
        if (auctionId > auctionIdCounter || auctionId == 0)
            revert AuctionDoesNotExist();

        if (
            cancelledAuction[auctionId] ||
            !_registry.platformContracts(address(this))
        ) return "CANCELLED";

        if (claimed[auctionId]) return "ENDED & CLAIMED";

        uint256 startTime = auctionInfo[auctionId].startTime;
        uint256 endTime = auctionInfo[auctionId].endTime;

        if (block.timestamp < startTime) return "PENDING";

        if (block.timestamp >= startTime && block.timestamp < endTime)
            return "ACTIVE";

        if (block.timestamp > endTime) return "ENDED";

        revert("error");
    }

    function _beforeAuction(
        address nftAddress,
        uint256 startTime,
        uint256 endTime,
        address currency
    ) private {
        if (!_registry.platformContracts(nftAddress))
            revert NFTContractIsNotApproved();
        if (!_registry.platformContracts(address(this)))
            revert ContractIsDeprecated();
        if (!_registry.approvedCurrencies(currency))
            revert CurrencyIsNotSupported();
        if (!INFT(nftAddress).supportsInterface(0x2a55205a))
            revert ContractMustSupportERC2981();
        if (endTime <= startTime) revert EndTimeMustBeGreaterThanStartTime();
    }
}
