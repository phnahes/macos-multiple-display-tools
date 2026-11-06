# Changelog

All notable changes to this project are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning follows
[Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-11-06

### Added

- One brightness slider per connected display when "Follow Mac brightness" is
  off; a single Mac brightness slider when it is on.
- `monitor angle` and the `lidangle` helper binary: the MacBook lid angle from
  the command line.
- "Start at login" toggle in the menu bar (enable/disable the LaunchAgent).
- "Last error" item in the menu when a DDC write fails.
- CLI test suite with fake `m1ddc`/`ioreg` binaries (26 cases, no hardware).
- GitHub Actions: shell lint + tests + build on every push, and a release
  workflow that packages `MonitorBar.app` when a `v*` tag is pushed.
- Release packaging with SHA-256 checksum.

### Changed

- The menu is rebuilt from a cache and refreshed in the background, so opening it
  no longer blocks on `m1ddc`.
- The app only polls on a timer when there is something live to follow (sync on
  or the angle shown in the menu bar); otherwise values are read when the menu
  opens.
- Project renamed to `macos-multiple-display-tools`.

### Fixed

- Concurrent DDC access between the app and the CLI could crash `m1ddc`; both
  sides now take a shared per-user lock around every transaction and retry.
- DDC reads and writes are retried twice before reporting an error.
- With no external display connected, the CLI now says so instead of trying to
  control the built-in panel and failing with a generic error.
- Hot-plug and wake are handled through system notifications instead of waiting
  for the next poll.

## [1.0.0] - 2026-11-05

### Added

- `MonitorBar.app`: menu bar app that keeps an external monitor's brightness in
  sync with the built-in display (DDC/CI via `m1ddc`, built-in via
  `DisplayServices`).
- `monitor` / `brightness` / `contrast` / `monitor-info` CLI, plus
  `brilho`/`contraste` aliases.
- Physical port detection from `ioreg` (`USB-C 2 (left, rear)`).
- Lid angle in the menu bar and optionally in the status item.
- `setup.sh` for a one-shot install (Command Line Tools, Homebrew, `m1ddc`).
- `install.sh` / `uninstall.sh`, LaunchAgent for login start.
