# Changelog

Version headings use the form `## <version> — <YYYY-MM-DD>`. When a `v*` tag is
pushed, `.github/workflows/release.yml` copies the matching section into the
GitHub Release description (`v1.0.0` and `v1.0` both match `## 1.0`).

## Unreleased

## 0.9.3 — 2026-11-22

### Improved

- Storage: the distribution now covers the whole disk instead of leaving most
  of it as "outside measured folders". New rows show the macOS and service
  volumes (System, Preboot, VM, Recovery), system data (`/Library`,
  `/private/var`, Homebrew), `~/Library` by section (app data, containers,
  developer files, mail and messages, iCloud Drive), your own folders in the
  home folder and hidden folders such as `.cache` or `.npm`, each with a list
  of what is inside. Whatever cannot be measured is labelled with the reason,
  for example folders that need Full Disk Access.
- Storage: the "Can be cleaned" and "Snapshots" tiles measure on their own and
  show a value, including zero, instead of a dash.

## 0.9.2 — 2026-11-20

### Fixed

- Uninstaller: an app started while an uninstall is under way, or while the
  password dialog is open, is kept together with its data. A folder that
  merely ends in `.app` is no longer offered as an app, and data matched by
  name stays when another installed app uses that name.
- Uninstaller: when one item of a password-protected batch fails, the items
  removed before it are no longer reported as still installed or left out of
  History.
- Orphans: a privileged helper that a launchd job still uses is no longer
  offered for removal.
- Startup: removing a login item removes only that item, not every item with
  the same name. A second "turn off" can no longer start while one is running.
- Undo: undoing part of a cleanup no longer erases its History record while
  some of its items are still in the Trash.
- Privacy: clearing several browsers at once now clears all of them; before,
  every browser after the first was silently skipped. A browser opened while
  the confirmation is up is no longer quit without asking. The confirmation
  names the data that is actually cleared, and an already empty Firefox
  history is no longer offered.
- Duplicates: a copy restored with Undo can be removed again, and sparse files
  no longer overstate the space a cleanup frees.
- Storage: the overview refreshes after a cleanup on another screen instead of
  showing the old numbers until a manual rescan.
- System Data: a snapshot deleted during a rescan no longer comes back in the
  list, and a size that could only be partly measured is shown as "at least".
- System Junk: a file hard-linked into two folders is counted once.
- Large Files: an empty result after a timeout or an access error keeps its
  warning instead of showing a clean disk.
- Monitor: quitting a process can no longer hit a different process that
  reused its PID. Sorting by memory shows the largest memory users even when
  they use no CPU. Network speed no longer loses traffic on fast links. A
  charged battery on mains is shown as mains power.
- Alerts: one hot reading can no longer trigger the sustained-temperature
  alert, and an alert macOS failed to deliver is no longer muted for its
  cooldown.
- Menu bar: the sparkline resets when its metric changes.
- Settings opened on its own now shows the result of its actions.

### Improved

- Developer measures build folders in parallel within one time limit and keeps
  the results it has when the limit is reached; a slow project no longer keeps
  the screen scanning for minutes.
- Large Files stops searching once it has enough results and skips excluded
  folders without walking them, so it uses less memory on large disks.
- Leftovers and Orphans no longer re-read every installed app for each file
  they remove.
- The monitor stops polling battery and GPU temperature sensors a Mac does not
  have, and no longer leaks a system port reference on every sample.

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
