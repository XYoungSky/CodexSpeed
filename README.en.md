# CodexSpeed

[简体中文](README.md) | **English**

A lightweight macOS floating window for Codex task speed, token usage, and quota.
Reads local logs without modifying them. No API key required; no conversation content uploaded.
Not affiliated with OpenAI.

## Features

- Output speed (tok/s), task status, elapsed time, token usage, and estimated context usage.
- Automatically follows the most recently active Codex Desktop main task, with manual task locking.
- Full and compact views, a menu bar mode, and a draggable window that remembers its position.
- English and Simplified Chinese; system, light, and dark appearance; glass, solid, or transparent backgrounds.
- Quota and reset times from logs, with optional API-equivalent capacity estimates through ccusage.

## Build and run

Requires macOS 13+ to run. Building requires a Swift toolchain with the macOS 26+ SDK
for the Liquid Glass API; older systems use a solid background at runtime.
No third-party Swift package dependencies.

```sh
git clone https://github.com/XYoungSky/CodexSpeed.git
cd CodexSpeed
./scripts/build-app.sh
open dist/CodexSpeed.app
```

The build produces `dist/CodexSpeed.app` for your Mac's architecture, with an ad hoc signature
and no notarization. Icons are generated automatically during the build.

Logs are read from `~/.codex` by default. To use another location, select the Codex home directory
containing `sessions` in Settings. Use the top controls to switch to compact mode, hide to the menu bar,
or open Settings. Click the menu bar icon to restore the floating window.

## Understanding the data

- **Speed:** estimated from recent log increments while running; after completion, total turn output tokens divided by duration, including tool execution and waiting.
- **Quota:** based on log snapshots, which may be stale; no live server queries. Missing metrics appear as `—`.
- **Log window:** files modified within the last 14 UTC calendar days, including active and archived sessions; reads are incremental after startup.
- **Cost estimates (optional):** supports only `ccusage 20.0.20`. Set its executable path in Settings; the default is `/opt/homebrew/bin/ccusage`. Speed and logged quota remain available without ccusage.
- **Calibration:** requires at least 3 valid snapshots, a 10-minute span, and 5 percentage points of quota consumption. Resets or pricing changes restart sampling.

Dollar amounts estimate API-equivalent capacity; **they are not a subscription balance or bill**.
Usage on other devices, missing logs, model prices, and quota consumption weights can affect the results.
ccusage runs offline with a pricing snapshot in [Pricing.swift](Sources/CodexSpeedCore/Pricing.swift);
prices do not update automatically. Unknown models and unsupported long-context pricing pause calibration.
Changes to the log format may also affect compatibility.

Settings are stored in UserDefaults. Calibration records are saved to
`~/Library/Application Support/CodexSpeed/calibration.json` without conversation content.
The app does not use App Sandbox; configure only a trusted ccusage executable.

## Development

```sh
./scripts/test.sh
```

Tests run through the standalone `CoreChecks` executable target.
The ccusage integration check is skipped if ccusage is not installed at the default path.

```text
Sources/CodexSpeed/       Window, menu bar, and settings
Sources/CodexSpeedCore/   Log parsing, speed metrics, and quota calibration
Tests/                   Core checks
scripts/                 Tests, builds, and icon generation
Assets/                  Vector icon artwork
```

## License

[MIT](LICENSE)
