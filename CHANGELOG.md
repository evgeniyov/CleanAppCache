# Changelog

Version headings use the form `## <version> — <YYYY-MM-DD>`. When a `v*` tag is
pushed, `.github/workflows/release.yml` copies the matching section into the
GitHub Release description (`v1.0.0` and `v1.0` both match `## 1.0`).

## Unreleased

## 0.9.1 — 2026-11-18

### Fixed

- Monitor: per-process CPU usage on Apple Silicon was about 40 times too low.
- CPU and temperature alerts now repeat after their 30-minute pause while the
  condition lasts, instead of staying silent for the rest of a long episode.
- Startup: turning an agent on or off no longer rewrites its plist; only the
  launchd override changes. Reading and removing login items no longer freezes
  the window while System Events starts or asks for permission.
- Uninstaller: data of another app whose bundle id extends the removed one's
  stays when that app lives outside the Applications folders.
- Large Files: a complete search no longer reports that it was cut short
  because some folders were unreadable.

## 0.9.0 — 2026-11-18

First public release, a beta. The DMG is not notarized yet; see the README for
how to open it the first time.

### System

- Storage: used and free space with a breakdown by category, a 7- or 30-day
  history of available space, folder browsing with cancellable measurements,
  and mounted external volumes.
- System Data: what Finder's "System Data" is made of, including local Time
  Machine snapshots, which can be deleted.
- Monitor: CPU, memory, GPU, network, disk and SSD health, temperatures, CPU
  cluster frequencies, battery and a searchable process list, with optional
  threshold alerts.
- History of cleanups with a report per run; Security checks for FileVault,
  firewall, Gatekeeper, SIP and other settings.

### Cleanup

- Smart Cleanup: caches, logs, temporary files, old installers and the Trash,
  with search, per-item selection and paths to always skip.
- System Junk, Developer caches and project build artifacts, browser Privacy
  data, Large Files and Duplicates, with saved search profiles.
- Items in use or written to recently are skipped and shown with the reason.

### Uninstaller

- Applications with their associated files, Leftovers of removed apps, orphaned
  launch agents and helpers, and Startup items.

### Safety

- Every delete is checked against a list of protected paths, and items that
  changed since the scan are left alone.
- Most cleanups move items to the Trash with Undo; permanent deletes always say
  so in the confirmation, and a password is asked only where macOS requires it.

### Menu bar and Settings

- A menu bar widget with eight layouts, light and dark themes, and English and
  Russian, switchable without a restart.
