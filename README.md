# Claude Monitor

**A native macOS menu-bar app that shows your Claude Code rate limits at a glance.**

![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-blue) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

**[⬇︎ Download for macOS](https://github.com/YuriS5N/claude-monitor/releases/latest/download/ClaudeMonitor.dmg)** · [Website](https://yuris5n.github.io/claude-monitor/) · [Case study](docs/PORTFOLIO.md)

![Claude Monitor](docs/screenshot.png)

## What it does

### At a glance — the menu bar

The menu-bar title is compact (a status glyph plus your current 5h/7d percentages) and collapses to a shorter form when the menu bar runs out of room. Clicking it opens a popover with the 5h and weekly windows, today's activity, a 7-day chart, tokens by model, and your running Claude Code sessions with per-session memory.

### In depth — the Analytics window

A second window (button in the popover footer) answers the questions the menu bar can't:

- **Am I using what I pay for?** Your weekly quota consumption as bars, with dotted reference lines for the *other* plans' ceilings — so you can see at a glance whether a cheaper tier would have fit. Plus a month-by-month reconciliation, because the limit resets weekly while the bill is monthly.
- **Is the subscription worth it?** What your usage would have cost at pay-as-you-go API prices, per day / month / cumulative, against what you actually paid.
- **Where did it go?** Tokens by model over time, and a sortable table of every session with project, branch, active time and cost.
- **Should I switch plans?** A verdict based on your observed weekly peaks — gated until there's enough data to say something honest.

## How it works

- **Rate limits come from response headers.** Every 5 minutes the app makes one minimal 1-token Claude Haiku API call and reads the `anthropic-ratelimit-unified-*` headers from the HTTP response (`5h-utilization`, `7d-utilization`, `*-reset`, `*-status`, `overage-status`, `fallback-percentage`). These limits are unified across the whole account, not per model.
- **Auth is read from your Keychain.** Claude Code stores its OAuth token there per account, keyed by config directory — the service name is `Claude Code-credentials-<sha256(config dir)[:8]>`. The app pins one account (default `~/.claude`) and derives the service from it, so it keeps measuring the same account even if you use several. Claude Code manages and refreshes the token; you never paste anything.
- **Usage history comes from your transcripts.** It scans `<config dir>/projects/**/*.jsonl` for per-message model and token counts, deduplicating by `message.id` (transcripts write each message about twice, and forked sessions replay history into new files). The scan is incremental — it remembers how far it read into each file — and the aggregates are kept in `~/.claude-monitor/usage.json` so they survive Claude Code's own transcript cleanup.
- **Rate-limit history is recorded, because the API doesn't keep any.** Each poll is appended to `~/.claude-monitor/ratelimits.jsonl`. Weekly windows are a fixed 7-day cadence, so past weeks can be reconstructed by converting cost into quota using a ratio calibrated against the windows actually measured — shown as estimates, and replaced by real readings as weeks go by.
- **Today's counts and active sessions** come from `<config dir>/history.jsonl` and `<config dir>/sessions/*.json`, refreshed every 30s.

> **Requirements & cost.** This app requires a working Claude Code auth / Anthropic API access on your machine — it does nothing useful without it. The periodic 1-token Haiku call has a tiny but non-zero cost (a handful of input tokens every 5 minutes). If that matters to you, adjust the interval in `fetchRateLimits()`.

## Install

**Just want to use it?** Download the latest **[ClaudeMonitor.dmg](https://github.com/YuriS5N/claude-monitor/releases/latest/download/ClaudeMonitor.dmg)**, open it, and drag **Claude Monitor** onto the Applications folder. It's signed & notarized by Apple, so a double-click opens it — no Gatekeeper warnings. Apple Silicon · macOS 14+.

## Build from source

No Xcode required — it compiles directly with `swiftc` (using the Objective-C `ExceptionCatcher` bridging header to catch intermittent CoreText exceptions).

```bash
git clone https://github.com/YuriS5N/claude-monitor.git
cd claude-monitor

# Compile (arm64, macOS 14+)
./build.sh

# Launch it into the menu bar
./start.sh
```

Optional — auto-start at login and auto-restart on crash:

```bash
# Installs ~/Library/LaunchAgents/com.agape.claude-monitor.plist
./install_launchagent.sh
```

### Preview the UI (offscreen render)

You can generate the product screenshot above — with fixed sample data, no API or Keychain access — via:

```bash
./ClaudeMonitor --snapshot   # writes docs/screenshot.png
```

## Privacy

- Reads **only** local Claude Code files (`<config dir>/...`) and the OAuth token from your macOS Keychain.
- Writes only to `~/.claude-monitor/` — usage aggregates, the rate-limit log, and your plan config. Deleting that folder is a safe reset (it costs one full rescan, a few seconds).
- The single periodic API call goes to `api.anthropic.com` and returns nothing but a 1-token reply plus rate-limit headers.
- `--snapshot` mode uses **fixed sample data** — it never reads the Keychain, never calls the API, and never reflects your real usage.
- **No telemetry, no analytics, no third-party services.** Nothing leaves your machine except the Anthropic API call.

## Stack

Swift 6 · SwiftUI · AppKit · Swift Charts · zero external dependencies · targets macOS 14+ on Apple Silicon. Compiles with plain `swiftc` — `build.sh` builds everything under `Sources/`.

## Building the installer

The signed, notarized `.dmg` is produced by the scripts in [`packaging/`](packaging/) —
icon generation, `.app` bundling, code signing, Apple notarization and GitHub releases.
See [`packaging/README.md`](packaging/README.md).

## Support

Claude Monitor is free and open source. If it saves you a trip to the terminal, you can
**[buy me a coffee ☕](https://donate.stripe.com/6oU14o8RefjYfD30AxcAo05)** — one-time,
secure payment via Stripe, no account needed. Every bit is appreciated. 🙏

## License

[MIT](LICENSE) © 2026 Yuri Gomes de Abreu

---

*Not affiliated with Anthropic. "Claude" is a trademark of Anthropic, PBC.*
