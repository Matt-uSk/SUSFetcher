# Changelog

All notable changes to SUS Fetcher. Format based on [Keep a Changelog](https://keepachangelog.com/).

## [1.2.0] - 2026-10-20

### Added
- **Firmwares (IPSW)** section for iPhone, iPad and Apple Silicon Macs, based on [ipsw.me](https://ipsw.me): model list, firmware table with version, build, Apple signing status, release date and size.
- “Signed only” filter, copy URL / SHA-256 from the context menu.
- One-click IPSW download into `IPSW/` (original Apple file name), with pause / resume.
- Automatic **SHA-256 verification** after each IPSW download, shown on the Downloads page.
- Keyboard shortcuts ⌘3 / ⌘4 / ⌘5 for iPhone / iPad / Mac (Downloads moves to ⌘6).

### Changed
- Catalog toolbar controls (channel, “Betas only”) are disabled outside the catalog pages.

## [1.1.0] - 2026-10-20

### Added
- Automatic detection of the latest macOS major version: no source change or rebuild needed when a new macOS ships, including for beta channels.
- Settings → Apple catalog: detected version, optional custom catalog URL, “Re-detect and reload”.
- The status bar shows the macOS version of the catalog in use.

### Changed
- README in English, with a French version (`README.fr.md`).

## [1.0.0] - 2026-10-20

First release.

- One-click `InstallAssistant.pkg` download from the Apple Software Update catalog.
- Configurable installer file naming (e.g. `InstallermacOSTahoe-26.7.1.pkg`) with custom templates.
- Downloads page with pause / resume / cancel / retry, mini monitor in the sidebar, confirmation before quitting.
- Public / beta channels, beta-only products flagged with a BETA badge and “Betas only” filter.
- Settings: language (Français / English), appearance (system / light / dark), default download folder.
