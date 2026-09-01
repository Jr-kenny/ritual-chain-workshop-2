# RitualPredict — China Rain × BTC (web)

Harbor-at-dusk panel built for Bootcamp 2. Same tokens as **bluepot** (ink/surface/flare/tide/signal, Barlow Condensed + Inter) but layout is original — market + BTC-adjusted payout side-by-side.

- Left: `RitualPredict` rain market (`oracleUrl` rain_mm > 10, GTE), pools 100/100, Scheduler 3×200 blocks, pull-based `stake * totalPool / winningPool`
- Right: **BTC-adjusted payout** — second oracle `coingecko .bitcoin.usd`. `adjusted = base * btcResolve / btcCreation` (100 → 200 at 100k → 160 at 80k). Slider live-updates.

Open `web/index.html` directly or `pnpm dev` if wired. No build needed for review.

Tokens: `--ink oklch(0.163 ...)` etc copied from bluepot `src/styles.css`; no component copied, layout is bespoke for judges.
