// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract NFT721 is ERC721, ERC2981, Ownable {
    constructor() ERC721("NFT721", "NFT721") {}

    function safeMint(
        address to,
        uint256 tokenId,
        bytes memory data
    ) external onlyOwner {
        _safeMint(to, tokenId, "");
    }
}

contract NFT1155 is ERC1155, ERC2981, Ownable {
    constructor() ERC1155("baseURI") {}

    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external onlyOwner {
        _mint(to, id, amount, data);
    }

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public onlyOwner {
        _mintBatch(to, ids, amounts, data);
    }
}
}
