# Changelog

All notable changes to SUS Fetcher. Format based on [Keep a Changelog](https://keepachangelog.com/).

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
