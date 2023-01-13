// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "./interfaces/INFT.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ISale.sol";
import "./interfaces/IAuction.sol";

/// @title Marketplace
/// @author Linum Labs
/// @notice Allows selling bundles of ERC1155 NFTs and ERC721 at a fix price
contract Treasury is Ownable, ERC721Holder, ERC1155Holder {
    using SafeERC20 for IERC20;

    // address alias for using ETH as a currency
    address constant ETH = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);
    IRegistry immutable registry;
    ISale immutable sale;
    IAuction immutable auction;
    address[] approvedContracts;

    event ClaimFunds(
        address indexed accountOf,
        address indexed tokenAddress,
        uint256 indexed newBalance
    );

    event BalanceUpdated(
        address indexed accountOf,
        address indexed tokenAddress,
        uint256 indexed newBalance
    );

    event EscrowUpdate(address currency, uint256 newEscrowAmount);

    modifier onlyAuction() {
        require(
            msg.sender == address(auction),
            "Only the Auction contract can call this function"
        );
        _;
    }

    // account => currency => amount
    mapping(address => mapping(address => uint256)) public claimableFunds;
    mapping(address => uint256) public auctionEscrow; // currency => amount

    constructor(
        address registryAddress,
        address saleAddress,
        address auctionAddress
    ) {
        registry = IRegistry(registryAddress);
        sale = ISale(saleAddress);
        auction = IAuction(auctionAddress);
    }

    /// @notice Grant the permission to update the in-contract funds
    function updateClaimableFunds(
        address account,
        address currency,
        uint256 newClaimableFunds
    ) external {
        require(
            msg.sender == address(sale) || msg.sender == address(auction),
            "Only Sale or Auction contract can call this function"
        );
        claimableFunds[account][currency] = newClaimableFunds;

        emit BalanceUpdated(account, currency, newClaimableFunds);
    }

    /// @notice Withdraws in-contract balance of a particular token
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    function claimFunds(address tokenAddress) external {
        uint256 payout = claimableFunds[msg.sender][tokenAddress];
        require(payout > 0, "Nothing to claim");
        if (tokenAddress != ETH) {
            delete claimableFunds[msg.sender][tokenAddress];
            IERC20(tokenAddress).safeTransfer(msg.sender, payout);
        } else {
            delete claimableFunds[msg.sender][tokenAddress];
            (bool success, bytes memory reason) = msg.sender.call{
                value: payout
            }("");
            require(success, string(reason));
        }

        emit ClaimFunds(msg.sender, tokenAddress, payout);
    }

    /// @notice internal function for handling royalties and system fee
    function proceedAuctionFunds(
        uint256 auctionId,
        uint256 fundsToPay,
        address nftAddress
    ) external onlyAuction {
        IAuction.AuctionInfo memory auctionInfo = auction.auctionInfo(
            auctionId
        );
        address currency = auctionInfo.currency;

        auctionEscrow[currency] -= fundsToPay;
        // if this is from a successful auction
        (address artistAddress, uint256 royalties) = INFT(nftAddress)
            .royaltyInfo(auctionInfo.nftId, fundsToPay);

        // system fee
        (address systemWallet, uint256 fee) = registry.feeInfo(fundsToPay);
        fundsToPay -= fee;
        claimableFunds[systemWallet][currency] += fee;

        emit BalanceUpdated(
            systemWallet,
            currency,
            claimableFunds[systemWallet][currency]
        );

        // artist royalty if artist isn't the seller
        if (auctionInfo.owner != artistAddress) {
            fundsToPay -= royalties;
            claimableFunds[artistAddress][currency] += royalties;
            emit BalanceUpdated(
                artistAddress,
                currency,
                claimableFunds[artistAddress][currency]
            );
        }

        // seller gains
        claimableFunds[auctionInfo.owner][auctionInfo.currency] += fundsToPay;

        emit BalanceUpdated(
            auctionInfo.owner,
            auctionInfo.currency,
            claimableFunds[auctionInfo.owner][auctionInfo.currency]
        );
    }

    function transferERC721To(
        address nftAddress,
        address recipient,
        uint256 nftId
    ) external onlyAuction {
        INFT(nftAddress).safeTransferFrom(address(this), recipient, nftId, "");
    }

    function transferERC1155To(
        address nftAddress,
        address recipient,
        uint256 nftId,
        uint256 amount
    ) external onlyAuction {
        INFT(nftAddress).safeTransferFrom(
            address(this),
            recipient,
            nftId,
            amount,
            ""
        );
    }

    function updateAuctionEscrow(address currency, uint256 newEscrowAmount)
        external
        onlyAuction
    {
        auctionEscrow[currency] = newEscrowAmount;

        emit EscrowUpdate(currency, newEscrowAmount);
    }
}
