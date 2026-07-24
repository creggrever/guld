// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC20, IUniversalRouter, IGuldStaking } from "./Interfaces.sol";

/**
 * @title GuldRoom
 * @notice One table of GULD — an honest, transparent on-chain jackpot game. Buy
 *         permanent (no-sell) gold bars with ETH; each buy adds to the vault and
 *         streams dividends to existing bar-holders. The round timer opens at the cap
 *         and only extends inside its final minute — a last-minute buy adds time (up to
 *         the cap), so the endgame is unsnipeable while mid-round buys don't stall it.
 *         When the timer hits zero the last buyer wins the vault; a seed rolls into the
 *         next round so it never opens empty.
 *
 *         Payout token: ETH in the "ETH room" (payoutToken == address(0), no
 *         swaps), else a stock/token — 90% of each buy (vault+dividends+seed) is
 *         swapped ETH→token once per buy, so vault + dividends accrue AS the token.
 *         The 10% protocol fee always stays ETH: 5% to $GULD stakers, 5% to
 *         treasury.
 *
 *         Split per buy: 40% vault / 40% dividends / 10% seed / 10% protocol.
 *         Linear bonding curve: price(n) = BASE + SLOPE*n. All config is immutable —
 *         no admin can change rules or withdraw the vault/dividends. Winnings and
 *         dividends are pull-based (claim), so a payout that reverts can never brick
 *         settlement.
 */
contract GuldRoom {
    uint256 internal constant MAG = 2 ** 128;
    // the clock only extends inside the final ENDGAME seconds — a buy with more time
    // left than this leaves the timer alone; only last-minute buys push it (up to the cap).
    uint64 internal constant ENDGAME = 60;
    // split, in bps of a buy
    uint16 internal constant VAULT_BPS = 4000;
    uint16 internal constant DIV_BPS = 4000;
    uint16 internal constant SEED_BPS = 1000;
    uint16 internal constant STAKE_BPS = 500;
    uint16 internal constant TREASURY_BPS = 500;
    uint16 internal constant STOCK_BPS = VAULT_BPS + DIV_BPS + SEED_BPS; // 9000
    // custom-token rooms burn half the seed slice (5% of each deposit) → the payout
    // token is bought and sent to the dead address, deflationary by design.
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // Universal Router recipient sentinels (map to msg.sender / the router).
    address internal constant MSG_SENDER = address(1);
    address internal constant ADDRESS_THIS = address(2);
    // Universal Router command bytes.
    bytes internal constant CMDS_V3 = hex"0b00"; // WRAP_ETH, V3_SWAP_EXACT_IN
    bytes internal constant CMDS_V2 = hex"0b08"; // WRAP_ETH, V2_SWAP_EXACT_IN
    bytes internal constant CMDS_V4 = hex"10";   // V4_SWAP (native ETH in, no wrap)
    // V4 action bytes: SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL
    bytes internal constant V4_ACTIONS = hex"060c0f";

    struct V4PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    struct V4ExactInSingle { V4PoolKey poolKey; bool zeroForOne; uint128 amountIn; uint128 amountOutMinimum; bytes hookData; }

    // ---- immutable config ----
    address public immutable payoutToken; // address(0) = ETH room; else the token
    address public immutable universalRouter;
    address public immutable staking;
    address public immutable treasury;
    uint8   public immutable swapVersion; // 0 = ETH room (no swap), 2 = V2, 3 = V3
    bytes   public swapRoute;             // set once in constructor (route to payout token)
    uint256 public immutable basePrice;   // BASE (wei)
    uint256 public immutable slope;       // SLOPE (wei per bar)
    uint64  public immutable timeStep;    // seconds added per buy
    uint64  public immutable timeCap;     // max timer / round-open duration
    bool    internal immutable isEthRoom;
    bool    public immutable burnsToken;  // custom-token room: burn 5% of each deposit

    // ---- round state (current round) ----
    uint256 public round;
    uint256 public totalBars;
    uint256 public vault;         // jackpot for this round (payout token units)
    uint256 public seed;          // rolls into next round's vault
    uint256 public divPerShare;   // magnified dividends-per-bar, this round
    uint64  public endsAt;
    address public lastBuyer;
    bool    public started;

    // per-holder state (single-level, lazily reset each round via _sync)
    mapping(address => uint256) public barRound;    // which round `bars` belongs to
    mapping(address => uint256) public bars;
    mapping(address => int256)  public correction;
    mapping(address => uint256) public claimedDiv;  // dividends withdrawn this round
    mapping(address => uint256) public claimable;   // finalized past dividends + winnings

    // snapshot of a finished round's final divPerShare, for late finalization
    mapping(uint256 => uint256) public finalDivPerShare;

    bool internal _entered;
    modifier nonReentrant() { require(!_entered, "re"); _entered = true; _; _entered = false; }

    event Bought(uint256 indexed round, address indexed buyer, uint256 barsBought, uint256 spent, uint256 totalBars, uint64 endsAt);
    event Claimed(address indexed holder, uint256 amount);
    event Settled(uint256 indexed round, address indexed winner, uint256 vaultWon, uint256 seedCarried);

    struct Config {
        address payoutToken; address universalRouter; address staking; address treasury;
        uint8 swapVersion; bytes swapRoute;
        uint256 basePrice; uint256 slope; uint64 timeStep; uint64 timeCap;
        bool burn; // custom-token launch: burn 5% of each deposit (5% seed instead of 10%)
    }

    constructor(Config memory c) {
        require(c.staking != address(0) && c.treasury != address(0), "zero");
        require(c.basePrice > 0 && c.timeStep > 0 && c.timeCap >= c.timeStep, "cfg");
        bool eth = (c.payoutToken == address(0));
        require(eth || (c.universalRouter != address(0) && c.swapVersion >= 2 && c.swapVersion <= 4), "swap-cfg");
        payoutToken = c.payoutToken;
        universalRouter = c.universalRouter;
        staking = c.staking;
        treasury = c.treasury;
        swapVersion = c.swapVersion;
        swapRoute = c.swapRoute;
        basePrice = c.basePrice;
        slope = c.slope;
        timeStep = c.timeStep;
        timeCap = c.timeCap;
        isEthRoom = eth;
        burnsToken = c.burn && !eth; // only token rooms can burn their payout token
        round = 1;
    }

    // ---- pricing ----
    /// ETH cost to buy `n` bars from the current supply on the linear curve.
    function costFor(uint256 n) public view returns (uint256) {
        uint256 s = totalBars;
        // sum_{i=s}^{s+n-1} (base + slope*i) = n*base + slope*(n*s + n(n-1)/2)
        return n * basePrice + slope * (n * s + (n * (n - 1)) / 2);
    }
    function nextPrice() external view returns (uint256) { return basePrice + slope * totalBars; }

    // ---- play ----
    /// Buy `n` gold bars; msg.value must cover costFor(n). Excess is refunded.
    function buy(uint256 n) external payable nonReentrant {
        require(n > 0, "n");
        // if the live round has expired, settle it first (rolls to a fresh round).
        if (started && block.timestamp >= endsAt) _settle();

        uint256 cost = costFor(n);
        require(msg.value >= cost, "underpay");

        bool opening = !started;
        if (opening) started = true;

        _sync(msg.sender); // reset the buyer's per-round state if they're new this round

        // 10% protocol (ETH), 90% -> payout token
        uint256 stakeEth = (cost * STAKE_BPS) / 10_000;
        uint256 treasEth = (cost * TREASURY_BPS) / 10_000;
        uint256 stockEth = cost - stakeEth - treasEth;

        uint256 payoutAmt = _toPayout(stockEth);
        uint256 vaultAdd = (payoutAmt * VAULT_BPS) / STOCK_BPS;
        uint256 seedPool = (payoutAmt * SEED_BPS) / STOCK_BPS; // the 10% seed slice
        uint256 divAdd   = payoutAmt - vaultAdd - seedPool;
        // custom-token rooms split the seed slice into 5% seed + 5% burn
        uint256 burnAmt  = burnsToken ? seedPool / 2 : 0;
        uint256 seedAdd  = seedPool - burnAmt;

        // dividends go to EXISTING holders; if none yet, fold into the vault
        if (totalBars == 0) { vaultAdd += divAdd; }
        else { divPerShare += (divAdd * MAG) / totalBars; }

        vault += vaultAdd;
        seed  += seedAdd;

        // mint the buyer's bars with a correction so they don't claim past dividends
        totalBars += n;
        bars[msg.sender] += n;
        correction[msg.sender] += int256(divPerShare * n);

        // timer: open at the cap. Otherwise the clock only moves in the final ENDGAME
        // seconds — a buy with more time left than that doesn't extend it; a last-minute
        // buy adds timeStep (capped at now+timeCap), making the endgame unsnipeable.
        uint64 nowT = uint64(block.timestamp);
        uint64 maxEnd = nowT + timeCap;
        if (opening) { endsAt = maxEnd; }
        else if (endsAt - nowT < ENDGAME) {
            uint64 ne = endsAt + timeStep;
            endsAt = ne > maxEnd ? maxEnd : ne;
        }
        lastBuyer = msg.sender;

        emit Bought(round, msg.sender, n, cost, totalBars, endsAt);

        // interactions last (checks-effects-interactions)
        if (burnAmt > 0) { require(IERC20(payoutToken).transfer(DEAD, burnAmt), "burn"); } // deflationary
        if (stakeEth > 0) IGuldStaking(staking).notifyReward{value: stakeEth}();
        if (treasEth > 0) { (bool ok, ) = treasury.call{value: treasEth}(""); require(ok, "treas"); }
        if (msg.value > cost) { (bool ok2, ) = msg.sender.call{value: msg.value - cost}(""); require(ok2, "refund"); }
    }

    /// Settle a finished round (permissionless once the timer expires).
    function settle() external nonReentrant {
        require(started && block.timestamp >= endsAt, "live");
        _settle();
    }

    function _settle() internal {
        address winner = lastBuyer;
        uint256 won = vault;
        uint256 carried = seed;

        finalDivPerShare[round] = divPerShare; // snapshot for late dividend claims
        if (won > 0 && winner != address(0)) claimable[winner] += won; // pull, no push

        emit Settled(round, winner, won, carried);

        round += 1;
        totalBars = 0;
        vault = carried;   // seed becomes the opening vault
        seed = 0;
        divPerShare = 0;
        lastBuyer = address(0);
        started = false;
        endsAt = 0;
    }

    // ---- claim (pull) ----
    /// Finalize a holder's dividends from a past round (if any) into `claimable`
    /// and reset their per-round state for the current round.
    function _sync(address h) internal {
        uint256 br = barRound[h];
        if (br == round) return;
        if (bars[h] > 0) {
            uint256 dps = finalDivPerShare[br];
            int256 a = int256(dps * bars[h]) - correction[h];
            uint256 acc = a <= 0 ? 0 : uint256(a) / MAG;
            uint256 owed = acc > claimedDiv[h] ? acc - claimedDiv[h] : 0;
            if (owed > 0) claimable[h] += owed;
        }
        bars[h] = 0;
        correction[h] = 0;
        claimedDiv[h] = 0;
        barRound[h] = round;
    }

    /// Dividends owed to `holder` for the CURRENT round (live).
    function currentDividends(address holder) public view returns (uint256) {
        if (barRound[holder] != round) return 0;
        int256 a = int256(divPerShare * bars[holder]) - correction[holder];
        uint256 acc = a <= 0 ? 0 : uint256(a) / MAG;
        return acc > claimedDiv[holder] ? acc - claimedDiv[holder] : 0;
    }

    /// Everything `holder` can withdraw right now: current-round dividends +
    /// finalized past dividends + winnings.
    function claimableOf(address holder) external view returns (uint256 total) {
        total = claimable[holder] + currentDividends(holder);
        // add not-yet-synced past-round dividends
        uint256 br = barRound[holder];
        if (br != round && bars[holder] > 0) {
            int256 a = int256(finalDivPerShare[br] * bars[holder]) - correction[holder];
            uint256 acc = a <= 0 ? 0 : uint256(a) / MAG;
            if (acc > claimedDiv[holder]) total += acc - claimedDiv[holder];
        }
    }

    /// Claim dividends (current + finalized past) and any winnings, in the payout token.
    function claim() external nonReentrant returns (uint256 total) {
        _sync(msg.sender); // sweeps finished-round dividends into `claimable`
        uint256 cur = currentDividends(msg.sender);
        if (cur > 0) claimedDiv[msg.sender] += cur;
        total = claimable[msg.sender] + cur;
        require(total > 0, "0");
        claimable[msg.sender] = 0;
        _payout(msg.sender, total);
        emit Claimed(msg.sender, total);
    }

    // ---- helpers ----
    /// Swap `ethAmount` of ETH into the payout token via the Universal Router (V2/V3),
    /// returning the amount actually received (balance-delta — robust to any router).
    function _toPayout(uint256 ethAmount) internal returns (uint256 out) {
        if (isEthRoom || ethAmount == 0) return ethAmount;

        bytes memory cmds;
        bytes[] memory inputs;
        if (swapVersion == 4) {
            // V4 swaps native ETH directly (no WETH wrap). swapRoute encodes the pool.
            (address c0, address c1, uint24 fee, int24 tickSpacing, address hooks, bool zeroForOne) =
                abi.decode(swapRoute, (address, address, uint24, int24, address, bool));
            V4ExactInSingle memory s = V4ExactInSingle({
                poolKey: V4PoolKey(c0, c1, fee, tickSpacing, hooks),
                zeroForOne: zeroForOne, amountIn: uint128(ethAmount), amountOutMinimum: 0, hookData: ""
            });
            bytes[] memory p = new bytes[](3);
            p[0] = abi.encode(s);
            p[1] = abi.encode(zeroForOne ? c0 : c1, ethAmount);   // SETTLE_ALL(currencyIn, maxAmount)
            p[2] = abi.encode(payoutToken, uint256(0));           // TAKE_ALL(currencyOut, minAmount)
            inputs = new bytes[](1);
            inputs[0] = abi.encode(V4_ACTIONS, p);
            cmds = CMDS_V4;
        } else {
            inputs = new bytes[](2);
            inputs[0] = abi.encode(ADDRESS_THIS, ethAmount); // WRAP_ETH → router holds WETH
            if (swapVersion == 3) {
                cmds = CMDS_V3;
                inputs[1] = abi.encode(MSG_SENDER, ethAmount, uint256(0), swapRoute, false);
            } else {
                cmds = CMDS_V2;
                address[] memory path = abi.decode(swapRoute, (address[]));
                inputs[1] = abi.encode(MSG_SENDER, ethAmount, uint256(0), path, false);
            }
        }

        uint256 before = IERC20(payoutToken).balanceOf(address(this));
        IUniversalRouter(universalRouter).execute{value: ethAmount}(cmds, inputs, block.timestamp);
        out = IERC20(payoutToken).balanceOf(address(this)) - before;
        require(out > 0, "swap"); // no liquidity / bad route → fail loud (funds safe)
    }

    function _payout(address to, uint256 amount) internal {
        if (isEthRoom) { (bool ok, ) = to.call{value: amount}(""); require(ok, "eth"); }
        else { require(IERC20(payoutToken).transfer(to, amount), "tok"); }
    }

    function timeLeft() external view returns (uint256) {
        if (!started || endsAt <= block.timestamp) return 0;
        return endsAt - block.timestamp;
    }

    receive() external payable {}
}
