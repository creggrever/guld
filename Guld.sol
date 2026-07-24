// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { INonfungiblePositionManager } from "./Interfaces.sol";

/**
 * @title Guld  ($GULD)
 * @notice The GULD game's house token. Fixed 1,000,000 supply — no mint, no pause,
 *         no fees, no blacklist. The full premine is held by the token itself and
 *         seeded single-sided into a WETH pool by `startTrading` (LP NFT minted to
 *         the owner, then locked in GuldLocker). Fair launch: 1M supply, ~$5k
 *         starting MC pin, no presale, no team allocation.
 *
 *         The `owner` holds NO powers over the token beyond the anti-snipe limits
 *         below (no mint, no pause, no blacklist, no fee) — it exists so the team can
 *         send a public, verifiable `transferOwnership` to a burn address (e.g.
 *         0x…dEaD) after launch, the recognised on-chain "hands off" signal.
 *
 *         Anti-snipe wallet/tx limits (ported from LootProtocolToken), defaulted to
 *         1.5% of supply in the constructor: a `maxWallet` caps how much any non-exempt
 *         address may hold (this is what actually throttles a sniper's buy) and a
 *         `maxTx` caps transfer size. Enforced only once `tradingEnabled` (set by
 *         `startTrading`), and the owner can only ever RAISE them (never tighten) or
 *         disable them for good — a launch guard, not a lever to trap holders.
 *
 *         Minimal, gas-lean ERC-20. Infinite allowance (type(uint256).max) is not
 *         decremented, so routers don't burn approval every swap.
 */
contract Guld {
    string public constant name = "Guld";
    string public constant symbol = "GULD";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000e18;

    // Anti-snipe launch limits, as bps of supply (150 = 1.5%). Owner can only raise or
    // disable them after launch via increaseLimits; enforced once trading is open.
    uint256 constant MAX_WALLET_BPS = 150;
    uint256 constant MAX_TX_BPS = 150;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isExempt; // skips the wallet/tx limits

    address public owner;
    address public spawner;

    bool public tradingEnabled; // limits are only enforced once this is on
    bool public walletLtd;      // false = limits disabled forever
    uint256 public maxWallet;   // max holding for a non-exempt address
    uint256 public maxTx;       // max transfer size between non-exempt addresses

    address public uniswapV3Pool; // set by startTrading
    uint256 public lpNFTId;       // the seeded LP position, minted to the owner

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ExemptSet(address indexed account, bool exempt);
    event IncreasedLimits(uint256 maxWalletBps, uint256 maxTxBps);
    event StartedTrading(address pool, uint256 lpId, address pmgr);

    constructor(address owner_) {
        owner = owner_;
        spawner = msg.sender;
        balanceOf[address(this)] = totalSupply; // premine held here for LP seeding

        walletLtd = true;
        maxWallet = (totalSupply * MAX_WALLET_BPS) / 10000;
        maxTx = (totalSupply * MAX_TX_BPS) / 10000;

        // the token (seed holder), owner and dead address never trip the limits
        isExempt[address(this)] = true;
        isExempt[owner_] = true;
        isExempt[msg.sender] = true;
        isExempt[DEAD] = true;

        emit Transfer(address(0), address(this), totalSupply);
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() { require(msg.sender == owner, "o"); _; }

    /// Hand ownership to another address. To go hands-off, transfer to a burn
    /// address such as 0x…dEaD — the recognised on-chain "renounced" signal.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "z");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // =====================================================================
    //                        launch / anti-snipe limits
    // =====================================================================

    /// Open the pool and seed the full premine single-sided, then arm the wallet/tx
    /// limits. Creates the pool, exempts it + the position manager (the pool MUST be
    /// exempt or every sell would trip maxWallet), mints the LP to `params.recipient`
    /// (the owner), and flips `tradingEnabled`. One-way. Mirrors
    /// LootProtocolToken.startTrading.
    function startTrading(
        address pmgr,
        uint160 sqrtPriceX96,
        INonfungiblePositionManager.MintParams calldata params
    ) external returns (address pool) {
        require(msg.sender == owner || msg.sender == spawner, "o");
        require(!tradingEnabled, "td");
        require(params.recipient == owner, "rcpt");
        require(params.token0 != params.token1, "s1");
        require(params.token1 == address(this) || params.token0 == address(this), "s2");
        if (params.token1 == address(this)) {
            require(params.amount1Desired == totalSupply, "amt");
        } else {
            require(params.amount0Desired == totalSupply, "amt");
        }

        tradingEnabled = true;

        isExempt[pmgr] = true;
        allowance[address(this)][pmgr] = totalSupply; // let the pmgr pull the premine

        pool = INonfungiblePositionManager(pmgr).createAndInitializePoolIfNecessary(
            params.token0, params.token1, params.fee, sqrtPriceX96
        );
        isExempt[pool] = true;
        (lpNFTId, , , ) = INonfungiblePositionManager(pmgr).mint(params);
        uniswapV3Pool = pool;

        emit StartedTrading(pool, lpNFTId, pmgr);
    }

    /// Exempt (or un-exempt) an address from the wallet/tx limits. Used for protocol
    /// contracts that pool GULD (staking, locker). Owner-only, like the reference.
    function setExempt(address account, bool exempt) external onlyOwner {
        isExempt[account] = exempt;
        emit ExemptSet(account, exempt);
    }

    /// Raise (never tighten) the limits, or disable them for good by passing 10000/10000.
    function increaseLimits(uint256 maxWalletBps, uint256 maxTxBps) external onlyOwner {
        require(walletLtd, "off");
        require(maxWalletBps <= 10000 && (totalSupply * maxWalletBps) / 10000 >= maxWallet, "wallet");
        require(maxTxBps <= 10000 && (totalSupply * maxTxBps) / 10000 >= maxTx, "tx");
        maxWallet = (totalSupply * maxWalletBps) / 10000;
        maxTx = (totalSupply * maxTxBps) / 10000;
        if (maxWalletBps == 10000 && maxTxBps == 10000) walletLtd = false;
        emit IncreasedLimits(maxWalletBps, maxTxBps);
    }

    // =====================================================================
    //                              ERC-20
    // =====================================================================

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "allowance");
            unchecked { allowance[from][msg.sender] = allowed - value; }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0) && to != address(this), "to");
        uint256 bal = balanceOf[from];
        require(bal >= value, "balance");

        if (tradingEnabled && walletLtd && !isExempt[from] && !isExempt[to]) {
            require(value <= maxTx, "maxTx");
        }
        if (tradingEnabled && walletLtd && !isExempt[to]) {
            require(balanceOf[to] + value <= maxWallet, "maxWallet");
        }

        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
