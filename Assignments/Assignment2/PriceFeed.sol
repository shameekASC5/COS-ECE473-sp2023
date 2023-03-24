// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IPriceFeed.sol";

contract PriceFeed is IPriceFeed {
    AggregatorV3Interface internal priceFeed;
    // BNB / USD: 0x7b219F57a8e9C7303204Af681e9fA69d17ef626f
    constructor() {
        priceFeed = AggregatorV3Interface(
            0x7b219F57a8e9C7303204Af681e9fA69d17ef626f
        );
    }
    function getLatestPrice() external view returns (int, uint) {
        (
            uint80 roundID ,
            int price,
            uint startedAt,
            uint updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        return (price, updatedAt);
    }
}