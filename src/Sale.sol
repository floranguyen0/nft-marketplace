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
    address private constant ETH =
        address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
    IRegistry private immutable _registry;
    ITreasury private immutable _treasury;

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

    error CanOnlySellOneNFT();
    error ContractIsDeprecated();
    error SaleIsNotActive();
    error ZeroAddressNotAllowed();
    error NotEnoughStock();
    error NotEnoughBalance();
    error InputValueAndPriceMismatch();
    error SaleIsNotClosed();
    error OnlyNFTOwnerCanClaim();
    error StockAlreadySoldOrClaimed();
    error SaleMustBeActiveOrPending();
    error SaleDoesNotExist();
    error NFTContractIsNotApproved();
    error CurrencyIsNotSupported();
    error ContractMustSupportERC2981();
    error EndTimeMustBeGreaterThanStartTime();
    error OnlyOwnerOrSaleCreator();
    error UnexpectedError();

    struct SaleInfo {
        uint128 nftId;
        bool isERC721;
        address nftAddress;
        address owner;
        address currency; // use zero address or 0xaaa for ETH
        uint256 amount; // amount of NFTs being sold
        uint256 purchased; // amount of NFTs purchased thus far
        uint256 startTime;
        uint256 endTime;
        uint256 price;
    }

    mapping(uint256 => SaleInfo) public saleInfo; // saleId => saleInfo
    mapping(uint256 => bool) public cancelledSale; // saleId => isSaleCancelled
    // saleId => purchaserAddress => amountPurchased
    mapping(uint256 => mapping(address => uint256)) public purchased;

    constructor(address registryAddress, address treasuryAddress) {
        _registry = IRegistry(registryAddress);
        _treasury = ITreasury(treasuryAddress);
    }

    /// @notice Creates a sale of ERC1155 and ERC721 NFTs
    /// @param startTime uint256 timestamp when the sale should commence
    /// @param endTime uint256 timestamp when sale should end
    /// @param currency address of the token bids should be made in
    function createSale(
        bool isERC721,
        address nftAddress,
        uint128 nftId,
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
                amount,
                ""
            );

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
        if (!_registry.platformContracts(address(this)))
            revert ContractIsDeprecated();
        if (getSaleStatus(saleId) != "ACTIVE") revert SaleIsNotActive();

        assembly {
            if iszero(recipient) {
                let ptr := mload(0x40)
                mstore(
                    ptr,
                    0x8579befe00000000000000000000000000000000000000000000000000000000
                ) // selector for `ZeroAddressNotAllowed()`
                revert(ptr, 0x4)
            }
        }

        SaleInfo memory saleInfo_ = saleInfo[saleId];
        if (amountToBuy > saleInfo_.amount - saleInfo_.purchased)
            revert NotEnoughStock();

        address currency = saleInfo_.currency;

        if (amountFromBalance > _treasury.claimableFunds(msg.sender, currency))
            revert NotEnoughBalance();

        (address artistAddress, uint256 royalties) = INFT(saleInfo_.nftAddress)
            .royaltyInfo(saleInfo_.nftId, amountToBuy * saleInfo_.price);

        // send the nft price to the platform
        if (currency != ETH) {
            IERC20 token = IERC20(currency);

            token.safeTransferFrom(
                msg.sender,
                address(_treasury),
                (amountToBuy * saleInfo_.price) - amountFromBalance
            );
        } else {
            if (
                msg.value != (amountToBuy * saleInfo_.price) - amountFromBalance
            ) revert InputValueAndPriceMismatch();
        }
        uint256 claimableFunds = _treasury.claimableFunds(msg.sender, currency);

        if (amountFromBalance != 0) {
            _treasury.updateClaimableFunds(
                msg.sender,
                currency,
                claimableFunds - amountFromBalance
            );
        }

        // system fee
        (address systemWallet, uint256 fee) = _registry.feeInfo(
            amountToBuy * saleInfo_.price
        );
        _treasury.updateClaimableFunds(
            systemWallet,
            currency,
            claimableFunds + fee
        );

        // artist royalty if artist isn't the seller
        if (saleInfo_.owner != artistAddress) {
            _treasury.updateClaimableFunds(
                artistAddress,
                currency,
                claimableFunds + royalties
            );
        } else {
            // since the artist is the seller
            delete royalties;
        }

        // seller gains
        uint256 sellerGains = (amountToBuy * saleInfo_.price) - fee - royalties;
        _treasury.updateClaimableFunds(
            saleInfo_.owner,
            currency,
            claimableFunds + sellerGains
        );

        // update the sale info
        saleInfo[saleId].purchased += amountToBuy;
        purchased[saleId][msg.sender] += amountToBuy;

        // send the nft to the buyer
        saleInfo_.isERC721
            ? _treasury.transferERC721To(
                saleInfo_.nftAddress,
                recipient,
                saleInfo_.nftId
            )
            : _treasury.transferERC1155To(
                saleInfo_.nftAddress,
                recipient,
                saleInfo_.nftId,
                amountToBuy
            );

        emit Purchase(saleId, msg.sender, recipient);
    }

    /// @notice Allows contract owner or seller to cancel a pending or active sale
    function cancelSale(uint256 saleId) external {
        if (msg.sender != saleInfo[saleId].owner && msg.sender != owner())
            revert OnlyOwnerOrSaleCreator();

        bytes32 status = getSaleStatus(saleId);
        if (status != "ACTIVE" && status != "PENDING")
            revert SaleMustBeActiveOrPending();

        cancelledSale[saleId] = true;

        emit SaleCancelled(saleId);
    }

    /// @notice Allows seller to reclaim unsold NFTs
    /// @dev sale must be cancelledAuction or ended
    /// @param saleId the index of the sale to claim from
    function claimSaleNfts(uint256 saleId) external {
        bytes32 status = getSaleStatus(saleId);
        if (status != "CANCELLED" && status != "ENDED")
            revert SaleIsNotClosed();

        SaleInfo memory saleInfo_ = saleInfo[saleId];
        if (msg.sender != saleInfo_.owner) revert OnlyNFTOwnerCanClaim();
        if (saleInfo_.purchased == saleInfo_.amount)
            revert StockAlreadySoldOrClaimed();

        uint256 stock = saleInfo_.amount - saleInfo_.purchased;
        // update the sale info and send the nfts back to the seller
        saleInfo[saleId].purchased = saleInfo_.amount;
        saleInfo_.isERC721
            ? _treasury.transferERC721To(
                saleInfo_.nftAddress,
                saleInfo_.owner,
                saleInfo_.nftId
            )
            : _treasury.transferERC1155To(
                saleInfo_.nftAddress,
                saleInfo_.owner,
                saleInfo_.nftId,
                stock
            );

        emit ClaimSaleNFTs(saleId, msg.sender, stock);
    }

    function getSaleStatus(uint256 saleId) public view returns (bytes32) {
        if (saleId > saleIdCounter || saleId == 0) revert SaleDoesNotExist();

        if (
            cancelledSale[saleId] || !_registry.platformContracts(address(this))
        ) return "CANCELLED";

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

        revert UnexpectedError();
    }

    function _validateSale(
        bool isERC721,
        address nftAddress,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        address currency
    ) private {
        if (isERC721 && amount != 1) revert CanOnlySellOneNFT();
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
