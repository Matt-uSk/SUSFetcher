# Changelog

All notable changes to SUS Fetcher. Format based on [Keep a Changelog](https://keepachangelog.com/).

## [1.7.0] - 2026-10-21

### Added
- **IPSW file naming**, like installers: original Apple name, readable (`iPhone17Pro-iOS27.0.1.ipsw`), readable + build, identifier + version + build, or a custom template (`{model}` `{identifier}` `{os}` `{version}` `{build}`). Universal Mac IPSWs are named `UniversalMac-…` to avoid duplicating one file under several model names.
- **Download queue**: Settings → Downloads → *Simultaneous downloads* (1–10, default 3). Extra downloads wait as **Queued** (with their position) and start automatically in order; queued items can be paused or cancelled. Resumed downloads also go through the queue.

### Changed
- Settings window reorganized into tabs: General, Downloads, Naming, Catalog.

## [1.6.0] - 2026-10-21

### Added
- **Already-downloaded detection**: when the file is already in the destination folder, the row shows **✓ Downloaded** (click to reveal in Finder, right-click → Download Again) instead of downloading it again. Applies to installers, “Other” packages and IPSW files; double-click and multi-selection skip files already present.
- **Renamed files are recognized too**: `.pkg` / `.ipsw` files of the exact same size anywhere in the destination folder are checked by checksum (Apple catalog SHA-1 “Digest”, ipsw.me SHA-256 / Apple SHA-1). Checksums are computed once in the background and cached.
- InstallAssistant and catalog packages are now **verified by SHA-1** after download, like IPSW files.
- **Download Latest Versions…** (right-click a collection's title): resolves the latest version of every item — newest InstallAssistant, newest package set, latest *signed* IPSW (shared Mac IPSWs listed once) — and shows a summary before starting: files, sizes, status (to download / already present / not found), total size, free disk space with a warning when it's not enough, and an option to re-download files already present.

## [1.5.0] - 2026-10-20

### Added
- **Built-in updater**: checks GitHub Releases at launch (at most once a day) or via *SUS Fetcher → Check for Updates…*. When a new version is out, shows what's new with **Install and Relaunch**, View on GitHub, Later or Skip This Version.
- The update is downloaded, its SHA-256 checked against the release, its bundle identifier verified, then the app is replaced and relaunched — no quarantine prompt for updated versions.
- Settings → Updates: installed version, automatic checks on/off, “Check Now”.

### Notes
- Versions up to 1.4.1 don't include the updater: install 1.5.0 manually once, later versions will update themselves.

## [1.4.1] - 2026-10-20

### Added
- Sort menu above the IPSW model list: newest first, oldest first, name (A → Z), or **by product line** (grouped in sections: MacBook Pro, iMac, Mac mini…). The choice is remembered.

### Fixed
- Mac models were in the wrong order: M1-era identifiers (iMac21, MacBookPro18, Macmini9…) were listed before newer Macs. They are now placed in their generation, before Mac13 and later.

## [1.4.0] - 2026-10-20

### Added
- **Collections**: create your own collections (e.g. “Fleet”, “Beta testing”), rename, reorder and delete them. Each collection is a section in the sidebar.
- Right-click a catalog product or an IPSW model → **Add to Collection ›** (checkmarks per collection, or “New Collection…”); the folder button next to a model's name does the same.
- Items can be reordered by drag and drop and removed with a right-click; one item can live in several collections.
- Catalog items follow the product **title** (e.g. “macOS Tahoe”), so they always show every version, including future ones; IPSW items follow the model identifier.
- “New Collection…” in the File menu (⇧⌘N) and at the bottom of the sidebar.

## [1.3.0] - 2026-10-20

### Added
- IPSW fallback chain when ipsw.me is unreachable: last saved copy on disk (with its date), then Apple's official restore lists (latest signed version per model).
- SHA-1 verification for firmwares coming from Apple's lists (SHA-256 is still used for ipsw.me data).
- Source indicator in the IPSW pages (ipsw.me / offline cache / Apple fallback) and a warning banner when not using ipsw.me.

### Fixed
- IPSW pages now use the full window height (the device list was squeezed in the middle).
- Models are sorted newest first (by identifier) instead of reverse alphabetical order.
- iMac models were missing from the Mac section.

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
