// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice Simple free-mint NFT for testing Axon vault NFT support.
contract TestNFT is ERC721 {
    uint256 private _nextTokenId;

    constructor() ERC721("Axon Test NFT", "AXNFT") {}

    /// @notice Mint an NFT to any address. No restrictions — testnet only.
    function mint(address to) external returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
    }
}
