# Claude Monitor

**A native macOS menu-bar app that shows your Claude Code rate limits at a glance.**

![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-blue) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

![Claude Monitor](docs/screenshot.png)

## What it does

Claude Monitor lives in your macOS menu bar and surfaces your Claude Code usage without opening a terminal:

- **5h session** — percent of the rolling 5-hour rate-limit window used, with a time-vs-usage pace marker and countdown to reset.
- **Weekly (7d)** — percent of the rolling 7-day window used, same pace marker and reset countdown.
- **Today** — message count and the projects you touched today.
- **7-day bar chart** — messages per day, colored green/orange/red relative to your weekly average.
- **Tokens by model** — a breakdown across Opus / Sonnet / Haiku.
- **Active sessions** — running Claude Code sessions with status (busy/idle) and per-session memory.

The menu-bar title itself is compact — a status glyph plus the current 5h/7d percentages — and it adapts (or collapses to a shorter form) depending on how much room the menu bar has.

## How it works

- **Rate limits come from response headers.** Every 5 minutes the app makes one minimal 1-token Claude Haiku API call and reads the `anthropic-ratelimit-unified-*` headers from the HTTP response (`5h-utilization`, `7d-utilization`, `*-reset`, `*-status`, `overage-status`, `fallback-percentage`). These limits are unified across the whole account, not per model.
- **Auth is read from your Keychain.** The app reads the OAuth token that Claude Code already stores in the macOS Keychain (`security find-generic-password -s "Claude Code-credentials"`). Claude Code manages and refreshes that token; the app never asks you to paste anything.
- **Local stats come from your Claude files.** It reads `~/.claude/stats-cache.json`, `~/.claude/history.jsonl`, and `~/.claude/sessions/*.json` (refreshed every 30s) for today's messages, the 7-day chart, per-model tokens, and active sessions.

> **Requirements & cost.** This app requires a working Claude Code auth / Anthropic API access on your machine — it does nothing useful without it. The periodic 1-token Haiku call has a tiny but non-zero cost (a handful of input tokens every 5 minutes). If that matters to you, adjust the interval in `fetchRateLimits()`.

## Install / build

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

- Reads **only** local Claude Code files (`~/.claude/...`) and the OAuth token from your macOS Keychain.
- The single periodic API call goes to `api.anthropic.com` and returns nothing but a 1-token reply plus rate-limit headers.
- `--snapshot` mode uses **fixed sample data** — it never reads the Keychain, never calls the API, and never reflects your real usage.
- **No telemetry, no analytics, no third-party services.** Nothing leaves your machine except the Anthropic API call.

## Stack

Swift 6 · SwiftUI · AppKit · single-file app (`Sources/ClaudeMonitor.swift`) · zero external dependencies · targets macOS 14+ on Apple Silicon.

## License

[MIT](LICENSE) © 2026 Yuri Gomes de Abreu
