# Changelog

Version headings use the form `## <version> — <YYYY-MM-DD>`. When you push a `v*` tag, `.github/workflows/release.yml` copies the matching
section into the GitHub release description. Both `v1.0.0` and `v1.0` match
`## 1.0`.

## Unreleased

## 0.9.4 — 2026-11-22

### Added

- In Storage, "What changed" compares used space with the previous measurement
  and over 7 or 30 days. It lists what cleanups freed or moved to the Trash in
  that period and which folders and categories changed most. It marks changes
  as uncertain when it could only measure part of an item.
- The app measures the disk once a day in the background at low priority. It
  records the results even if you never open Storage. It skips measurements in
  Low Power Mode or when the battery is low. You can turn off daily
  measurements in Settings.

## 0.9.3 — 2026-11-22

### Improved

- Storage accounts for the whole disk. Earlier versions grouped most of the
  disk under "outside measured folders". New rows list macOS and service
  volumes (System, Preboot, VM, Recovery), system data (`/Library`,
  `/private/var`, Homebrew), `~/Library` by section (app data, containers,
  developer files, mail and messages, iCloud Drive), your own folders in the
  home folder and hidden folders such as `.cache` or `.npm`. Each row lists its
  contents. Storage gives a reason for anything it cannot measure, such as a
  folder that requires Full Disk Access.
- In Storage, the "Can be cleaned" and "Snapshots" tiles each run their own
  measurement. They show the measured value, including zero.

## 0.9.2 — 2026-11-20

### Fixed

- The Uninstaller keeps an app and its data if the app starts during uninstall,
  including while the password dialog is open. It excludes folders that end in
  `.app` but are not apps. It keeps data matched by name if another installed
  app uses that name.
- If an item in a password-protected batch fails, the Uninstaller still reports
  earlier removals and records them in History.
- Orphans leaves out privileged helpers that a launchd job still uses.
- Startup removes only the selected login item, even when other items share its
  name. It blocks a second "turn off" while the first is running.
- After a partial Undo, History keeps the cleanup record while any of its items
  remain in the Trash.
- Privacy clears every selected browser. Previously, it skipped every browser
  after the first without reporting it. It asks before quitting a browser
  opened while the confirmation is visible. The confirmation lists the data
  Privacy clears. Privacy leaves empty Firefox histories out of the results.
- Duplicates can remove a copy again after you restore it with Undo. It counts
  only the space sparse files occupy.
- Storage refreshes the overview after a cleanup on another screen. Previously,
  you had to rescan to update it.
- System Data keeps a snapshot out of the list if you delete it during a
  rescan. It displays partial size measurements as "at least".
- System Junk counts a file hard-linked into two folders once.
- Large Files keeps the warning when a timeout or an access error leaves the
  results empty.
- Monitor checks that the process you want to quit is still the one with that
  PID. Sorting by memory includes the largest memory users even when they use
  no CPU. Monitor counts network traffic on fast links. It shows mains power
  when the Mac is plugged in and the battery is charged.
- The sustained-temperature alert requires more than one hot reading. If macOS
  fails to deliver an alert, the app can retry without waiting for the
  cooldown.
- The menu bar resets the sparkline when you change its metric.
- Settings shows the result of each action even when you open it on its own.

### Improved

- Developer measures build folders in parallel under one time limit. When it
  reaches the limit, it keeps the results it has, so a slow project cannot keep
  the scan running for minutes.
- Large Files stops once it has enough results and skips excluded folders
  without scanning their contents. This reduces memory use on large disks.
- Leftovers and Orphans reuse the installed-app inventory when they remove
  files.
- Monitor polls battery and GPU temperature sensors only if the Mac has them.
  It releases a system port reference after each sample.

## 0.9.1 — 2026-11-18

### Fixed

- Monitor corrects per-process CPU usage on Apple Silicon. Earlier readings
  were about 40 times too low.
- CPU and temperature alerts repeat after their 30-minute pause if the
  condition persists. Previously, they fired only once while the condition
  lasted.
- When you turn an agent on or off, Startup changes only the launchd override
  and leaves the plist intact. You can use the window while System Events
  starts or asks for permission to read or remove login items.
- The Uninstaller keeps another app's data if its bundle ID extends the removed
  app's ID and it lives outside the Applications folders.
- Large Files reports a finished search as complete even if it could not read
  some folders.

## 0.9.0 — 2026-11-18

This is the first public release. It is a beta. The DMG is not notarized yet.
See the README for first-launch instructions.

### System

- Storage shows used and free space by category and a 7- or 30-day history of
  available space. You can browse folders, cancel measurements and view mounted
  external volumes.
- System Data lists what Finder groups under "System Data". You can delete
  local Time Machine snapshots there.
- Monitor shows CPU, memory, GPU, network, disk and SSD health, temperatures,
  CPU cluster frequencies and battery status. It has a searchable process list
  and optional threshold alerts.
- History shows a report for each cleanup. Security checks FileVault, firewall,
  Gatekeeper, SIP and other settings.

### Cleanup

- Smart Cleanup lists caches, logs, temporary files, old installers and the
  Trash. You can search, select individual items and set paths to always skip.
- You can save search profiles for System Junk, Developer caches and project
  build artifacts, browser Privacy data, Large Files and Duplicates.
- The app skips items in use or written to recently and shows why.

### Uninstaller

- The Uninstaller section lists Applications with their associated files,
  Leftovers of removed apps, orphaned launch agents and helpers, and Startup
  items.

### Safety

- The app checks every deletion against a list of protected paths and skips
  items that changed since the scan.
- Most cleanups move items to the Trash with Undo. The confirmation identifies
  permanent deletions. The app asks for a password only when macOS requires
  one.

### Menu bar and Settings

- The menu bar widget has eight layouts. You can switch between light and dark
  themes and between English and Russian without restarting.
