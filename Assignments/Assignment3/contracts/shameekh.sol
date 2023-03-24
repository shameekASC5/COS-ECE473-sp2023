// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/IMint.sol";
import "./sAsset.sol";
import "./EUSD.sol";

contract Mint is Ownable, IMint{

    struct Asset {
        address token;
        uint minCollateralRatio;
        address priceFeed;
    }

    struct Position {
        uint idx;
        address owner;
        uint collateralAmount;
        address assetToken;
        uint assetAmount;
    }

    mapping(address => Asset) _assetMap;
    uint _currentPositionIndex;
    mapping(uint => Position) _idxPositionMap;
    address public collateralToken;
    

    constructor(address collateral) {
        collateralToken = collateral;
    }

    function registerAsset(address assetToken, uint minCollateralRatio, address priceFeed) external override onlyOwner {
        require(assetToken != address(0), "Invalid assetToken address");
        require(minCollateralRatio >= 1, "minCollateralRatio must be greater than 100%");
        require(_assetMap[assetToken].token == address(0), "Asset was already registered");
        
        _assetMap[assetToken] = Asset(assetToken, minCollateralRatio, priceFeed);
    }

    function getPosition(uint positionIndex) external view returns (address, uint, address, uint) {
        require(positionIndex < _currentPositionIndex, "Invalid index");
        Position storage position = _idxPositionMap[positionIndex];
        return (position.owner, position.collateralAmount, position.assetToken, position.assetAmount);
    }

    function getMintAmount(uint collateralAmount, address assetToken, uint collateralRatio) public view returns (uint) {
        Asset storage asset = _assetMap[assetToken];
        (int relativeAssetPrice, ) = IPriceFeed(asset.priceFeed).getLatestPrice();
        uint8 decimal = sAsset(assetToken).decimals();
        uint mintAmount = collateralAmount * (10 ** uint256(decimal)) / uint(relativeAssetPrice) / collateralRatio ;
        return mintAmount;
    }

    function checkRegistered(address assetToken) public view returns (bool) {
        return _assetMap[assetToken].token == assetToken;
    }

    // open a CDP by sending EUSD as collateral and mint sAsset
    function openPosition(uint collateralAmount, address assetToken, uint collateralRatio) external override {
        // Make sure the asset is registered and the input collateral ratio is not less than the asset MCR
        require(checkRegistered(assetToken) == true, "Asset was not registered");
        require(collateralRatio >= _assetMap[assetToken].minCollateralRatio, "input collateral ratio must not be less than the asset minCollateralRatio");
        // transfer collateralAmount EUSD tokens from message sender to the contract
        ERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
        // calculate the number of minted tokens to send to the message sender
        uint tokens_to_send = this.getMintAmount(collateralAmount, assetToken, collateralRatio);
        // mint sAsset
        sAsset(assetToken).mint(msg.sender, tokens_to_send);
        // add new position to mapping
        _idxPositionMap[_currentPositionIndex] = Position(_currentPositionIndex, msg.sender, collateralAmount, assetToken, tokens_to_send);
        _currentPositionIndex = _currentPositionIndex + 1;
    }
    // Close a CDP to withdraw EUSD and burn sAsset
    function closePosition(uint positionIndex) external override {
        require(_idxPositionMap[positionIndex].owner == msg.sender, "Only the owner of each respective position should be allowed to close it.");
        (
            address owner,
            uint collateralAmount,
            address assetToken,
            uint assetAmount
        ) = this.getPosition(positionIndex);
        // Burn all sAsset tokens 
        sAsset(assetToken).burn(owner, assetAmount);
        // transfer EUSD tokens locked in the position to the position owner
        ERC20(collateralToken).transfer(owner, collateralAmount);
        // Finally, delete the position at the given index.
        delete _idxPositionMap[positionIndex];
    }
    
    // deposit EUSD to an existing CDP
    function deposit(uint positionIndex, uint collateralAmount) external override {
        // Make sure the message sender owns the position
        require(_idxPositionMap[positionIndex].owner == msg.sender, "Only the owner of each respective position should be allowed to close it.");
        // transfer deposited tokens from the sender to the contract.
        ERC20(collateralToken).transferFrom(_idxPositionMap[positionIndex].owner, address(this), collateralAmount);
        // Add collateral amount of the position at the given index. 
        _idxPositionMap[positionIndex].collateralAmount = _idxPositionMap[positionIndex].collateralAmount + collateralAmount;
    }
    // withdraw EUSD from an existing CDP (withdraw)
    function withdraw(uint positionIndex, uint withdrawAmount) external override {
        // Make sure the message sender owns the position
        require(_idxPositionMap[positionIndex].owner == msg.sender, "Only the owner of each respective position should be allowed to withdraw from it.");
        uint new_collateralAmount = _idxPositionMap[positionIndex].collateralAmount - withdrawAmount;
        address derivative_asset = _idxPositionMap[positionIndex].assetToken;
        // Make sure the collateral ratio won't go below the MCR. 
        require(new_collateralAmount/_idxPositionMap[positionIndex].assetAmount >= _assetMap[derivative_asset].minCollateralRatio, "withdrawal amount must not decrease collateral ratio below minimum.");
        // Withdraw collateral tokens from the position at the given index. 
        _idxPositionMap[positionIndex].collateralAmount = new_collateralAmount;
        // Transfer withdrawn tokens from the contract to the sender.
        ERC20(collateralToken).transfer(_idxPositionMap[positionIndex].owner, withdrawAmount);
    }
    // mint sAsset from an existing CDP (mint)
    function mint(uint positionIndex, uint mintAmount) external override {
        // Make sure the message sender owns the position
        require(_idxPositionMap[positionIndex].owner == msg.sender, "Only the owner of each respective position should be allowed to mint from it.");
        uint new_assetAmount = _idxPositionMap[positionIndex].assetAmount + mintAmount;
        address derivative_asset = _idxPositionMap[positionIndex].assetToken;
        // Make sure the collateral ratio won't go below the MCR.
        require(_idxPositionMap[positionIndex].collateralAmount/new_assetAmount >= _assetMap[derivative_asset].minCollateralRatio, "withdrawal amount must not decrease collateral ratio below minimum.");
        // Mint more asset tokens from the position at the given index.
        sAsset(derivative_asset).mint(_idxPositionMap[positionIndex].owner, mintAmount);
        // update the position
        _idxPositionMap[positionIndex].assetAmount = new_assetAmount;
    }
    // return and burn sAsset to an existing CDP (burn)
    function burn(uint positionIndex, uint burnAmount) external override {
        // Make sure the message sender owns the position.
        require(_idxPositionMap[positionIndex].owner == msg.sender, "Only the owner of each respective position should be allowed to burn it.");
        uint new_assetAmount = _idxPositionMap[positionIndex].assetAmount - burnAmount;
        address derivative_asset = _idxPositionMap[positionIndex].assetToken;
        // Contract burns the given amount of asset tokens in the position. 
        if (burnAmount > _idxPositionMap[positionIndex].assetAmount) {
            // burn all assets and set assetAmount to 0
            sAsset(derivative_asset).burn(_idxPositionMap[positionIndex].owner, _idxPositionMap[positionIndex].assetAmount);
            _idxPositionMap[positionIndex].assetAmount = 0;
        }
        else {
            // otherwise burn the amount requested
            sAsset(derivative_asset).burn(_idxPositionMap[positionIndex].owner, burnAmount);
            // update the position
            _idxPositionMap[positionIndex].assetAmount = _idxPositionMap[positionIndex].assetAmount - burnAmount;
        }
    }

}