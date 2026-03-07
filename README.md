# ClaudeUsageBar

A lightweight macOS menu bar app that displays your Claude API usage in real time. Shows session (5-hour) and weekly (7-day) utilization as color-coded progress rings directly in the menu bar.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **Menu bar progress ring** with percentage — green/yellow/red based on usage level
- **Session & weekly utilization** displayed in a popover with countdown timers
- **Extra usage tracking** for plans with spending limits (shows dollars used/remaining)
- **Plan badge** — detects Max 5x/20x tiers automatically
- **Auto-refresh** every 60 seconds and on wake from sleep
- **Zero configuration** — reads credentials directly from Claude Code's Keychain entry

## Prerequisites

- **macOS 13.0** (Ventura) or later
- **Swift 5.9+** toolchain (included with Xcode 15+)
- **Claude Code** must be installed and signed in (the app reads its OAuth token from the macOS Keychain)

## Installation

### From source (recommended)

```bash
git clone https://github.com/kossov-it/claude-usage-bar.git
cd claude-usage-bar
make install
```

This builds a release binary, bundles it into `ClaudeUsageBar.app`, and copies it to `/Applications`.

### Manual

```bash
make bundle
open .build/release/ClaudeUsageBar.app
```

## Usage

1. **Sign in to Claude Code** in your terminal (`claude` command) — the app reads its OAuth token
2. **Launch ClaudeUsageBar** — it appears in your menu bar with a progress ring and percentage
3. **Click the icon** to see the full popover with session/weekly details
4. The **progress ring color** indicates usage level:
   - Green: < 50% utilization
   - Yellow: 50-79% utilization
   - Red: >= 80% utilization
5. When weekly utilization hits 100%, the menu bar shows a red "X"

### Menu bar controls

| Button | Action |
|--------|--------|
| Refresh arrow | Force an immediate usage refresh |
| X button | Quit the app |

### Auto-start on login

To launch automatically at login:

1. Open **System Settings > General > Login Items**
2. Click **+** and select `ClaudeUsageBar.app` from `/Applications`

## Build targets

| Command | Description |
|---------|-------------|
| `make build` | Compile release binary |
| `make bundle` | Build + create `.app` bundle (ad-hoc signed) |
| `make install` | Bundle + copy to `/Applications` |
| `make run` | Bundle + launch the app |
| `make clean` | Remove build artifacts |

## How it works

1. Reads the OAuth access token from macOS Keychain (stored by Claude Code under `Claude Code-credentials`)
2. Calls `https://api.anthropic.com/api/oauth/usage` to get session and weekly utilization
3. Calls `https://api.anthropic.com/api/oauth/account` once to detect the plan tier (Pro vs Max 5x/20x)
4. Renders a progress ring and percentage in the menu bar
5. Polls every 60 seconds and on system wake

The app never stores or transmits credentials — it only reads what Claude Code has already saved in your Keychain.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Menu bar shows "—" | No OAuth token found | Run `claude` in Terminal to sign in |
| "Session expired" error | Token expired | Open Claude Code to refresh the session |
| "Rate limited" error | Too many API requests | Waits for next poll cycle (60s) |
| App doesn't appear | `LSUIElement` hides Dock icon | Check the menu bar (top-right area) |
| Build fails | Missing Swift toolchain | Install Xcode 15+ or Command Line Tools |

## License

MIT License. See [LICENSE](LICENSE) for details.
