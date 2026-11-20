# Agent Instructions

This file gives AI coding agents the rules and context for working in this repository; human contributors should read [CONTRIBUTING.md](CONTRIBUTING.md).

## Project
- **What**: CleanAppCache, a native macOS disk-cleaning and system-monitor utility.
- **Platform**: macOS 13+, universal binary (arm64 + x86_64). Developed and
  tested on an Apple M4 (Mac16,12) running macOS 27, and in CI on macOS 15.
  The x86_64 slice and macOS 13/14 are untested.
- **Language / build**: Swift and SwiftUI, Swift Package Manager.
  `Package.swift` uses swift-tools-version 5.9 with the `StrictConcurrency`
  experimental feature on the library target; CI builds on the `macos-15`
  image's default Xcode and treats warnings as errors. The Swift 6 toolchain
  uses Swift 5 language mode because the tools version is 5.9.
- **Build & run**: `python3 build.py && open CleanAppCache.app` builds a
  universal `.app` and a DMG. It signs with the local "CleanAppCache Local"
  identity when `Scripts/make_signing_identity.sh` has created it, otherwise
  ad-hoc; with `DEVELOPER_ID` and `NOTARY_PROFILE` it signs with Developer ID,
  notarizes and staples.
- **Verify**: `swift build`, `swift test`, and `Scripts/verify.sh`, which
  mirrors CI (invariants, warnings-as-errors build, tests, `build.py`, bundle
  checks).
- **Distribution**: Developer ID and notarization, not the Mac App Store; no
  notarized release has been published yet. The
  app is unsandboxed (see `entitlements.plist`) so it can read `~/Library` and
  other apps' caches, and it reads sensors through private APIs.
  `.github/workflows/release.yml` builds a release on a `v*` tag once the
  Developer ID secrets exist.

## Architecture
- `CleanAppCacheLib`: library target with all business logic and UI.
- `CleanAppCache`: thin executable (`@main`), `AppDelegate` and `MenuBarExtra`.
- `CleanAppCacheTests` depends on `CleanAppCacheLib`.
- MVVM; `AppState.shared` holds the long-lived view models.

### Navigation (`Views/ContentView.swift`, `NavGroup` / `Screen`)
- **System**: `storage`, `systemData`, `monitor`, `history`, `security`
- **Cleanup**: `smartCleanup`, `systemJunk`, `developer`, `privacy`,
  `largeFiles`, `duplicates`
- **Uninstaller**: `apps`, `leftovers`, `orphans`, `startup`
- `settings` opens from the sidebar footer. The app opens on `storage`.

### Theming and invariants
- `AppTheme` (`Design/ThemeManager.swift`): `light` (default) or `dark`.
- The palette is closed: every colour is a `DesignTokens` member in
  `Design/Theme.swift`, read through `Palette`. `Color(hex:)` anywhere else
  fails `Scripts/check_invariants.sh` and `DesignInvariantsTests`.
- Sizes and speeds go only through `Fmt` (`Design/Format.swift`);
  `ByteCountFormatter` fails CI.
- Every user-visible string goes through `loc.s` / `loc.f`. A new key goes into
  both `en.lproj` and `ru.lproj` with identical format specifiers (plurals in
  `.stringsdict`); a missing key renders as its raw name at runtime, not as an
  error. `Scripts/check_invariants.sh` catches a missing literal key passed to
  `loc.s` / `loc.f` / `loc.opt`, but skips interpolated keys
  (`"sec.\(id).risk"`), so those must be checked by hand.
- Tables take column widths from one `TableSpec` (`Components/Table.swift`)
  with exactly one flexible column (`width: nil`). This is a convention; the
  code does not enforce it.
- Menu-bar widget: eight `MenuBarStyle` layouts drawn by one renderer.
  `MenuBarController.widgetCells` feeds both the status bar and the Settings
  preview, so the preview matches the real bar. Only the `stack` layout pairs
  a temperature with its load: when both are pinned, the temperature becomes
  the upper line above that load; every other layout shows them as separate
  cells.

### Key services
- `PathGuard` (`Core/PathGuard.swift`): a deny-list checked before every
  delete. It refuses the filesystem root and top-level directories, system and
  package-manager trees (`/usr`, `/opt/homebrew`, `/opt/local`), sensitive
  `/Library` subtrees, the home folder and its standard folders, other users'
  homes and `/Users/Shared`, credentials and personal data stores (keychains,
  Mail, Messages, SSH/GPG and cloud credentials), iCloud Drive and
  CloudStorage folders, Time Machine backups, volume metadata, media-library
  packages, virtual machine bundles (`.utm`, `.pvm`, `.vmwarevm`) and anything
  inside `.git`, including `/System/Library/Caches` (SIP). It resolves
  symlinks and `..` and compares case-insensitively on path-component
  boundaries. A caller may pass `allowing: [.launchdJob]` to reach a single
  job plist in `/Library/LaunchAgents|LaunchDaemons` or a helper in
  `/Library/PrivilegedHelperTools` (Startup and Orphans only).
- `RemovalCheck` (`Core/RemovalCheck.swift`): preflight (`trashObstacle`,
  `deleteObstacle`) and failure classification into `RemovalObstacle`:
  `needsAdmin` (POSIX; a password helps), `privacyProtected` (TCC: Full Disk
  Access or App Management; a password does not help), `systemProtected`
  (SIP, read-only volume), `locked`, `inUse`, `other`. `RemovalReport`
  presents one toast per obstacle with its action.
- `TrashService`: the default route (move to Trash, Undo toast); screens every
  URL with `PathGuard` and pins batch object/parent identities before sizing.
  `trashEscalating` retains those identities when handing `needsAdmin` failures to
  Finder (AppleScript `delete`), which asks for the password and moves them
  where Put Back finds them; Undo skips those (`Trashed.viaFinder`). Missing
  items count as `alreadyGone`, not as failures.
- `DeletionService`: permanent removal; screens every URL with `PathGuard`.
  Restores the owner's write bit on a read-only tree the user owns before
  giving up. Permission repair and rollback use pinned descriptors, never
  replacement pathnames. `deleteAsAdministrator` is the app's only root delete: one
  password for a batch, groups removed in order, limited by
  `administratorTarget(for:)` to app bundles in application folders, items
  inside `~/.Trash`, and an app's own entry directly inside the uninstaller's
  `~/Library` folders.
- `AppleScriptRunner`: runs AppleScript in an `osascript` child process (paths
  as `argv`, off the main thread); `runPrivileged` is the only
  `do shell script … with administrator privileges`.
- `SystemDataManager`: Time Machine local snapshots via `tmutil`.
- `CleanupHistory.shared`: persistent journal of cleanups. Each record keeps
  `freedBytes` (deleted for good) apart from `trashedBytes` (moved to the
  Trash, still on disk); totals count freed space only, so emptying the Trash
  through Smart Cleanup does not count the same bytes twice. Trash-based call
  sites pass `trashedBytes`, permanent ones `freedBytes`.
- `Scanner`: Smart Cleanup categories. `excludedChildPaths` keeps the app's
  own log folder (`~/Library/Logs/CleanAppCache`) out of the Logs category.
  Every fresh candidate carries a scan-time object/parent identity; cached
  results require a fresh scan before cleanup. Confirmations hold a fixed
  selection from one scan, including quick cleanup in the menu bar.
- `StorageManager` / `DiskCacheManager`: invalidation persists before notifying
  views. Cache generations reject measurements spanning a cleanup; open detail
  views retain visible rows as stale and discard their in-flight work.
- `SystemMonitor`: CPU, memory, network, disk, processes, sensors. Each
  instance owns its own `IOReportFreq`, `SMCReader` and `IOHIDThermal`. The
  in-app monitor uses `SystemMonitor.shared`; `MenuBarController` creates a
  separate instance, so they never share subscription state or delta counters.
- `AppManager`: app discovery, uninstall (`check` then `uninstall(_:adminPrompt:)`),
  last-opened dates from Spotlight (`kMDItemLastUsedDate`). Associated files
  match by bundle ID (exact or `<bundleID>.` prefix) across Caches, Preferences (and ByHost),
  Containers, non-group Application Scripts, Saved Application State,
  Logs, Application Support, HTTPStorages, WebKit and Cookies; an app without a
  bundle ID falls back to an exact folder-name match. Two installed copies
  with the same bundle ID share their data, so neither lists it
  (`sharedDataWith`). Group Containers and app-group Application Scripts stay
  because their names do not establish exclusive ownership. Uninstall checks
  scan-time object and parent identities before ordinary and privileged deletes;
  changed targets require a rescan. `installedInventory()` adds the ids of bundles inside
  apps, running apps, app names and vendor tokens for Leftovers.
- `LeftoversManager` / `OrphanScanner`: ask LaunchServices before treating an
  app as uninstalled, so an app run from outside `/Applications` keeps its data.
  Leftovers also skips names of installed apps and marks an id whose vendor
  still has an app installed as `uncertain` (never selected in bulk). Orphans
  revalidate the selected identity and missing-owner/binary reason before removal.

### DeletionRoutingTests
`Tests/CleanAppCacheTests/DeletionRoutingTests.swift` scans `Sources/` (with
comments stripped, string literals kept) for destructive API spellings grouped
into families: FileManager remove/replace, FileManager trash, POSIX
`unlink`/`rmdir`/`removefile`, NSWorkspace recycle, shell removal (`rm`,
`find -delete`, AppleScript `do shell script`) and AppleScript addressed to
Finder. Exemptions are per file and per family: `DeletionService.swift`
(remove, and shell for the administrator `rm`), `TrashService.swift` (trash,
and Finder for protected items), `AppleScriptRunner.swift` (shell: it runs
`do shell script` for commands others build), and `DiskCacheManager.swift`, `Log.swift`,
`DashboardViewModel.swift`, `CleanupHistory.swift` (remove, for the app's own
housekeeping files). An exempt file that calls a family outside its set fails.
Route new deletes through `DeletionService` or `TrashService`; add an
exemption only with a reason in the comment. A delete spelled another way (a
C wrapper, a command assembled from pieces) is not detected, so review for it.

## Safety rules
- **Trash with an Undo toast** (`TrashService`): Smart Cleanup categories,
  Large Files, Duplicates, Leftovers, Orphans, System Junk (including iPhone
  backups under `MobileSync/Backup`). Protected items go through Finder after
  a password and are put back with Finder's Put Back, not the Undo.
- **Startup** changes nothing on disk: "turn off" removes a login item
  (System Events), writes a per-user launchd override for user and global
  agents (no password), and disables daemons in the system domain as root
  after one password (`StartupManager.disableDaemons`).
- **Permanent** (`DeletionService` or `tmutil`), always behind a confirmation
  that says the action is permanent: emptying the Trash (Smart Cleanup's Trash
  category), the uninstaller (bundle and associated files), Developer caches
  and build artifacts, Privacy browser data (history, cookies, site data; an
  Undo would restore live session tokens; Firefox history is cleared inside
  `places.sqlite`, which also holds the bookmarks), and Time Machine local
  snapshots (needs Full Disk Access and may be refused).
- Uninstall ordering (`AppManager.uninstall(_:adminPrompt:)`, single and
  batch alike): running apps are asked to quit first and a still-running one
  is skipped whole; each bundle goes before its associated files, which are
  deleted only once the bundle is gone; bundles and data that need root are
  deleted under one password, each app's data chained after its bundle.
- Escalation is never silent: the confirmation says when a password will be
  asked for, and macOS shows its own dialog. The only root operations are
  `DeletionService.deleteAsAdministrator` and `StartupManager.disableDaemons`;
  everything else that needs rights goes through Finder. Never `rm` system
  paths.
- Duplicates re-checks size and modification date of both the kept copy and
  the copies to delete; a group whose kept copy changed is skipped.
- Full Disk Access is optional (`FullDiskAccess`); code must handle its absence.

## Low-level notes
- CPU frequencies and GPU load come from the private IOReport library. DVFS
  tables are the `voltage-states*` properties under `AppleARMIODevice`: E-cores
  `voltage-states1-sram`, P-cores `voltage-states5-sram` (non-`-sram` variants
  hold reciprocal values and are rejected), GPU `voltage-states9` first. M4 and
  later store kHz, earlier chips Hz; the unit is detected from the values.
- Temperatures: on Apple Silicon only the `AppleSMCKeysEndpoint` node services
  SMC key reads; opening the generic `AppleSMC` parent makes `#KEY` return 0.
  The SMC `Tp*`/`Te*`/`Ts*` average is the primary CPU figure. When SMC yields
  nothing, the fallbacks are, in order: a single named SMC key, the IOHID
  per-cluster "MTR Temp Sensor" average, and the IOHID die sensors, which read
  a few degrees lower. The GPU never falls back to the CPU value. Unavailable
  values show "—".
- Subprocess pipes: call `readDataToEndOfFile()` before `waitUntilExit()`, or
  output larger than the pipe buffer deadlocks.
- `macmon` is a useful reference for checking sensor readings.

## Code style
- `actor` for managers that touch the filesystem broadly (Scanner, AppManager,
  StorageManager, StartupManager, LeftoversManager); `@MainActor` for view
  models and UI-facing singletons; `async/await`, heavy work off the main thread.
- Zero warnings: CI builds with warnings as errors.
- Comments are present-tense English and state constraints: why the code is
  the way it is and what breaks if it changes. No references to design
  documents, audits, section numbers or project history.
- Commit messages describe the change and its reason. Never write "the user
  asked" or narrate how the change was produced.

## Workflow
- A finished change is committed and pushed to `master` as soon as
  `Scripts/verify.sh` passes; nothing verified stays only on the local
  machine. Work that is not finished or not green is not pushed.
- A multi-step change that cannot stay green between its steps lives on a
  branch and is fast-forwarded into `master` once it verifies.
- After a push, CI is checked (`gh run list`, `gh run watch <id>`). CI uses
  the `macos-15` runner's default Xcode, whose older Swift compiler rejects
  some code the local toolchain accepts. Fix a red CI before pushing anything
  else.
- `master` is never force-pushed and published history is not rewritten.
- Pushing a change under `.github/workflows/` needs a GitHub token with the
  `workflow` scope (`gh auth refresh -h github.com -s workflow`).
- Versions follow releases, not commits. The version is the `--version`
  default in `build.py`; the build number is the commit timestamp. A batch of
  user-visible changes ships as a new version: move the CHANGELOG `Unreleased`
  entries under `## X.Y — YYYY-MM-DD`, bump the default, commit, tag `vX.Y`,
  push the commit and the tag, and build the DMG from that commit so the
  installed app matches GitHub. A `v*` tag runs `release.yml`. If any of the
  six signing and notarization secrets is missing, the job skips signing and
  publication and the maintainer publishes the unnotarized DMG by hand.

## Testing
- Unit tests live in `Tests/CleanAppCacheTests/`; run `swift test`.
- Sensor tests skip hardware claims under a hypervisor
  (`TestHost.isVirtualMachine`, `kern.hv_vmm_present`); `CAC_ASSUME_VM=1`
  exercises that path on a real Mac.
- Environment switches for testing and screenshots:
  `CAC_INITIAL_SCREEN=<Screen raw value>` (for example `monitor`) opens that
  screen instead of Storage; `CAC_HIDE_FDA_BANNER` (any value) hides the Full
  Disk Access banner.
- Integration smoke script: `swift Scripts/integration_test.swift`.
  It uses temporary fixtures and exits nonzero on failure; it runs in both
  `Scripts/verify.sh` and CI. `--probe-path` can exercise a failing size probe.

## Imported Claude Cowork project instructions
