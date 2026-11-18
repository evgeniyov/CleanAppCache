# Changelog

Version headings use the form `## <version> — <YYYY-MM-DD>`. When a `v*` tag is
pushed, `.github/workflows/release.yml` copies the matching section into the
GitHub Release description (`v1.0.0` and `v1.0` both match `## 1.0`).

## Unreleased

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
