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

    function safeMint(address to, uint256 tokenId) external onlyOwner {
        _safeMint(to, tokenId, "");
    }
}

contract NFT1155 is ERC1155, ERC2981, Ownable {
    constructor() ERC1155("baseURI") {}
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
    Marketplace market;
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
        registry = new Registry();
        market = new Marketplace(address(registry));
        nft721 = new NFT721();
        nft1155 = new NFT1155();
        mockCurrency = new MockCurrency();
    }

    function testCreateSaleERC721() public {
        nft721.safeMint(addressA, 1);
        market.createSale({
            isERC721: true,
            nftAddress: address(nft721),
            nftId: 1,
            amount: 1,
            startTime: block.timestamp,
            endTime: block.timestamp + 3 days,
            price: 100,
            currency: address(mockCurrency)
        });
    }
}
