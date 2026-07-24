---
name: play-guld
description: >-
  How an autonomous agent (e.g. a Claude bot) plays GULD, the on-chain jackpot game on
  Robinhood Chain, fully on-chain from its own wallet. Covers the economics, the GuldRoom
  contract interface, reading room state, pricing and placing deposits (minting gulden),
  farming dividends, sniping the vault, and claiming winnings - with a viem example the
  agent can adapt and run itself.
---

# Playing GULD as an agent

This skill lets an autonomous agent play GULD entirely on-chain, signing from its own
wallet. There is no backend and no API - the agent reads and writes the `GuldRoom`
contract directly (viem/ethers or raw JSON-RPC). Everything below is what it needs.

GULD is a transparent, honest-ponzi jackpot game. Each **room** is one `GuldRoom`
contract. You deposit **ETH** to mint permanent **gulden**; every deposit pays
dividends to everyone who came before you, adds to a **jackpot vault**, and pushes a
countdown timer forward. When the timer runs out, the **last depositor wins the whole
vault**. There is no sell - gulden are forever.

Two independent ways a bot makes ETH:
1. **Dividend farming** - hold gulden early; earn 40% of every later deposit, pro-rata
   to your share of the gulden supply.
2. **Jackpot snipe** - be the `lastBuyer` when the timer expires and take the vault.

Everything is on-chain and permissionless. No API keys, no accounts - just a funded
wallet and the room address.

---

## Economics (per deposit)

For a deposit of `cost` wei of ETH:

| Slice | Share of cost | Where it goes |
|-------|---------------|---------------|
| Vault | **40%** | the jackpot for this round (won by the last depositor) |
| Dividends | **40%** | split pro-rata across **existing** gulden holders (not the buyer) |
| Seed | **10%** | rolls into **next** round's opening vault (stays in the contract) |
| Stakers | **5%** | streamed to `$GULD` stakers (ETH) |
| Treasury | **5%** | protocol treasury |

- In the **ETH room** (`payoutToken() == address(0)`) the vault + dividends are in ETH.
- In a **token room**, each deposit's 90% is swapped ETH→token, so the vault + dividends
  accrue and pay out in that token. **You still deposit ETH** either way.

**Custom-token launch rooms** (`burnsToken() == true`): the 10% seed slice is split into
**5% seed + 5% burn** - that 5% of every deposit is bought as the token and sent to the
dead address, so playing the room is continuously **deflationary** for that token. All
other slices are unchanged (40/40 vault/dividends, 5/5 stakers/treasury).

### Pricing (linear bonding curve)

`gulden` are priced on a rising line. With `s = totalBars()` (current supply):

```
costFor(n) = n*basePrice + slope*( n*s + n*(n-1)/2 )      // wei of ETH
nextPrice() = basePrice + slope*s                          // price of the next single gulden
```

`basePrice` and `slope` are per-room immutables. The curve is steeper in stock rooms.
Overpaying is safe - `buy` refunds anything above `costFor(n)`.

### Timer

- Each deposit sets `endsAt = min(now + timeCap, endsAt + timeStep)`; the first deposit
  of a round opens it at `now + timeCap`.
- The round is **live** while `now < endsAt`. It's **over** once `now >= endsAt`.
- `settle()` finalizes an over round (permissionless). The **next `buy` auto-settles**
  the previous round first, so you rarely need to call `settle` yourself.
- `timeStep` (seconds added per deposit) and `timeCap` (max clock) are room immutables.

### Break-even for the last-man snipe

A single snipe costs `nextPrice()` and, if you stay last, wins `vault()`. It's +EV when
`vault() > nextPrice()` **and** you can be the final depositor. Risk: anyone buying after
you extends the clock by `timeStep` and takes over `lastBuyer`. Snipe as late as latency
allows (`timeLeft()` a few seconds), and only when the vault dwarfs the entry price.

---

## Contract interface (`GuldRoom`)

```solidity
// ---- actions ----
function buy(uint256 n) external payable;      // mint n gulden; send >= costFor(n) ETH (overpay refunded)
function claim() external returns (uint256);   // withdraw dividends + winnings (in the payout token)
function settle() external;                    // finalize an expired round (permissionless)

// ---- pricing ----
function costFor(uint256 n) external view returns (uint256); // ETH cost to mint n now
function nextPrice() external view returns (uint256);        // price of the next 1 gulden

// ---- round state ----
function round() external view returns (uint256);
function totalBars() external view returns (uint256);        // gulden minted this round
function vault() external view returns (uint256);            // current jackpot (payout-token units)
function seed() external view returns (uint256);             // rolls to next round
function endsAt() external view returns (uint64);            // unix seconds; round over when now >= endsAt
function timeLeft() external view returns (uint256);         // seconds remaining (0 if over/unstarted)
function started() external view returns (bool);
function lastBuyer() external view returns (address);        // wins the vault at settle

// ---- your position ----
function bars(address) external view returns (uint256);              // your gulden this round
function currentDividends(address) external view returns (uint256); // live dividends owed this round
function claimableOf(address) external view returns (uint256);      // everything withdrawable now (divs + past + winnings)

// ---- config ----
function payoutToken() external view returns (address); // 0x0 = ETH room; else the payout ERC-20
function basePrice() external view returns (uint256);
function slope() external view returns (uint256);
function timeStep() external view returns (uint64);
function timeCap() external view returns (uint64);
function burnsToken() external view returns (bool);     // true = custom-launch room burns 5% of each deposit

// ---- events ----
event Bought(uint256 indexed round, address indexed buyer, uint256 barsBought, uint256 spent, uint256 totalBars, uint64 endsAt);
event Settled(uint256 indexed round, address indexed winner, uint256 vaultWon, uint256 seedCarried);
event Claimed(address indexed holder, uint256 amount);
```

Depositing (`buy`) is always paid in **ETH** (`msg.value`). Dividends and the vault pay
out in `payoutToken` (ETH for the ETH room). Read `costFor(n)` immediately before sending
`buy` and set `value = costFor(n)` (or a hair more; overpay refunds).

---

## Config

| | Mainnet | Testnet |
|-|---------|---------|
| chainId | `4663` | `46630` |
| RPC | `https://rpc.mainnet.chain.robinhood.com` | `https://rpc.testnet.chain.robinhood.com` |
| Explorer | `https://robinhoodchain.blockscout.com` | `https://explorer.testnet.chain.robinhood.com` |

Room addresses come from the deploy output (the `ETH room` / `AAPL room` … lines) or the
web app env (`NEXT_PUBLIC_ROOM_ETH`, `NEXT_PUBLIC_ROOM_AAPL`, …). Your wallet needs ETH
for deposits **and** gas. Robinhood is Arbitrum-style: a node's `eth_estimateGas` is
L1-inclusive, so normal estimation works; if a send ever reverts with "intrinsic gas too
low", bump the gas limit ~2–4×.

---

## Minimal example (viem)

```ts
import { createPublicClient, createWalletClient, http, parseAbi, parseEther } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const RPC = process.env.RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com";
const ROOM = process.env.ROOM as `0x${string}`;          // the GuldRoom address
const account = privateKeyToAccount(process.env.PRIVATE_KEY as `0x${string}`);

const abi = parseAbi([
  "function costFor(uint256) view returns (uint256)",
  "function timeLeft() view returns (uint256)",
  "function started() view returns (bool)",
  "function vault() view returns (uint256)",
  "function lastBuyer() view returns (address)",
  "function claimableOf(address) view returns (uint256)",
  "function buy(uint256) payable",
  "function claim() returns (uint256)",
]);

const pub = createPublicClient({ transport: http(RPC) });
const wallet = createWalletClient({ account, transport: http(RPC) });
const read = (fn: string, args: unknown[] = []) => pub.readContract({ address: ROOM, abi, functionName: fn as never, args: args as never });

async function tick() {
  const [started, left, vault, last, owed] = await Promise.all([
    read("started"), read("timeLeft"), read("vault"), read("lastBuyer"),
    read("claimableOf", [account.address]),
  ]) as [boolean, bigint, bigint, string, bigint];

  // 1) snipe: buy 1 in the last few seconds if the vault beats the entry price
  const iAmLast = last.toLowerCase() === account.address.toLowerCase();
  if (started && left > 0n && left <= 6n && !iAmLast) {
    const cost = await read("costFor", [1n]) as bigint;
    if (vault > cost * 2n) {
      await wallet.writeContract({ address: ROOM, abi, functionName: "buy", args: [1n], value: cost });
    }
  }

  // 2) sweep winnings / dividends when worth the gas
  if (owed > parseEther("0.002")) {
    await wallet.writeContract({ address: ROOM, abi, functionName: "claim" });
  }
}

setInterval(() => tick().catch(console.error), 3000);
```

---

## Safety notes

- **Only ETH is at stake** - you deposit ETH; the worst case is losing your deposits when
  the vault goes to someone else. Cap spend per round (`MAX_SPEND_ETH`).
- The game is **honest but adversarial** - other bots snipe too; a snipe is only won if no
  one deposits after you before `endsAt`.
- **Everything is pull-based**: winnings and dividends sit in `claimableOf` until you
  `claim()`. They never expire. Claim on your own schedule to save gas.
- **Never assume a room is safe by address alone** - verify `payoutToken`, `basePrice`,
  `slope`, `timeStep`, `timeCap` on-chain before playing an unfamiliar room.
