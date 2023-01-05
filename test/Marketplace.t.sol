// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Registry.sol";
import "../src/Marketplace.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract NFT721 is ERC721, ERC2981, Ownable {
    constructor() ERC721("NFT721", "NFT721") {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC2981, ERC721)
        returns (bool)
    {
        return
            ERC2981.supportsInterface(interfaceId) ||
            ERC721.supportsInterface(interfaceId);
    }

    function safeMint(address to, uint256 tokenId) external onlyOwner {
        _safeMint(to, tokenId, "");
    }
}

contract NFT1155 is ERC1155, ERC2981, Ownable {
    constructor() ERC1155("baseURI") {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC2981)
        returns (bool)
    {
        return
            ERC2981.supportsInterface(interfaceId) ||
            ERC1155.supportsInterface(interfaceId);
    }

    function mint(
        address to,
        uint256 id,
        uint256 amount
    ) external onlyOwner {
        _mint(to, id, amount, "");
    }

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts
    ) public onlyOwner {
        _mintBatch(to, ids, amounts, "");
    }
}

contract MockCurrency is ERC20 {
    constructor() ERC20("Mock Currency", "MC") {
        _mint(address(this), 100_000 * 10**18);
    }
}

contract MarketplaceTest is Test {
    Registry registry;
    Marketplace marketPlace;
    NFT721 nft721;
    NFT1155 nft1155;
    MockCurrency mockCurrency;

    address addressA = vm.addr(1);
    address addressB = vm.addr(2);
    address addressC = vm.addr(3);
    address addressD = vm.addr(4);

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
    event ClaimSaleNFTs(
        uint256 indexed id,
        address indexed owner,
        uint256 indexed amount
    );
    event ClaimFunds(
        address indexed accountOf,
        address indexed tokenAddress,
        uint256 indexed newBalance
    );

    function setUp() public {
        // create contract instance
        registry = new Registry();
        marketPlace = new Marketplace(address(registry));
        nft721 = new NFT721();
        nft1155 = new NFT1155();
        mockCurrency = new MockCurrency();

        // approve nft contracts and currency
        registry.setContractStatus(address(marketPlace), true);
        registry.setContractStatus(address(nft721), true);
        registry.setContractStatus(address(nft1155), true);
        registry.setCurrencyStatus(address(mockCurrency), true);
    }

    function testCreateSaleERC721() public {
        nft721.safeMint(addressA, 1);
        vm.startPrank(addressA);
        nft721.approve(address(marketPlace), 1);

        // emit the SaleCreated event correctly
        vm.expectEmit(true, true, true, true);
        emit SaleCreated(1, address(nft721), 1);

        marketPlace.createSale({
            isERC721: true,
            nftAddress: address(nft721),
            nftId: 1,
            amount: 1,
            startTime: block.timestamp,
            endTime: block.timestamp + 3 days,
            price: 100,
            currency: address(mockCurrency)
        });
        vm.stopPrank();

        // save sale info correctly
        (
            bool isERC721,
            address nftAddress,
            uint256 nftId,
            address owner,
            uint256 amount,
            uint256 purchased,
            uint256 startTime,
            uint256 endTime,
            uint256 price,
            address currency
        ) = marketPlace.sales(1);

        assertEq(isERC721, true);
        assertEq(nftAddress, address(nft721));
        assertEq(nftId, 1);
        assertEq(owner, address(addressA));
        assertEq(amount, 1);
        assertEq(purchased, 0);
        assertEq(startTime, block.timestamp);
        assertEq(endTime, block.timestamp + 3 days);
        assertEq(price, 100);
        assertEq(currency, address(mockCurrency));

        // transfer nft to the platform
        assertEq(nft721.balanceOf(address(marketPlace)), 1);
        assertEq(nft721.ownerOf(1), address(marketPlace));
        assertEq(nft721.balanceOf(address(addressA)), 0);
    }

    function testCreateSaleERC1155() public {
        nft1155.mint(addressB, 1, 10);
        vm.startPrank(addressB);
        nft1155.setApprovalForAll(address(marketPlace), true);

        // emit the SaleCreated event correctly
        vm.expectEmit(true, true, true, true);
        emit SaleCreated(1, address(nft1155), 1);

        marketPlace.createSale({
            isERC721: false,
            nftAddress: address(nft1155),
            nftId: 1,
            amount: 5,
            startTime: block.timestamp,
            endTime: block.timestamp + 4 days,
            price: 200,
            currency: address(mockCurrency)
        });
        vm.stopPrank();

        // save sale info correctly
        (
            bool isERC721,
            address nftAddress,
            uint256 nftId,
            address owner,
            uint256 amount,
            uint256 purchased,
            uint256 startTime,
            uint256 endTime,
            uint256 price,
            address currency
        ) = marketPlace.sales(1);

        assertEq(isERC721, false);
        assertEq(nftAddress, address(nft1155));
        assertEq(nftId, 1);
        assertEq(owner, address(addressB));
        assertEq(amount, 5);
        assertEq(purchased, 0);
        assertEq(startTime, block.timestamp);
        assertEq(endTime, block.timestamp + 4 days);
        assertEq(price, 200);
        assertEq(currency, address(mockCurrency));

        // transfer nft to the platform
        assertEq(nft1155.balanceOf(address(marketPlace), 1), 5);
        assertEq(nft1155.balanceOf(address(addressB), 1), 5);
    }
}