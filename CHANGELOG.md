# Changelog

All notable changes to SUS Fetcher. Format based on [Keep a Changelog](https://keepachangelog.com/).

## [2.0.0-beta.2] - 2026-11-09

Pre-release for testing — published on the beta channel only.

### Fixed
- **Apple Silicon Mac in DFU not showing in Connected Devices.** Connected to another Apple Silicon Mac, a Mac in DFU doesn't appear as a standard USB DFU device but behind Apple's “Debug USB” interface. Devices in DFU / Recovery are now read through **MobileDevice** (the framework used by Finder and Apple Configurator), which reports their ECID, chip and board — so the Mac is detected and identified. The previous USB detection remains as a fallback.

### Added
- DFU Mode page: **Copy Diagnostics** button (detected devices, MobileDevice events, Apple USB devices, last DFU command output) to attach to a bug report.

## [2.0.0-beta.1] - 2026-11-09

Pre-release for testing — published on the beta channel only.

### Added
- **Connected Devices** (bottom of the sidebar): iPhone and iPad plugged in over USB appear with their name, model and iOS version (read from the device, no pairing needed). Devices in **DFU or Recovery** — Apple Silicon Macs included — are detected too and identified from their chip (CPID/BDID).
- Clicking a device opens its page: model, identifier, UDID / ECID (click to copy), **up to date / update available** status (or the latest signed version to restore with), and its firmwares ready to download.
- **DFU Mode** page: **put an Apple Silicon Mac connected to this Mac into DFU** in one click, or restart it to leave DFU (bundled [macvdmtool](https://github.com/AsahiLinux/macvdmtool), Apache 2.0; requires an Apple Silicon Mac, both Macs connected through their DFU ports, and an administrator password). Step-by-step button guides for iPhone / iPad (no software DFU exists for those) and for a Mac without a second Mac.
- Updater: **update channel** setting (Stable / Beta). Beta builds follow the Beta channel by default; version comparison now understands pre-releases (2.0.0 > 2.0.0-beta.2 > 2.0.0-beta.1).

## [1.10.0] - 2026-11-06

### Added
- **On This Mac** (sidebar › Activity, ⌘7): every `.pkg` / `.ipsw` already in the destination folder (subfolders included) with type, version, size, date and folder, plus the total size. Packages are **identified** from the catalog by their xar TOC digest, even renamed, and flagged when a **newer version is available**. Right-click: Show in Finder, Copy Path, Move to Trash (with confirmation).

## [1.9.2] - 2026-11-06

### Fixed
- Updater: on Macs where the account can't modify the app's folder (standard / non-admin account, app installed by an administrator), *Install and Relaunch* was silently missing. It now offers **Install and Relaunch (administrator password)**: macOS asks for an admin password, the app is replaced and relaunched under the user's account.
- Updater: when automatic install isn't possible, the window now says why (e.g. app running from a temporary *App Translocation* location — move it to Applications).

## [1.9.1] - 2026-11-06

### Fixed
- **False “SHA-1 mismatch — corrupted file”** on InstallAssistant and catalog packages. The catalog's `Digest` turned out to be the SHA-1 of the package's **xar table of contents**, not of the whole file (checked against real Apple packages). Downloads were fine; the check was wrong.
- InstallAssistant (and every package that provides it) is now verified with Apple's **chunklist** — the SHA-256 of each 10 MB chunk, the same integrity data macOS uses — so the **whole file** is checked. Other packages are checked against their xar TOC digest.
- Renamed-file detection for `.pkg` now reads only the xar TOC (a few KB) instead of hashing the whole file: instant.

### Added
- Right-click a finished download → **Verify Again**.

## [1.9.0] - 2026-11-06

### Added
- **Universal app**: runs natively on Apple Silicon **and Intel** Macs (macOS 14 or later), one download for everyone — the updater works on both.

## [1.8.1] - 2026-11-05

### Fixed
- Updater: more robust download — no cache, automatic second attempt through the GitHub API, checks that the file received is really a zip of the announced size before comparing its SHA-256.
- Updater: precise error messages (not a zip — likely a proxy / web filter / antivirus page —, wrong size, or both checksums), plus **Download Manually** and **Copy Details** buttons.

## [1.8.0] - 2026-11-05

### Added
- **Collection settings button** (⚙︎ at the end of each collection's title in the sidebar, also on right-click): rename, automatic sync, **per-collection frequency** and **old-versions choice** (or use the defaults from Settings), Sync Now with last sync date, Download Latest Versions, move, delete.
- **Automatic sync per collection** (⚙︎ › *Automatic Sync*, shown with ↻): at the chosen interval the app reloads the catalog and firmwares, finds the latest version of every item and downloads what's missing through the queue. *Sync Now* is also available per collection and in Settings.
- Settings → **Sync** tab: frequency (hourly → weekly), **delete old versions** option, *Open SUS Fetcher at login*, last / next sync and a summary of the last run.
- Old versions are **moved to the Trash** only once the new version is downloaded and its checksum verified, and only for files the sync itself downloaded — your own files are never touched, and a file still current for another synced item (e.g. the universal Mac IPSW) is kept.
- macOS notification when a sync starts new downloads.

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
