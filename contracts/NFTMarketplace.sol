// contracts/NFTMarketplace.sol
// SPDX-License-Identifier: MIT OR Apache-2.0
// 
// adapt and edit from (Nader Dabit): 
//    https://github.com/dabit3/polygon-ethereum-nextjs-marketplace/blob/main/contracts/Market.sol

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "hardhat/console.sol";

contract NFTMarketplace is ReentrancyGuard {
  using Counters for Counters.Counter;
  Counters.Counter private _itemCounter;//start from 1
  Counters.Counter private _itemSoldCounter;

  address payable public marketowner;
  uint256 public listingFee = 0.025 ether;

  // 状态 上架，卖出，主动删除或直接取消授权
  enum State { Created, Release, Inactive }

  // 定义商品Item
  struct MarketItem {
    uint id;
    address nftContract;
    uint256 tokenId;
    address payable seller;
    address payable buyer;
    uint256 price;
    State state;
  }

  mapping(uint256 => MarketItem) private marketItems;

  // 上架售出
  event MarketItemCreated (
    uint indexed id,
    address indexed nftContract,
    uint256 indexed tokenId,
    address seller,
    address buyer,
    uint256 price,
    State state
  );

  event MarketItemSold (
    uint indexed id,
    address indexed nftContract,
    uint256 indexed tokenId,
    address seller,
    address buyer,
    uint256 price,
    State state
  );

  constructor() {
    marketowner = payable(msg.sender);
  }

  /**
   * @dev Returns the listing fee of the marketplace
   */
  function getListingFee() public view returns (uint256) {
    return listingFee;
  }
  
  /**
   * @dev create a MarketItem for NFT sale on the marketplace.
   * 
   * List an NFT. 上架NFT item
   */
  function createMarketItem(
    address nftContract,
    uint256 tokenId,
    uint256 price
  ) public payable nonReentrant {

    require(price > 0, "Price must be at least 1 wei");
    require(msg.value == listingFee, "Fee must be equal to listing fee");

    _itemCounter.increment();
    uint256 id = _itemCounter.current();
  
    marketItems[id] =  MarketItem(
      id,
      nftContract,
      tokenId,
      payable(msg.sender),
      payable(address(0)),
      price,
      State.Created
    );

    require(IERC721(nftContract).getApproved(tokenId) == address(this), "NFT must be approved to market");

    // change to approve mechanism from the original direct transfer to market
    // IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);

    // emit一个事件，表明商品已经上架了，并把参数传递过去，可供前端使用
    emit MarketItemCreated(
      id,
      nftContract,
      tokenId,
      msg.sender,
      address(0),
      price,
      State.Created
    );
  }

  /**
   * @dev delete a MarketItem from the marketplace.
   * 
   * de-List an NFT. 下架 NFT
   * 
   * todo ERC721.approve can't work properly!! comment out
   */
  function deleteMarketItem(uint256 itemId) public nonReentrant {
    require(itemId <= _itemCounter.current(), "id must <= item count");
    require(marketItems[itemId].state == State.Created, "item must be on market");
    MarketItem storage item = marketItems[itemId]; // should use storage!!

    require(IERC721(item.nftContract).ownerOf(item.tokenId) == msg.sender, "must be the owner");
    // 判断是否有授权
    require(IERC721(item.nftContract).getApproved(item.tokenId) == address(this), "NFT must be approved to market");

    // 更改商品状态
    item.state = State.Inactive;

    // emit 一个事件
    emit MarketItemSold(
      itemId,
      item.nftContract,
      item.tokenId,
      item.seller,
      address(0),
      0,
      State.Inactive
    );

  }

  /**
   * @dev (buyer) buy a MarketItem from the marketplace.
   * Transfers ownership of the item, as well as funds
   * NFT:         seller    -> buyer
   * value:       buyer     -> seller
   * listingFee:  contract  -> marketowner
   * 购买 NFT item
   */
  function createMarketSale(
    address nftContract,
    uint256 id
  ) public payable nonReentrant {

    MarketItem storage item = marketItems[id]; //should use storge!!!!
    uint price = item.price;
    uint tokenId = item.tokenId;

    // 判断要有付钱
    require(msg.value == price, "Please submit the asking price");
    // 判断当前商品是否有授权
    require(IERC721(nftContract).getApproved(tokenId) == address(this), "NFT must be approved to market");

    // 商品信息更改
    item.buyer = payable(msg.sender);
    item.state = State.Release;
    _itemSoldCounter.increment();    

    // 将nft转让
    IERC721(nftContract).transferFrom(item.seller, msg.sender, tokenId);
    // 把listingFee转给nft的拥有者 建议使用safeTransferFrom
    payable(marketowner).transfer(listingFee);
    // 把商品的钱转给卖家
    item.seller.transfer(msg.value);

    emit MarketItemSold(
      id,
      nftContract,
      tokenId,
      item.seller,
      msg.sender,
      price,
      State.Release
    );    
  }

  /**
   * @dev Returns all unsold market items 查询函数
   * condition: 
   *  1) state == Created
   *  2) buyer = 0x0
   *  3) still have approve
   */
  function fetchActiveItems() public view returns (MarketItem[] memory) {
    return fetchHepler(FetchOperator.ActiveItems);
  }

  /**
   * @dev Returns only market items a user has purchased
   * todo pagination
   */
  function fetchMyPurchasedItems() public view returns (MarketItem[] memory) {
    return fetchHepler(FetchOperator.MyPurchasedItems);
  }

  /**
   * @dev Returns only market items a user has created
   * todo pagination
  */
  function fetchMyCreatedItems() public view returns (MarketItem[] memory) {
    return fetchHepler(FetchOperator.MyCreatedItems);
  }

  enum FetchOperator { ActiveItems, MyPurchasedItems, MyCreatedItems}

  /**
   * @dev fetch helper
   * todo pagination   
   */
   function fetchHepler(FetchOperator _op) private view returns (MarketItem[] memory) {     
    uint total = _itemCounter.current();

    uint itemCount = 0;
    for (uint i = 1; i <= total; i++) {
      if (isCondition(marketItems[i], _op)) {
        itemCount ++;
      }
    }

    uint index = 0;
    MarketItem[] memory items = new MarketItem[](itemCount);
    for (uint i = 1; i <= total; i++) {
      if (isCondition(marketItems[i], _op)) {
        items[index] = marketItems[i];
        index ++;
      }
    }
    return items;
  } 

  /**
   * @dev helper to build condition
   *
   * todo should reduce duplicate contract call here
   * (IERC721(item.nftContract).getApproved(item.tokenId) called in two loop
   */
  function isCondition(MarketItem memory item, FetchOperator _op) private view returns (bool){
    if(_op == FetchOperator.MyCreatedItems){ 
      return 
        (item.seller == msg.sender
          && item.state != State.Inactive
        )? true
         : false;
    }else if(_op == FetchOperator.MyPurchasedItems){
      return
        (item.buyer ==  msg.sender) ? true: false;
    }else if(_op == FetchOperator.ActiveItems){
      return 
        (item.buyer == address(0) 
          && item.state == State.Created
          && (IERC721(item.nftContract).getApproved(item.tokenId) == address(this))
        )? true
         : false;
    }else{
      return false;
    }
  }

}
