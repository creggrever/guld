<p align="center">
  <img src="guld-coin.png" alt="GULD" width="150" />
</p>

<h1 align="center">GULD Contracts</h1>

<p align="center"><em>The honest ponzi, on-chain.</em></p>

---

GULD is a transparent, honest-ponzi jackpot game that runs entirely on-chain on
[Robinhood Chain](https://robinhoodchain.blockscout.com). You deposit **ETH** to mint
permanent **gulden** (gold bars); every deposit pays dividends to everyone who came before
you, adds to a **jackpot vault**, and pushes a countdown timer forward. When the timer runs
out, the **last depositor wins the whole vault**. There is no sell - gulden are forever.

Every rule is set at deploy time and **immutable**: no admin can change the split, move the
vault, pause a room, or withdraw dividends.

> This repo is the **contracts only** (Solidity + Foundry). To play a room from an agent's
> own wallet, see [`SKILL.md`](./SKILL.md).

## Contracts

| Contract | Address | Description |
|----------|---------|-------------|
| `GuldRoom.sol` | `TBD` | One table of the game. Buy no-sell gulden with ETH; each buy splits into vault / dividends / seed / protocol and extends the timer in its final minute. Last buyer at expiry wins the vault. |
| `Guld.sol` | `TBD` | The `$GULD` token. Fixed 1,000,000 supply - no mint, no pause, no fee, no blacklist. |
| `GuldStaking.sol` | `TBD` | Lock `$GULD` to earn the game's protocol-fee ETH, pro-rata by amount x lock-days. |
| `GuldLocker.sol` | `TBD` | Locks the fair-launch LP forever; only trading fees are sweepable, and only to the treasury. |
| `GuldSpawn.sol` | `TBD` | Deterministic (CREATE2) `$GULD` launcher + liquidity bootstrap. |

## Economics (per deposit)

| Slice | Share | Where it goes |
|-------|-------|---------------|
| **Vault** | 40% | the jackpot for this round (won by the last depositor) |
| **Dividends** | 40% | split pro-rata across **existing** gulden holders (not the buyer) |
| **Seed** | 10% | rolls into the **next** round's opening vault |
| **Stakers** | 5% | streamed to `$GULD` stakers as ETH |
| **Treasury** | 5% | protocol treasury |

- **ETH room**: vault and dividends are ETH, no swaps.
- **Token room**: 90% of each buy is swapped ETH -> token, so the vault and dividends accrue
  and pay out in that token. **You always deposit ETH.**

Gulden are priced on a rising linear bonding curve (`price = basePrice + slope * supply`);
overpaying is safe, as `buy` refunds anything above cost. Each buy sets
`endsAt = min(now + timeCap, endsAt + timeStep)`, so the clock only extends near the end -
a last-minute buy always adds time, up to the cap.

## Design & safety

- **Immutable rules.** A room's split, curve, and timer are set in the constructor and can
  never change. No admin can withdraw the vault or dividends.
- **Pull-based payouts.** Winnings and dividends sit in `claimableOf` until you `claim()`, so
  a reverting recipient can never block settlement or anyone else's funds.
- **No-sell token model.** Gulden are permanent; the only exits are dividends and the vault.
  Only ETH is ever at stake in a room.
- **Un-ruggable launch.** `$GULD` has a fixed supply and no mint / pause / fee / blacklist,
  the LP is locked forever, and ownership is meant to be renounced to a burn address.
- **Adversarial by design.** Rooms are permissionless; a snipe only wins if no one deposits
  after you before `endsAt`.

## Playing as an agent

Everything is on-chain and permissionless - no backend, no API keys. An autonomous agent can
read a room and place buys, farm dividends, snipe the vault, and claim winnings straight from
its own wallet. See [`SKILL.md`](./SKILL.md) for the full interface, the economics, and a
runnable viem example.
