// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract NFTF is ERC721, ERC721Enumerable, Ownable, ReentrancyGuard {
    using Strings for uint256;

    enum RarityType { Bronze, Silver, Gold }

    struct RarityInfo {
        uint256 maxSupply;
        uint256 currentSupply;
        string metadataURI;
    }

    uint256 public constant MAX_TOTAL_SUPPLY = 1000;
    uint256 public constant BRONZE_MAX_SUPPLY = 600;
    uint256 public constant SILVER_MAX_SUPPLY = 300;
    uint256 public constant GOLD_MAX_SUPPLY = 100;
    uint256 public constant INITIAL_MINT_PRICE = 0.05 ether;
    uint256 public constant MAX_MINTS_PER_TX = 5;

    uint256 public maxMintsPerAddress;
    uint256 public mintPrice;
    bool public paused;
    bool public goPublic;
    mapping(RarityType => RarityInfo) public rarityTypes;
    mapping(uint256 => RarityType) private _tokenToRarity;
    mapping(address => uint256) public mintsPerAddress;
    mapping(address => bool) public whitelisted;
    mapping(address => uint256) public howMany;
    string private _baseMetadataURI;
    string private _baseExtension = ".json";
    uint256 private _tokenIdCounter;

    event NFTMinted(address indexed to, uint256 tokenId, RarityType rarityType);
    event MintPriceUpdated(uint256 newPrice);
    event Paused(bool isPaused);
    event MetadataURIUpdated(RarityType rarityType, string newURI);
    event MaxMintsPerAddressUpdated(uint256 newMax);
    event MintedIds(address indexed to, uint256[] ids);
    event GoPublicSet(bool isPublic);

    constructor(
        address initialOwner,
        string memory name,
        string memory symbol,
        string memory initBaseURI
    ) ERC721(name, symbol) Ownable(initialOwner) {
        require(initialOwner != address(0), "Invalid owner address");
        require(bytes(name).length > 0, "Name cannot be empty");
        require(bytes(symbol).length > 0, "Symbol cannot be empty");
        require(bytes(initBaseURI).length > 0, "Base URI cannot be empty");

        _baseMetadataURI = initBaseURI;
        mintPrice = INITIAL_MINT_PRICE;
        maxMintsPerAddress = 5;
        _tokenIdCounter = 1;
        paused = false;
        goPublic = false;

        rarityTypes[RarityType.Bronze] = RarityInfo({
            maxSupply: BRONZE_MAX_SUPPLY,
            currentSupply: 0,
            metadataURI: string(abi.encodePacked(initBaseURI, "1.json"))
        });
        rarityTypes[RarityType.Silver] = RarityInfo({
            maxSupply: SILVER_MAX_SUPPLY,
            currentSupply: 0,
            metadataURI: string(abi.encodePacked(initBaseURI, "2.json"))
        });
        rarityTypes[RarityType.Gold] = RarityInfo({
            maxSupply: GOLD_MAX_SUPPLY,
            currentSupply: 0,
            metadataURI: string(abi.encodePacked(initBaseURI, "3.json"))
        });
    }

    // Dapp compatibility: mint(uint256) for public minting
    function mint(uint256 quantity) public payable whenNotPaused returns (uint256[] memory) {
        return mintNFT(msg.sender, quantity);
    }

    // Dapp compatibility: maxSupply()
    function maxSupply() public pure returns (uint256) {
        return MAX_TOTAL_SUPPLY;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseMetadataURI;
    }

    modifier whenNotPaused() {
        require(!paused, "Minting is paused");
        _;
    }

    function mintNFT(address to, uint256 quantity) public payable whenNotPaused nonReentrant returns (uint256[] memory) {
        require(goPublic, "Not publicly live yet");
        require(to != address(0), "Cannot mint to zero address");
        require(to != address(this), "Cannot mint to contract address");
        require(quantity > 0 && quantity <= MAX_MINTS_PER_TX, "Quantity must be between 1 and 5");
        require(msg.value >= mintPrice * quantity, "Insufficient ETH");
        require(totalSupply() + quantity <= MAX_TOTAL_SUPPLY, "Exceeds max total supply");
        require(mintsPerAddress[msg.sender] + quantity <= maxMintsPerAddress, "Exceeds max mints per address");
        require(_hasAvailableNFTs(), "No NFTs available for minting");

        uint256[] memory tokenIds = new uint256[](quantity);

        for (uint256 i = 0; i < quantity; i++) {
            RarityType selectedRarity = _getRandomRarityType();
            uint256 tokenId = _tokenIdCounter;
            _tokenIdCounter++;

            rarityTypes[selectedRarity].currentSupply++;
            _tokenToRarity[tokenId] = selectedRarity;
            tokenIds[i] = tokenId;

            _safeMint(to, tokenId);
            emit NFTMinted(to, tokenId, selectedRarity);
        }

        mintsPerAddress[msg.sender] += quantity;

        if (msg.value > mintPrice * quantity) {
            uint256 refundAmount = msg.value - mintPrice * quantity;
            uint256 balanceBefore = address(this).balance;
            (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
            require(success, "Refund failed");
            require(address(this).balance == balanceBefore - refundAmount, "Balance mismatch after refund");
        }

        emit MintedIds(to, tokenIds);
        return tokenIds;
    }

    function whiteMint() external whenNotPaused nonReentrant returns (uint256[] memory) {
        require(whitelisted[msg.sender], "Not whitelisted");
        require(howMany[msg.sender] > 0, "No whitelist mints remaining");
        require(totalSupply() + 1 <= MAX_TOTAL_SUPPLY, "Max supply reached");
        require(_hasAvailableNFTs(), "No NFTs available for minting");

        uint256[] memory tokenIds = new uint256[](1);
        RarityType selectedRarity = _getRandomRarityType();
        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;

        rarityTypes[selectedRarity].currentSupply++;
        _tokenToRarity[tokenId] = selectedRarity;
        tokenIds[0] = tokenId;

        _safeMint(msg.sender, tokenId);
        howMany[msg.sender] -= 1;
        if (howMany[msg.sender] == 0) {
            whitelisted[msg.sender] = false;
        }
        mintsPerAddress[msg.sender] += 1;

        emit NFTMinted(msg.sender, tokenId, selectedRarity);
        emit MintedIds(msg.sender, tokenIds);
        return tokenIds;
    }

    function ownerMint(address to, uint256 quantity) external onlyOwner returns (uint256[] memory) {
        require(to != address(0), "Cannot mint to zero address");
        require(quantity > 0 && quantity <= MAX_MINTS_PER_TX, "Quantity must be between 1 and 5");
        require(totalSupply() + quantity <= MAX_TOTAL_SUPPLY, "Exceeds max total supply");
        require(_hasAvailableNFTs(), "No NFTs available for minting");

        uint256[] memory tokenIds = new uint256[](quantity);

        for (uint256 i = 0; i < quantity; i++) {
            RarityType selectedRarity = _getRandomRarityType();
            uint256 tokenId = _tokenIdCounter;
            _tokenIdCounter++;

            rarityTypes[selectedRarity].currentSupply++;
            _tokenToRarity[tokenId] = selectedRarity;
            tokenIds[i] = tokenId;

            _safeMint(to, tokenId);
            emit NFTMinted(to, tokenId, selectedRarity);
        }

        emit MintedIds(to, tokenIds);
        return tokenIds;
    }

    function walletOfOwner(address owner) public view returns (uint256[] memory) {
        uint256 ownerTokenCount = balanceOf(owner);
        uint256[] memory tokenIds = new uint256[](ownerTokenCount);
        for (uint256 i; i < ownerTokenCount; i++) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }
        return tokenIds;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(ownerOf(tokenId) != address(0), "Token does not exist");
        RarityType rarityType = _tokenToRarity[tokenId];
        string memory rarityURI = rarityTypes[rarityType].metadataURI;
        if (bytes(rarityURI).length > 0) {
            return rarityURI;
        }
        return bytes(_baseMetadataURI).length > 0
            ? string(abi.encodePacked(_baseMetadataURI, tokenId.toString(), _baseExtension))
            : "";
    }

    function updateMetadataURI(RarityType rarityType, string memory newURI) public onlyOwner {
        require(bytes(newURI).length > 0, "Metadata URI cannot be empty");
        rarityTypes[rarityType].metadataURI = newURI;
        emit MetadataURIUpdated(rarityType, newURI);
    }

    function setBaseURI(string memory newBaseURI) public onlyOwner {
        require(bytes(newBaseURI).length > 0, "Base URI cannot be empty");
        _baseMetadataURI = newBaseURI;
    }

    function setMaxMintsPerAddress(uint256 newMax) public onlyOwner {
        require(newMax > 0, "Max mints per address must be greater than zero");
        maxMintsPerAddress = newMax;
        emit MaxMintsPerAddressUpdated(newMax);
    }

    function setMintPrice(uint256 newPrice) public onlyOwner {
        require(newPrice > 0, "Mint price must be greater than zero");
        mintPrice = newPrice;
        emit MintPriceUpdated(newPrice);
    }

    function setGoPublic() public onlyOwner {
        require(!goPublic, "Already public");
        goPublic = true;
        emit GoPublicSet(true);
    }

    function pause() public onlyOwner {
        require(!paused, "Already paused");
        paused = true;
        emit Paused(true);
    }

    function unpause() public onlyOwner {
        require(paused, "Already unpaused");
        paused = false;
        emit Paused(false);
    }

    function addFreeWhitelistUserOrAddMoreSpots(address user, uint256 howManySpots) public onlyOwner {
        require(user != address(0), "Invalid user address");
        whitelisted[user] = true;
        howMany[user] += howManySpots;
    }

    function removeFreeWhitelistUser(address user) public onlyOwner {
        require(whitelisted[user], "User not whitelisted");
        whitelisted[user] = false;
        howMany[user] = 0;
    }

    function withdraw() public onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "Withdrawal failed");
    }

    function getRarityType(uint256 tokenId) public view returns (RarityType) {
        require(ownerOf(tokenId) != address(0), "Token does not exist");
        return _tokenToRarity[tokenId];
    }

    function _hasAvailableNFTs() private view returns (bool) {
        for (uint256 i = 0; i < 3; i++) {
            RarityType rarityType = RarityType(i);
            if (rarityTypes[rarityType].currentSupply < rarityTypes[rarityType].maxSupply) {
                return true;
            }
        }
        return false;
    }

    function _getRandomRarityType() private view returns (RarityType) {
        uint256 totalAvailable = 0;
        for (uint256 i = 0; i < 3; i++) {
            RarityType rarityType = RarityType(i);
            totalAvailable += (rarityTypes[rarityType].maxSupply - rarityTypes[rarityType].currentSupply);
        }
        require(totalAvailable > 0, "No NFTs available");

        uint256 random = uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender, _tokenIdCounter))) % totalAvailable;
        uint256 currentSum = 0;

        for (uint256 i = 0; i < 3; i++) {
            RarityType rarityType = RarityType(i);
            uint256 available = rarityTypes[rarityType].maxSupply - rarityTypes[rarityType].currentSupply;
            if (random < currentSum + available) {
                return rarityType;
            }
            currentSum += available;
        }
        revert("Random selection failed");
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
} 