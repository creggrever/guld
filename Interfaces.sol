// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// =============================================================================
// Shared interfaces for the GULD game — Uniswap V3 periphery subset + ERC20/721.
// =============================================================================

interface INonfungiblePositionManager {
    struct MintParams {
        address token0; address token1; uint24 fee;
        int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired;
        uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId; address recipient;
        uint128 amount0Max; uint128 amount1Max;
    }
    function createAndInitializePoolIfNecessary(
        address token0, address token1, uint24 fee, uint160 sqrtPriceX96
    ) external payable returns (address pool);
    function mint(MintParams calldata params) external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params)
        external payable returns (uint256 amount0, uint256 amount1);
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// exactInputSingle across the two Uniswap-V3-style SwapRouter variants Robinhood
/// Chain exposes (testnet keeps `deadline`, mainnet SwapRouter02 drops it). Chosen
/// by chainid at runtime.
library SwapCompat {
    function exactInputSingle(
        address router,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMinimum
    ) internal returns (uint256 amountOut) {
        bytes memory data = block.chainid == 46630
            ? abi.encodeWithSelector(
                bytes4(0x414bf389),
                tokenIn, tokenOut, fee, recipient, block.timestamp, amountIn, amountOutMinimum, uint160(0))
            : abi.encodeWithSelector(
                bytes4(0x04e45aaf),
                tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, uint160(0));
        (bool ok, bytes memory ret) = router.call(data);
        require(ok && ret.length >= 32, "swap");
        amountOut = abi.decode(ret, (uint256));
    }
}

/// The staking surface a room pushes protocol-fee ETH into.
interface IGuldStaking {
    function notifyReward() external payable;
}

/// Uniswap Universal Router — one entrypoint that routes across V2/V3/V4. A room
/// wraps its ETH and swaps ETH→payout token through this, so any token with
/// liquidity on any version is supported.
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
