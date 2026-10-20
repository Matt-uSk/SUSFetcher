<p align="center"><img src="Resources/AppIcon.svg" width="128" alt="SUS Fetcher"></p>

# SUS Fetcher

🇫🇷 [Version française](README.fr.md)

Native macOS app (Swift/SwiftUI, Apple Silicon, macOS 14+, zero dependencies) that reads the Apple Software Update catalog and downloads `InstallAssistant.pkg` **in one click** — no more right-click → Packages → InstallAssistant.pkg.

## Origin and credits

- **Inspired by [SUS Inspector](https://github.com/hjuutilainen/sus-inspector)** by Hannes Juutilainen. The concept (browsing the Apple Software Update catalog and extracting its packages) comes from there. Since SUS Inspector relies on Python 2 / PyObjC, SUS Fetcher is a complete, modern rewrite focused on downloading macOS installers. No code from SUS Inspector was reused.
- **Most of the code was written by [Claude](https://claude.ai) (Anthropic)**.

## Features

- Sidebar: **macOS Installers** / **Other** / **iPhone** / **iPad** / **Mac** / **Downloads** (⌘1 … ⌘6)
- “InstallAssistant.pkg” button on each row, double-click, multi-selection (right-click)
- Downloads page + mini monitor at the bottom of the sidebar: progress, speed, time remaining, **pause / resume**, cancel, retry
- Confirmation before quitting while downloads are in progress
- “Other” products: package menu, saved into `<Title> <version> [<Product ID>]/`
- Channels: Public, Public beta, Developer beta, AppleSeed — beta-only products get a BETA badge, “Betas only” filter
- Search by title / version / build / Product ID
- **Favorites** section in the sidebar for quick access to a macOS line (e.g. “macOS Tahoe”, always up to date) or an iPhone / iPad / Mac model
- **Firmwares (IPSW)** for iPhone, iPad and Apple Silicon Macs, based on [ipsw.me](https://ipsw.me): models list, versions with Apple signing status, “Signed only” filter, one-click download into `IPSW/` with **automatic checksum verification**. If ipsw.me is unreachable, the app falls back to its last saved copy, then to Apple's official restore lists (latest signed version)
- Metadata (.dist) cached in `~/Library/Application Support/SUSFetcher/`

## Settings (⌘,)

- **Language**: system / Français / English (applied instantly)
- **Appearance**: system / light / dark
- Default **download folder**
- **Apple catalog**: detected macOS version, optional custom catalog URL
- **Installer naming**: presets or custom template, with live preview

| Preset | Example |
|---|---|
| Original Apple name | `InstallAssistant.pkg` |
| InstallAssistant + version + build | `InstallAssistant-26.7.1-25H123.pkg` |
| Readable (default) | `InstallermacOSTahoe-26.7.1.pkg` |
| Readable + build | `InstallermacOSTahoe-26.7.1-25H123.pkg` |

Custom template tokens: `{name}` (title without spaces), `{title}`, `{version}`, `{build}`, `{id}`.
An empty token is removed together with its separator.

## Installation

Download the latest version from [Releases](https://github.com/Matt-uSk/SUSFetcher/releases), unzip it and drag **SUS Fetcher.app** into `/Applications`.

The app is ad-hoc signed (no Apple Developer ID), so macOS blocks it on first launch. Remove the quarantine flag once:

```bash
xattr -dr com.apple.quarantine "/Applications/SUS Fetcher.app"
```

Apple Silicon, macOS 14 or later.

## Building from source

```bash
chmod +x build-app.sh
./build-app.sh 1.0.0      # → build/SUS Fetcher.app
```

For a quick test: `swift run`. Or `open Package.swift` to work in Xcode.

## Future macOS versions

Nothing to edit or recompile. At launch, SUS Fetcher detects the latest major version published by Apple: it starts from the highest known version (the Mac's own version, the last detected one, or 27) and probes the next catalogs until the first 404. The result is remembered and shown in the status bar and in Settings.

The public catalog already includes new installers anyway (Apple also adds them to older catalogs); detection mostly matters for beta channels, whose URL contains the version number. For troubleshooting, a custom catalog URL can be entered in Settings.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) — do whatever you want with it.
