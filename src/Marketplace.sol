// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/INFT.sol";
import "./interfaces/IRegistry.sol";

/// @notice Allows selling bundles of ERC1155 NFTs and ERC721 at a fix price
/// @dev Assumes the existence of a Registry as specified in IRegistry
/// @dev Assumes an ERC2981-compliant NFT, as specified below
contract Sale is ERC721Holder, ERC1155Holder, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    // address alias for using ETH as a currency
    address constant ETH = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);

    Counters.Counter private _saleId; // _saleId starts from 1
    Counters.Counter private _auctionId; // _autionId starts from 1
    IRegistry private Registry;

    event SaleCreated(
        uint256 indexed id,
        address indexed nftAddress,
        uint256 indexed nftID
    );
    event SaleCancelled(uint256 indexed saleId);
    event Purchase(
        uint256 indexed saleId,
        address indexed purchaser,
        address indexed recipient
    );
    event NFTsReclaimed(
        uint256 indexed id,
        address indexed owner,
        uint256 indexed amount
    );
    event ClaimFunds(
        address indexed accountOf,
        address indexed tokenAddress,
        uint256 indexed newBalance
    );

    event NewAuction(uint256 indexed auctionId, AuctionInfo newAuction);
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

    struct SaleInfo {
        address nftAddress;
        uint256 nftId;
        address owner;
        uint256 amount; // amount of NFTs being sold
        uint256 purchased; // amount of NFTs purchased thus far
        uint256 startTime;
        uint256 endTime;
        uint256 price;
        address currency; // use zero address or 0xaaa for ETH
    }

    struct AuctionInfo {
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
        uint256 auctionId;
        address bidder;
        uint256 amount;
        uint256 timestamp;
    }

    // saleId => SaleInfo
    mapping(uint256 => SaleInfo) public sales;
    mapping(uint256 => bool) private cancelledSale;
    mapping(uint256 => mapping(address => uint256)) public purchased;
    // user address => tokenAddress => amount
    mapping(address => mapping(address => uint256)) public claimableFunds;

    mapping(uint256 => AuctionInfo) private auctions;
    mapping(uint256 => bool) private cancelledAuction;
    mapping(uint256 => bool) private claimed;
    mapping(uint256 => address) private highestBid;
    mapping(uint256 => mapping(address => Bid)) private bids;
    // token => amount
    mapping(address => uint256) private escrow;

    constructor(address registry) {
        Registry = IRegistry(registry);
    }

    /// @notice Creates a sale of ERC1155 and ERC721 NFTs
    /// @dev NFT contract must be ERC2981-compliant and recognized by Registry
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param nftAddress the address of the NFT contract
    /// @param nftId the id of the NFTs on the NFT contract
    /// @param startTime uint256 timestamp when the sale should commence
    /// @param endTime uint256 timestamp when sale should end
    /// @param price the price for each NFT
    /// @param currency address of the token bids should be made in
    /// @return the index of the sale being created
    function createSale(
        bool isERC721,
        address nftAddress,
        uint256 nftId,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        uint256 price,
        address currency
    ) external nonReentrant returns (uint256) {
        _beforeSaleOrAuction(nftAddress, startTime, endTime, currency);
        INFT nftContract = INFT(nftAddress);
        if (isERC721) {
            require(
                nftContract.ownerOf(nftId) == msg.sender,
                "The caller is not the nft owner"
            );
        } else {
            require(
                nftContract.balanceOf(msg.sender, nftId) >= amount,
                "Insufficient NFT balance"
            );
        }

        // save the sale info
        _saleId.increment();
        uint256 saleId = _saleId.current();

        sales[saleId] = SaleInfo({
            nftAddress: nftAddress,
            nftId: nftId,
            owner: msg.sender,
            amount: isERC721 ? 1 : amount,
            purchased: 0,
            startTime: startTime,
            endTime: endTime,
            price: price,
            currency: currency
        });

        // transfer nft to the platform
        if (isERC721) {
            nftContract.safeTransferFrom(msg.sender, address(this), nftId, "");
        } else {
            nftContract.safeTransferFrom(
                msg.sender,
                address(this),
                nftId,
                amount,
                ""
            );
        }

        emit SaleCreated(saleId, nftAddress, nftId);
        return saleId;
    }

    /// @notice Allows purchase of NFTs from a sale
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @dev automatically calculates system fee and royalties (where applicable)
    /// @dev pass in 1 if a user buys ERC 721
    /// @param saleId the index of the sale to purchase from
    /// @param amountToBuy the number of NFTs to purchase
    /// @param amountFromBalance the amount to spend from msg.sender's balance in this contract
    /// @return a bool indicating success
    function buy(
        bool isERC721,
        uint256 saleId,
        address recipient,
        uint256 amountToBuy,
        uint256 amountFromBalance
    ) external payable nonReentrant returns (bool) {
        require(
            Registry.isPlatformContract(address(this)),
            "This contract is deprecated"
        );
        require(getSaleStatus(saleId) == "ACTIVE", "Sale is not active");
        SaleInfo memory currentSale = sales[saleId];
        if (!isERC721) {
            require(
                amountToBuy <= currentSale.amount - currentSale.purchased,
                "Not enough stock for purchase"
            );
        }
        address currency = currentSale.currency;
        require(
            amountFromBalance <= claimableFunds[msg.sender][currency],
            "Not enough balance"
        );

        uint256 nftId = currentSale.nftId;

        INFT Nft = INFT(currentSale.nftAddress);
        (address artistAddress, uint256 royalties) = Nft.royaltyInfo(
            nftId,
            amountToBuy * currentSale.price
        );

        // send the nft price to the platform
        if (currency != ETH) {
            IERC20 token = IERC20(currency);

            token.safeTransferFrom(
                msg.sender,
                address(this),
                (amountToBuy * currentSale.price) - amountFromBalance
            );
        } else {
            require(
                msg.value ==
                    (amountToBuy * currentSale.price) - amountFromBalance,
                "msg.value + balance != price"
            );
        }
        if (amountFromBalance > 0) {
            claimableFunds[msg.sender][currency] -= amountFromBalance;
        }

        // system fee
        (address systemWallet, uint256 fee) = Registry.feeInfo(
            amountToBuy * currentSale.price
        );
        claimableFunds[systemWallet][currency] += fee;

        // artist royalty if artist isn't the seller
        if (currentSale.owner != artistAddress) {
            claimableFunds[artistAddress][currency] += royalties;
        } else {
            // since the artist is the seller
            royalties = 0;
        }

        // seller gains
        claimableFunds[currentSale.owner][currency] +=
            (amountToBuy * currentSale.price) -
            fee -
            royalties;

        // update the sale info
        sales[saleId].purchased += amountToBuy;
        purchased[saleId][msg.sender] += amountToBuy;

        // send the nft to the buyer
        if (isERC721) {
            Nft.safeTransferFrom(
                address(this),
                recipient,
                currentSale.nftId,
                ""
            );
        } else {
            Nft.safeTransferFrom(
                address(this),
                recipient,
                currentSale.nftId,
                amountToBuy,
                ""
            );
        }

        emit Purchase(saleId, msg.sender, recipient);
        return true;
    }

    /// @notice Allows seller to reclaim unsold NFTs
    /// @dev sale must be cancelledAuction or ended
    /// @param saleId the index of the sale to claim from
    function claimNfts(bool isERC721, uint256 saleId) external {
        bytes32 status = getSaleStatus(saleId);
        require(
            status == "CANCELLED" || status == "ENDED",
            "Cannot claim before sale closes"
        );
        require(msg.sender == sales[saleId].owner, "Only nft owner can claim");
        require(
            sales[saleId].purchased < sales[saleId].amount,
            "Stock already sold or claimed"
        );

        uint256 stock = sales[saleId].amount - sales[saleId].purchased;
        // update the sale info and send the nfts back to the seller
        sales[saleId].purchased = sales[saleId].amount;
        if (isERC721) {
            INFT(sales[saleId].nftAddress).safeTransferFrom(
                address(this),
                sales[saleId].owner,
                sales[saleId].nftId,
                ""
            );
        } else {
            INFT(sales[saleId].nftAddress).safeTransferFrom(
                address(this),
                sales[saleId].owner,
                sales[saleId].nftId,
                stock,
                ""
            );
        }

        emit NFTsReclaimed(saleId, msg.sender, stock);
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

    /// @notice Allows contract owner or seller to cancel a pending or active sale
    /// @param saleId the index of the sale to cancel
    function cancelSale(bool isERC721, uint256 saleId) external {
        address nftOwner = isERC721
            ? INFT(sales[saleId].nftAddress).ownerOf(sales[saleId].nftId)
            : sales[saleId].owner;

        require(
            msg.sender == nftOwner || msg.sender == owner(),
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

    /// @notice Creates a first-price auction for a ERC1155 NFT
    /// @dev NFT contract must be ERC2981-compliant and recognized by Registry
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @param nftAddress the address of the NFT contract
    /// @param id the id of the NFT on the NFT contract
    /// @param startTime uint256 timestamp when the auction should commence
    /// @param endTime uint256 timestamp when auction should end
    /// @param reservePrice minimum price for bids
    /// @param currency address of the token bids should be made in
    /// @return the index of the auction being created
    function createAuction(
        address nftAddress,
        uint256 id,
        uint256 startTime,
        uint256 endTime,
        uint256 reservePrice,
        address currency
    ) external nonReentrant returns (uint256) {
        _beforeSaleOrAuction(nftAddress, startTime, endTime, currency);
        INFT nftContract = INFT(nftAddress);
        require(nftContract.balanceOf(msg.sender, id) > 0, "does not own NFT");

        _auctionId.increment();
        uint256 auctionId = _auctionId.current();

        auctions[auctionId] = AuctionInfo({
            id: auctionId,
            owner: msg.sender,
            nftAddress: nftAddress,
            nftId: id,
            startTime: startTime,
            endTime: endTime,
            reservePrice: reservePrice,
            currency: currency
        });

        nftContract.safeTransferFrom(msg.sender, address(this), id, 1, "");

        emit NewAuction(auctionId, auctions[auctionId]);
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
    ) external payable nonReentrant returns (bool) {
        require(
            Registry.isPlatformContract(address(this)) == true,
            "This contract is deprecated"
        );
        require(
            getAuctionStatus(auctionId) == "ACTIVE",
            "auction is not active"
        );
        uint256 totalAmount = amountFromBalance +
            externalFunds +
            // this allows the top bidder to top off their bid
            bids[auctionId][msg.sender].amount;
        require(
            totalAmount > bids[auctionId][highestBid[auctionId]].amount,
            "bid is not high enough"
        );
        require(
            totalAmount >= auctions[auctionId].reservePrice,
            "bid is lower than the reserve price"
        );
        require(
            amountFromBalance <=
                claimableFunds[msg.sender][auctions[auctionId].currency],
            "not enough balance"
        );

        if (auctions[auctionId].currency != ETH) {
            IERC20 token = IERC20(auctions[auctionId].currency);

            token.safeTransferFrom(msg.sender, address(this), externalFunds);
        } else {
            require(msg.value == externalFunds, "mismatch of value and args");
        }

        // next highest bid can be made claimable now,
        // also helps for figuring out how much more net is in escrow
        address lastBidder = highestBid[auctionId];
        uint256 lastAmount = bids[auctionId][lastBidder].amount;
        escrow[auctions[auctionId].currency] += totalAmount - lastAmount;

        if (bids[auctionId][msg.sender].bidder == address(0)) {
            bids[auctionId][msg.sender].bidder = msg.sender;
        }

        if (lastBidder != msg.sender) {
            bids[auctionId][lastBidder].amount = 0;
            claimableFunds[lastBidder][
                auctions[auctionId].currency
            ] += lastAmount;
            emit BalanceUpdated(
                lastBidder,
                auctions[auctionId].currency,
                claimableFunds[lastBidder][auctions[auctionId].currency]
            );
        }
        if (amountFromBalance > 0) {
            claimableFunds[msg.sender][
                auctions[auctionId].currency
            ] -= amountFromBalance;
            emit BalanceUpdated(
                msg.sender,
                auctions[auctionId].currency,
                amountFromBalance
            );
        }
        bids[auctionId][msg.sender].amount = totalAmount;
        bids[auctionId][msg.sender].timestamp = block.timestamp;

        highestBid[auctionId] = msg.sender;

        emit BidPlaced(auctionId, totalAmount);

        return true;
    }

    /// @notice Allows the winner of the auction to claim their NFT
    /// @notice Alternatively, allows auctioner to reclaim on an unsuccessful auction
    /// @dev this function delivers the NFT and moves the bid to the auctioner's claimable balance
    ///   and also accounts for the system fee and royalties (if applicable)
    /// @param auctionId the index of the auction to bid on
    /// @param recipient the address the NFT should be sent to
    /// @return a bool indicating success
    function claimNft(uint256 auctionId, address recipient)
        external
        returns (bool)
    {
        require(
            msg.sender == highestBid[auctionId] ||
                msg.sender == auctions[auctionId].owner,
            "cannot claim nft"
        );
        bytes32 status = getAuctionStatus(auctionId);
        require(
            status == "CANCELLED" || status == "ENDED",
            "nft not available for claiming"
        );
        INFT Nft = INFT(auctions[auctionId].nftAddress);
        uint256 totalFundsToPay = msg.sender == auctions[auctionId].owner
            ? 0
            : bids[auctionId][highestBid[auctionId]].amount;
        if (msg.sender == highestBid[auctionId]) {
            require(
                block.timestamp > auctions[auctionId].endTime,
                "cannot claim from auction"
            );
            require(
                bids[auctionId][highestBid[auctionId]].amount >=
                    auctions[auctionId].reservePrice,
                "reserve price not met"
            );
        } else if (msg.sender == auctions[auctionId].owner) {
            require(
                cancelledAuction[auctionId] ||
                    (bids[auctionId][highestBid[auctionId]].amount <
                        auctions[auctionId].reservePrice &&
                        block.timestamp > auctions[auctionId].endTime),
                "owner cannot reclaim nft"
            );
        }

        // accounting logic
        if (totalFundsToPay > 0) {
            _nftPayment(auctionId, totalFundsToPay, Nft);
        }

        Nft.safeTransferFrom(
            address(this),
            recipient,
            auctions[auctionId].nftId,
            1,
            ""
        );
        claimed[auctionId] = true;

        emit ClaimNFT(
            auctions[auctionId].nftId,
            msg.sender,
            recipient,
            bids[auctionId][highestBid[auctionId]].amount
        );

        return true;
    }

    /// @notice Allows contract owner to send NFT to auction winner and funds to auctioner's balance
    /// @dev prevents assets from being stuck if winner does not claim
    function resolveAuction(uint256 auctionId) external onlyOwner {
        require(
            getAuctionStatus(auctionId) == "ENDED",
            "can only resolve ENDED"
        );
        uint256 winningBid = bids[auctionId][highestBid[auctionId]].amount;
        require(winningBid > 0, "no bids: cannot resolve");
        INFT Nft = INFT(auctions[auctionId].nftAddress);
        _nftPayment(auctionId, winningBid, Nft);

        Nft.safeTransferFrom(
            address(this),
            highestBid[auctionId],
            auctions[auctionId].nftId,
            1,
            ""
        );
        claimed[auctionId] = true;

        emit ClaimNFT(
            auctions[auctionId].id,
            msg.sender,
            highestBid[auctionId],
            bids[auctionId][highestBid[auctionId]].amount
        );
    }

    /// @notice Allows contract owner or auctioner to cancel a pending or active auction
    function cancelAuction(uint256 auctionId) external {
        require(
            msg.sender == auctions[auctionId].owner || msg.sender == owner(),
            "only owner or sale creator"
        );
        require(
            getAuctionStatus(auctionId) == "ACTIVE" ||
                getAuctionStatus(auctionId) == "PENDING",
            "must be active or pending"
        );
        cancelledAuction[auctionId] = true;
        // current highest bid moves from escrow to being reclaimable
        address highestBidder = highestBid[auctionId];
        uint256 _highestBid = bids[auctionId][highestBidder].amount;

        escrow[auctions[auctionId].currency] -= _highestBid;
        claimableFunds[highestBidder][
            auctions[auctionId].currency
        ] += _highestBid;
        emit BalanceUpdated(
            highestBidder,
            auctions[auctionId].currency,
            claimableFunds[highestBidder][auctions[auctionId].currency]
        );
        emit AuctionCancelled(auctionId);
    }

    /// @return an "AuctionInfo" struct with the details of the auction requested
    function getAuctionDetails(uint256 auctionId)
        external
        view
        returns (AuctionInfo memory)
    {
        require(
            auctionId <= _auctionId.current() && auctionId > 0,
            "auction does not exist"
        );
        return auctions[auctionId];
    }

    /// @dev the amount of an outbid bid is reduced to zero
    /// @return a Bid struct with details of a specific bid
    function getBidDetails(uint256 auctionId, address bidder)
        external
        view
        returns (Bid memory)
    {
        return bids[auctionId][bidder];
    }

    /// @notice Returns the address of the current highest bidder in a particular auction
    function getHighestBidder(uint256 auctionId)
        external
        view
        returns (address)
    {
        return highestBid[auctionId];
    }

    function getAuctionStatus(uint256 auctionId) public view returns (bytes32) {
        require(
            auctionId <= _auctionId.current() && auctionId > 0,
            "auction does not exist"
        );
        if (
            cancelledAuction[auctionId] ||
            !Registry.isPlatformContract(address(this))
        ) return "CANCELLED";
        if (claimed[auctionId]) return "ENDED & CLAIMED";
        if (block.timestamp < auctions[auctionId].startTime) return "PENDING";
        if (
            block.timestamp >= auctions[auctionId].startTime &&
            block.timestamp < auctions[auctionId].endTime
        ) return "ACTIVE";
        if (block.timestamp > auctions[auctionId].endTime) return "ENDED";
        revert("error");
    }

    /// @notice allows contract to receive ERC1155 NFTs
    function onERC1155Received() external pure returns (bytes4) {
        // 0xf23a6e61 = bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)")
        return 0xf23a6e61;
    }

    function getSaleStatus(uint256 saleId) public view returns (bytes32) {
        require(
            saleId <= _saleId.current() && saleId > 0,
            "Sale does not exist"
        );
        if (
            cancelledSale[saleId] || !Registry.isPlatformContract(address(this))
        ) return "CANCELLED";
        else if (block.timestamp < sales[saleId].startTime) return "PENDING";
        else if (
            block.timestamp < sales[saleId].endTime &&
            sales[saleId].purchased < sales[saleId].amount
        ) return "ACTIVE";
        else if (
            block.timestamp >= sales[saleId].endTime ||
            sales[saleId].purchased == sales[saleId].amount
        ) return "ENDED";
        else revert("Error");
    }

    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    /// @return the uint256 in-contract balance of a specific address for a specific token
    function getClaimableBalance(address account, address token)
        external
        view
        returns (uint256)
    {
        return claimableFunds[account][token];
    }

    function _beforeSaleOrAuction(
        address nftAddress,
        uint256 startTime,
        uint256 endTime,
        address currency
    ) private {
        require(
            Registry.isPlatformContract(nftAddress),
            "NFT is not in approved contract"
        );
        require(
            Registry.isPlatformContract(address(this)),
            "This contract is deprecated"
        );
        require(
            Registry.isApprovedCurrency(currency),
            "Currency is not supported"
        );
        require(
            INFT(nftAddress).supportsInterface(0x2a55205a),
            "Contract must support ERC2981"
        );
        require(endTime > startTime, "Error in start/end params");
    }

    /// @notice internal function for handling royalties and system fee
    function _nftPayment(
        uint256 auctionId,
        uint256 fundsToPay,
        INFT Nft
    ) private {
        escrow[auctions[auctionId].currency] -= fundsToPay;
        // if this is from successful auction
        (address artistAddress, uint256 royalties) = Nft.royaltyInfo(
            auctions[auctionId].nftId,
            fundsToPay
        );

        // system fee
        (address systemWallet, uint256 fee) = Registry.feeInfo(fundsToPay);
        fundsToPay -= fee;
        claimableFunds[systemWallet][auctions[auctionId].currency] += fee;
        emit BalanceUpdated(
            systemWallet,
            auctions[auctionId].currency,
            claimableFunds[systemWallet][auctions[auctionId].currency]
        );

        // artist royalty if artist isn't the seller
        if (auctions[auctionId].owner != artistAddress) {
            fundsToPay -= royalties;
            claimableFunds[artistAddress][
                auctions[auctionId].currency
            ] += royalties;
            emit BalanceUpdated(
                artistAddress,
                auctions[auctionId].currency,
                claimableFunds[artistAddress][auctions[auctionId].currency]
            );
        }

        // seller gains
        claimableFunds[auctions[auctionId].owner][
            auctions[auctionId].currency
        ] += fundsToPay;
        emit BalanceUpdated(
            auctions[auctionId].owner,
            auctions[auctionId].currency,
            claimableFunds[auctions[auctionId].owner][
                auctions[auctionId].currency
            ]
        );
    }
}