# [clock.fun](https://clock.fun)

Clock.fun is an onchain financial game built on a tradeable token, $TICKER.

A portion of every $TICKER swap goes toward the countdown & jackpot pools.

Every buy has a chance to extend the clock and/or instantly win the jackpot. When the clock hits zero, the round ends and the countdown pool is paid out to the last buyer to extend the timer.

---

## Countdown pool

Every buy has a chance to extend the timer.

When the round ends (timer reaches zero), the countdown pool is distributed to the 50 most recent extenders by rank:

- Rank 1 (last extender): 50%
- Ranks 2–5: 5% each
- Ranks 6–10: 2% each
- Ranks 11–25: 1% each
- Ranks 26–50: 0.2% each

The odds of a buyer extending the timer depend on buy amount and countdown pool size.

---

## Jackpot pool

Each buy has a chance to win the entire jackpot.

The max odds of winning increase with pool size, making the jackpot progressive. After each win, the odds function is re-randomized — ensuring every pot evolves uniquely.

---

## Secured by Chainlink

Each $TICKER swap uses Chainlink VRF to randomly determine whether the timer is extended and/or the jackpot pool is won.

---

## Launch

Price discovery begins on a bonding curve and ultimately migrates to a Uniswap V4 pool with a custom game hook.

A fair-launch tax mechanism imposes an initial 99% tax that decays by 1% per minute to a 10% floor.

---

## Contract addresses

| Contract | Address |
|----------|---------|
| Ticker | [0xa54e6ecae0fdf28fd73d39f024774aadb4c3be32](https://basescan.org/address/0xa54e6ecae0fdf28fd73d39f024774aadb4c3be32#code) |
| ClockGame | [0x7af30623cded6e86f528143732b576c39521c9ab](https://basescan.org/address/0x7af30623cded6e86f528143732b576c39521c9ab#code) |
| ClockGameMechanics | [0xa95a45291878DB8D258B69bF6d4453f2BBB6c234](https://basescan.org/address/0xa95a45291878DB8D258B69bF6d4453f2BBB6c234#code) |
| BondingCurve | [0x51bc0a3afafe6d53c8fe27a624b415d0adf4f05f](https://basescan.org/address/0x51bc0a3afafe6d53c8fe27a624b415d0adf4f05f#code) |
| ClockHook (Uniswap v4) | [0x6ad9e9250fc26d3f4794a419a411734d5e0960cc](https://basescan.org/address/0x6ad9e9250fc26d3f4794a419a411734d5e0960cc#code) |

---

## Swap Tax

A percentage of each buy/sell goes to the game and is split 40% countdown pool, 50% jackpot pool, 10% creator. Game buys also pay a small VRF fee for on-chain randomness.
