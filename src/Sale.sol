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
/// @notice Allows selling bundles of ERC1155 NFTs and ERC721 at a fix price
contract Sale is Ownable {
    using SafeERC20 for IERC20;

    // address alias for using ETH as a currency
    address constant ETH = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
    IRegistry immutable registry;
    ITreasury immutable treasury;
    uint256 public saleIdCounter; // saleIdCounter starts from 1

    event SaleCreated(
        uint256 indexed saleId,
        address indexed nftAddress,
        uint256 indexed nftID
    );
    event Purchase(
        uint256 indexed saleId,
        address indexed purchaser,
        address indexed recipient
    );
    event SaleCancelled(uint256 indexed saleId);
    event ClaimSaleNFTs(
        uint256 indexed id,
        address indexed owner,
        uint256 indexed amount
    );

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

    mapping(uint256 => SaleInfo) public saleInfo;
    mapping(uint256 => bool) public cancelledSale;
    // saleId => purchaserAddress => amountPurchased
    mapping(uint256 => mapping(address => uint256)) public purchased;

    constructor(address registryAddress, address treasuryAddress) {
        registry = IRegistry(registryAddress);
        treasury = ITreasury(treasuryAddress);
    }

    /// @notice Creates a sale of ERC1155 and ERC721 NFTs
    /// @param startTime uint256 timestamp when the sale should commence
    /// @param endTime uint256 timestamp when sale should end
    /// @param currency address of the token bids should be made in
    function createSale(
        bool isERC721,
        address nftAddress,
        uint256 nftId,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        uint256 price,
        address currency
    ) external {
        _validateSale(
            isERC721,
            nftAddress,
            amount,
            startTime,
            endTime,
            currency
        );

        INFT nftContract = INFT(nftAddress);

        // transfer nft to the platform
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
                amount,
                ""
            );
        }

        // save sale info
        unchecked {
            ++saleIdCounter;
        }
        uint256 saleId = saleIdCounter;

        saleInfo[saleId] = SaleInfo({
            isERC721: isERC721,
            nftAddress: nftAddress,
            nftId: nftId,
            owner: msg.sender,
            amount: amount,
            purchased: 0,
            startTime: startTime,
            endTime: endTime,
            price: price,
            currency: currency
        });

        emit SaleCreated(saleId, nftAddress, nftId);
    }

    /// @notice Allows purchase of NFTs from a sale
    /// @param amountFromBalance the amount to spend from msg.sender's balance in this contract
    function buy(
        uint256 saleId,
        address recipient,
        uint256 amountToBuy,
        uint256 amountFromBalance
    ) external payable {
        require(
            registry.platformContracts(address(this)),
            "This contract is deprecated"
        );
        require(getSaleStatus(saleId) == "ACTIVE", "Sale is not active");
        SaleInfo memory saleInfo_ = saleInfo[saleId];
        require(
            amountToBuy <= saleInfo_.amount - saleInfo_.purchased,
            "Not enough NFT for purchase"
        );

        address currency = saleInfo_.currency;
        require(
            amountFromBalance <= treasury.claimableFunds(msg.sender, currency),
            "Not enough balance"
        );

        (address artistAddress, uint256 royalties) = INFT(saleInfo_.nftAddress)
            .royaltyInfo(saleInfo_.nftId, amountToBuy * saleInfo_.price);

        // send the nft price to the platform
        if (currency != ETH) {
            IERC20 token = IERC20(currency);

            token.safeTransferFrom(
                msg.sender,
                address(treasury),
                (amountToBuy * saleInfo_.price) - amountFromBalance
            );
        } else {
            require(
                msg.value ==
                    (amountToBuy * saleInfo_.price) - amountFromBalance,
                "msg.value + balance != price"
            );
        }
        uint256 claimableFunds = treasury.claimableFunds(msg.sender, currency);

        if (amountFromBalance > 0) {
            treasury.updateClaimableFunds(
                msg.sender,
                currency,
                claimableFunds - amountFromBalance
            );
        }

        // system fee
        (address systemWallet, uint256 fee) = registry.feeInfo(
            amountToBuy * saleInfo_.price
        );
        treasury.updateClaimableFunds(
            systemWallet,
            currency,
            claimableFunds + fee
        );

        // artist royalty if artist isn't the seller
        if (saleInfo_.owner != artistAddress) {
            treasury.updateClaimableFunds(
                artistAddress,
                currency,
                claimableFunds + royalties
            );
        } else {
            // since the artist is the seller
            royalties = 0;
        }

        // seller gains
        uint256 sellerGains = (amountToBuy * saleInfo_.price) - fee - royalties;
        treasury.updateClaimableFunds(
            saleInfo_.owner,
            currency,
            claimableFunds + sellerGains
        );

        // update the sale info
        saleInfo[saleId].purchased += amountToBuy;
        purchased[saleId][msg.sender] += amountToBuy;

        // send the nft to the buyer
        if (saleInfo_.isERC721) {
            treasury.transferERC721To(
                saleInfo_.nftAddress,
                recipient,
                saleInfo_.nftId
            );
        } else {
            treasury.transferERC1155To(
                saleInfo_.nftAddress,
                recipient,
                saleInfo_.nftId,
                amountToBuy
            );
        }

        emit Purchase(saleId, msg.sender, recipient);
    }

    /// @notice Allows contract owner or seller to cancel a pending or active sale
    function cancelSale(uint256 saleId) external {
        require(
            msg.sender == saleInfo[saleId].owner || msg.sender == owner(),
            "Only owner or sale creator"
        );
        require(
            getSaleStatus(saleId) == "ACTIVE" ||
                getSaleStatus(saleId) == "PENDING",
            "Must be active or pending"
        );
        cancelledSale[saleId] = true;

        emit SaleCancelled(saleId);
    }

    /// @notice Allows seller to reclaim unsold NFTs
    /// @dev sale must be cancelledAuction or ended
    /// @param saleId the index of the sale to claim from
    function claimSaleNfts(uint256 saleId) external {
        bytes32 status = getSaleStatus(saleId);
        require(
            status == "CANCELLED" || status == "ENDED",
            "Cannot claim before sale closes"
        );

        SaleInfo memory saleInfo_ = saleInfo[saleId];
        require(msg.sender == saleInfo_.owner, "Only nft owner can claim");
        require(
            saleInfo_.purchased < saleInfo_.amount,
            "Stock already sold or claimed"
        );

        uint256 stock = saleInfo_.amount - saleInfo_.purchased;
        // update the sale info and send the nfts back to the seller
        saleInfo[saleId].purchased = saleInfo_.amount;
        if (saleInfo_.isERC721) {
            treasury.transferERC721To(
                saleInfo_.nftAddress,
                saleInfo_.owner,
                saleInfo_.nftId
            );
        } else {
            treasury.transferERC1155To(
                saleInfo_.nftAddress,
                saleInfo_.owner,
                saleInfo_.nftId,
                stock
            );
        }

        emit ClaimSaleNFTs(saleId, msg.sender, stock);
    }

    function getSaleStatus(uint256 saleId) public view returns (bytes32) {
        require(saleId <= saleIdCounter && saleId > 0, "Sale does not exist");

        if (cancelledSale[saleId] || !registry.platformContracts(address(this)))
            return "CANCELLED";

        SaleInfo memory saleInfo_ = saleInfo[saleId];

        if (block.timestamp < saleInfo_.startTime) return "PENDING";

        if (
            block.timestamp < saleInfo_.endTime &&
            saleInfo_.purchased < saleInfo_.amount
        ) return "ACTIVE";

        if (
            block.timestamp >= saleInfo_.endTime ||
            saleInfo_.purchased == saleInfo_.amount
        ) return "ENDED";

        revert("Unexpected error");
    }

    function _validateSale(
        bool isERC721,
        address nftAddress,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        address currency
    ) private {
        if (isERC721) {
            require(amount == 1, "Can only sell one NFT for ERC721");
        }
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
