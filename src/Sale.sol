// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/marketplace/INFT.sol";
import "./interfaces/marketplace/IRegistry.sol";

/// @title Sale
/// @author Linum Labs
/// @notice Allows selling bundles of ERC1155 NFTs at a fix price
/// @dev Assumes the existence of a Registry as specified in IRegistry
/// @dev Assumes an ERC2981-compliant NFT, as specified below
contract Sale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    // address alias for using ETH as a currency
    address constant ETH = address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa);

    Counters.Counter private _saleId;
    IRegistry private Registry;

    event SaleCreated(uint256 indexed id, SaleInfo newSale);
    event SaleCancelled(uint256 indexed saleId);
    event Purchase(
        uint256 indexed saleId,
        address indexed purchaser,
        address indexed recipient,
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

    struct SaleInfo {
        uint256 id;
        address owner;
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

    // saleId => SaleInfo
    mapping(uint256 => SaleInfo) public sales;
    mapping(uint256 => bool) private cancelled;
    mapping(uint256 => mapping(address => uint256)) public purchased;
    // user address => tokenAddress => amount
    mapping(address => mapping(address => uint256)) public claimableFunds;

    constructor(address registry) {
        Registry = IRegistry(registry);
    }

    function getSaleStatus(uint256 saleId) public view returns (string memory) {
        require(
            saleId <= _saleId.current() && saleId > 0,
            "Sale does not exist"
        );
        if (cancelled[saleId] || !Registry.isPlatformContract(address(this)))
            return "CANCELLED";
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
    ) external nonReentrant returns (uint256) {
        INFT NftContract = INFT(nftContract);
        require(
            Registry.isPlatformContract(nftContract),
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
            NftContract.supportsInterface(0x2a55205a),
            "Contract must support ERC2981"
        );
        require(
            NftContract.balanceOf(msg.sender, id) >= amount,
            "Insufficient NFT balance"
        );
        require(endTime > startTime, "Error in start/end params");
        require(maxBuyAmount > 0, "MaxBuyAmount must be non-zero");
        _saleId.increment();
        uint256 saleId = _saleId.current();

        sales[saleId] = SaleInfo({
            id: saleId,
            owner: msg.sender,
            nftContract: nftContract,
            nftId: id,
            amount: amount,
            purchased: 0,
            startTime: startTime,
            endTime: endTime,
            price: price,
            maxBuyAmount: maxBuyAmount,
            currency: currency
        });

        NftContract.safeTransferFrom(msg.sender, address(this), id, amount, "");

        emit SaleCreated(saleId, sales[saleId]);

        return saleId;
    }

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
    ) external payable nonReentrant returns (bool) {
        require(
            Registry.isPlatformContract(address(this)),
            "This contract is deprecated"
        );
        require(
            keccak256(bytes(getSaleStatus(saleId))) ==
                keccak256(bytes("ACTIVE")),
            "Sale is not active"
        );
        SaleInfo memory currentSale = sales[saleId];
        require(
            purchased[saleId][msg.sender] + amountToBuy <=
                currentSale.maxBuyAmount,
            "Buy quantity too high"
        );
        require(
            amountToBuy <= currentSale.amount - currentSale.purchased,
            "Not enough stock for purchase"
        );
        address currency = currentSale.currency;
        require(
            amountFromBalance <= claimableFunds[msg.sender][currency],
            "Not enough balance"
        );

        uint256 nftId = currentSale.nftId;

        INFT Nft = INFT(currentSale.nftContract);
        (address artistAddress, uint256 royalties) = Nft.royaltyInfo(
            nftId,
            amountToBuy * currentSale.price
        );

        if (currency != ETH) {
            IERC20 Token = IERC20(currency);

            Token.safeTransferFrom(
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
            emit BalanceUpdated(
                msg.sender,
                currency,
                claimableFunds[msg.sender][currency]
            );
        }

        // system fee
        (address systemWallet, uint256 fee) = Registry.feeInfo(
            amountToBuy * currentSale.price
        );
        claimableFunds[systemWallet][currency] += fee;
        emit BalanceUpdated(
            systemWallet,
            currency,
            claimableFunds[systemWallet][currency]
        );

        // artist royalty if artist isn't the seller
        if (currentSale.owner != artistAddress) {
            claimableFunds[artistAddress][currency] += royalties;
            emit BalanceUpdated(
                artistAddress,
                currency,
                claimableFunds[artistAddress][currency]
            );
        } else {
            // since the artist is the seller
            royalties = 0;
        }

        // seller gains
        claimableFunds[currentSale.owner][currency] +=
            (amountToBuy * currentSale.price) -
            fee -
            royalties;
        emit BalanceUpdated(
            currentSale.owner,
            currency,
            claimableFunds[currentSale.owner][currency]
        );

        sales[saleId].purchased += amountToBuy;
        purchased[saleId][msg.sender] += amountToBuy;

        Nft.safeTransferFrom(
            address(this),
            recipient,
            currentSale.nftId,
            amountToBuy,
            ""
        );

        emit Purchase(saleId, msg.sender, recipient, amountToBuy);

        return true;
    }

    /// @notice Allows seller to reclaim unsold NFTs
    /// @dev sale must be cancelled or ended
    /// @param saleId the index of the sale to claim from
    function claimNfts(uint256 saleId) external {
        bytes32 status = keccak256(bytes(getSaleStatus(saleId)));
        require(
            status == keccak256(bytes("CANCELLED")) ||
                status == keccak256(bytes("ENDED")),
            "Cannot claim before sale closes"
        );
        require(msg.sender == sales[saleId].owner, "Only nft owner can claim");
        require(
            sales[saleId].purchased < sales[saleId].amount,
            "Stock already sold or claimed"
        );

        uint256 stock = sales[saleId].amount - sales[saleId].purchased;
        sales[saleId].purchased = sales[saleId].amount;
        INFT Nft = INFT(sales[saleId].nftContract);
        Nft.safeTransferFrom(
            address(this),
            sales[saleId].owner,
            sales[saleId].nftId,
            stock,
            ""
        );

        emit NFTsReclaimed(saleId, msg.sender, stock);
    }

    /// @notice Withdraws in-contract balance of a particular token
    /// @dev use address(0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa) for ETH
    function claimFunds(address tokenContract) external {
        require(
            claimableFunds[msg.sender][tokenContract] > 0,
            "Nothing to claim"
        );
        uint256 payout = claimableFunds[msg.sender][tokenContract];
        if (tokenContract != ETH) {
            IERC20 Token = IERC20(tokenContract);
            claimableFunds[msg.sender][tokenContract] = 0;
            Token.safeTransfer(msg.sender, payout);
        } else {
            claimableFunds[msg.sender][tokenContract] = 0;
            (bool success, ) = msg.sender.call{value: payout}("");
            require(success, "ETH payout failed");
        }
        emit BalanceUpdated(
            msg.sender,
            tokenContract,
            claimableFunds[msg.sender][tokenContract] = 0
        );
    }

    /// @notice Allows contract owner or seller to cancel a pending or active sale
    /// @param saleId the index of the sale to cancel
    function cancelSale(uint256 saleId) external {
        require(
            msg.sender == sales[saleId].owner || msg.sender == owner(),
            "Only owner or sale creator"
        );
        require(
            keccak256(bytes(getSaleStatus(saleId))) ==
                keccak256(bytes("ACTIVE")) ||
                keccak256(bytes(getSaleStatus(saleId))) ==
                keccak256(bytes("PENDING")),
            "Must be active or pending"
        );
        cancelled[saleId] = true;

        emit SaleCancelled(saleId);
    }

    /// @notice allows contract to receive ERC1155 NFTs
    function onERC1155Received() external pure returns (bytes4) {
        // 0xf23a6e61 = bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)")
        return 0xf23a6e61;
    }
}
