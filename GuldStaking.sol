// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC20 } from "./Interfaces.sol";

/**
 * @title GuldStaking
 * @notice Lock $GULD to earn the game's protocol-fee ETH. You pick a lock duration
 *         (1–365 days); your reward weight = amount × lock-days (simple, no decay).
 *         Rewards (ETH) are streamed in by the rooms via notifyReward() and split
 *         pro-rata by weight. You cannot withdraw the principal until the lock ends,
 *         but ETH rewards are claimable at any time. Non-custodial: no admin can
 *         move stakes or rewards.
 */
contract GuldStaking {
    uint256 internal constant MAG = 2 ** 128;
    uint256 public constant MIN_DAYS = 1;
    uint256 public constant MAX_DAYS = 365;

    IERC20 public immutable guld;
    address public immutable treasury; // where rewards go if there are no stakers

    struct Lock {
        address owner;
        uint256 amount;     // GULD locked
        uint256 weight;     // amount × lockDays
        uint64  unlockAt;
        uint256 rewardDebt; // magnified accounting checkpoint
    }

    uint256 public nextId = 1;
    mapping(uint256 => Lock) public locks;
    mapping(address => uint256[]) internal _userLocks;

    uint256 public totalWeight;
    uint256 public rewardPerWeight; // magnified ETH-per-weight, accumulated

    event Staked(uint256 indexed id, address indexed owner, uint256 amount, uint256 lockDays, uint256 weight, uint64 unlockAt);
    event Unstaked(uint256 indexed id, address indexed owner, uint256 amount);
    event RewardClaimed(uint256 indexed id, address indexed owner, uint256 amount);
    event RewardAdded(uint256 amount);

    bool internal _entered;
    modifier nonReentrant() { require(!_entered, "re"); _entered = true; _; _entered = false; }

    constructor(address guld_, address treasury_) {
        require(guld_ != address(0) && treasury_ != address(0), "zero");
        guld = IERC20(guld_);
        treasury = treasury_;
    }

    /// Lock `amount` of GULD for `lockDays` (1–365). Weight = amount × lockDays.
    function stake(uint256 amount, uint256 lockDays) external nonReentrant returns (uint256 id) {
        require(amount > 0, "amount");
        require(lockDays >= MIN_DAYS && lockDays <= MAX_DAYS, "days");
        require(guld.transferFrom(msg.sender, address(this), amount), "pull");

        uint256 weight = amount * lockDays;
        totalWeight += weight;

        id = nextId++;
        locks[id] = Lock({
            owner: msg.sender,
            amount: amount,
            weight: weight,
            unlockAt: uint64(block.timestamp + lockDays * 1 days),
            rewardDebt: weight * rewardPerWeight
        });
        _userLocks[msg.sender].push(id);
        emit Staked(id, msg.sender, amount, lockDays, weight, locks[id].unlockAt);
    }

    /// Streamed-in ETH rewards, split pro-rata by weight. Permissionless (rooms call
    /// it; anyone may also donate). With no stakers, ETH is forwarded to treasury.
    function notifyReward() external payable {
        if (msg.value == 0) return;
        if (totalWeight == 0) {
            (bool ok, ) = treasury.call{value: msg.value}("");
            require(ok, "treas");
            return;
        }
        rewardPerWeight += (msg.value * MAG) / totalWeight;
        emit RewardAdded(msg.value);
    }

    /// Pending ETH reward for a lock.
    function pending(uint256 id) public view returns (uint256) {
        Lock storage l = locks[id];
        uint256 acc = l.weight * rewardPerWeight;
        if (acc <= l.rewardDebt) return 0;
        return (acc - l.rewardDebt) / MAG;
    }

    /// Claim a lock's accrued ETH rewards (allowed any time, even while locked).
    function claim(uint256 id) public nonReentrant returns (uint256 amt) {
        Lock storage l = locks[id];
        require(l.owner == msg.sender, "owner");
        amt = pending(id);
        l.rewardDebt = l.weight * rewardPerWeight;
        if (amt > 0) {
            (bool ok, ) = msg.sender.call{value: amt}("");
            require(ok, "eth");
            emit RewardClaimed(id, msg.sender, amt);
        }
    }

    /// After the lock ends: claim remaining rewards and withdraw the GULD principal.
    function unstake(uint256 id) external nonReentrant returns (uint256 amount) {
        Lock storage l = locks[id];
        require(l.owner == msg.sender, "owner");
        require(block.timestamp >= l.unlockAt, "locked");

        // effects first (checks-effects-interactions): read what's owed, then clear state
        uint256 amt = pending(id);
        amount = l.amount;
        totalWeight -= l.weight;
        delete locks[id];

        // interactions last
        if (amt > 0) { (bool ok, ) = msg.sender.call{value: amt}(""); require(ok, "eth"); emit RewardClaimed(id, msg.sender, amt); }
        require(guld.transfer(msg.sender, amount), "tok");
        emit Unstaked(id, msg.sender, amount);
    }

    function userLocks(address u) external view returns (uint256[] memory) { return _userLocks[u]; }

    receive() external payable { } // allow plain ETH sends to accumulate as rewards
}
