// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { INonfungiblePositionManager, IERC721Receiver, IERC20, IWETH9 } from "./Interfaces.sol";

/**
 * @title GuldLocker
 * @notice Permanent custodian for the fair-launch $GULD/WETH LP position. The LP
 *         NFT is transferred in and registered; liquidity is then **locked forever**
 *         (there is no withdraw/decreaseLiquidity path), while the position's accrued
 *         trading fees can be swept — in full — to the treasury (WETH side unwrapped
 *         to ETH, the paired token sent as-is). Makes the launch liquidity
 *         un-ruggable.
 */
contract GuldLocker is IERC721Receiver {
    address public owner;
    address public treasury;
    address public immutable positionManager;
    address public immutable weth;

    uint256 public lpId;
    bool public lpSet;

    bool private _entered;
    modifier nonReentrant() { require(!_entered, "re"); _entered = true; _; _entered = false; }
    modifier onlyOwner() { require(msg.sender == owner, "o"); _; }

    event LpSet(uint256 indexed tokenId);
    event FeesClaimed(uint256 indexed tokenId, uint256 ethToTreasury, uint256 tokenToTreasury, address token);
    event TreasurySet(address treasury);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address positionManager_, address weth_, address treasury_) {
        require(positionManager_ != address(0) && weth_ != address(0) && treasury_ != address(0), "zero");
        owner = msg.sender;
        positionManager = positionManager_;
        weth = weth_;
        treasury = treasury_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// Register the LP NFT once it has been transferred into this locker. Liquidity
    /// stays locked forever — only fees are ever claimable.
    function setLp(uint256 tokenId) external onlyOwner {
        require(INonfungiblePositionManager(positionManager).ownerOf(tokenId) == address(this), "not-held");
        lpId = tokenId;
        lpSet = true;
        emit LpSet(tokenId);
    }

    /// Sweep the position's accrued trading fees to the treasury. Permissionless —
    /// funds can only ever go to `treasury`, never liquidity.
    function claimFees() external nonReentrant {
        require(lpSet, "no-lp");
        uint256 tokenId = lpId;
        (uint256 a0, uint256 a1) = INonfungiblePositionManager(positionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this),
                amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        (, , address token0, address token1, , , , , , , , ) =
            INonfungiblePositionManager(positionManager).positions(tokenId);
        uint256 wethFees = token0 == weth ? a0 : a1;
        uint256 tokenFees = token0 == weth ? a1 : a0;
        address token = token0 == weth ? token1 : token0;

        if (wethFees > 0) { IWETH9(weth).withdraw(wethFees); (bool ok, ) = treasury.call{value: wethFees}(""); require(ok, "eth"); }
        if (tokenFees > 0) { require(IERC20(token).transfer(treasury, tokenFees), "tok"); }
        emit FeesClaimed(tokenId, wethFees, tokenFees, token);
    }

    function setTreasury(address t) external onlyOwner { require(t != address(0), "zero"); treasury = t; emit TreasurySet(t); }
    function transferOwnership(address n) external onlyOwner { require(n != address(0), "zero"); emit OwnershipTransferred(owner, n); owner = n; }

    receive() external payable {}
}
