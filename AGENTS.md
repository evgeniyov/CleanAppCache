# Agent instructions

These instructions apply to coding agents in this repository. Human contributors should read [CONTRIBUTING.md](CONTRIBUTING.md).

## Project
- **What.** CleanAppCache is a native macOS disk-cleaning and system-monitor utility.
- **Platform.** CleanAppCache targets macOS 13+ and builds a universal binary
  (arm64 + x86_64). Development and testing use an Apple M4 (Mac16,12)
  running macOS 27. CI runs on macOS 15.
  The x86_64 slice and macOS 13/14 are untested.
- **Language / build.** The app uses Swift, SwiftUI and Swift Package Manager.
  `Package.swift` uses swift-tools-version 5.9 with the `StrictConcurrency`
  experimental feature on the library target. CI builds on the `macos-15`
  image's default Xcode and treats warnings as errors. The Swift 6 toolchain
  uses Swift 5 language mode because the tools version is 5.9.
- **Build & run.** `python3 build.py && open CleanAppCache.app` builds a
  universal `.app` and a DMG. The script signs with the local "CleanAppCache Local"
  identity when `Scripts/make_signing_identity.sh` has created it. Otherwise it
  signs ad hoc. With `DEVELOPER_ID` and `NOTARY_PROFILE`, it signs with
  Developer ID, notarizes and staples.
- **Verify.** Run `swift build`, `swift test` and `Scripts/verify.sh`. The
  script runs the same checks as CI: invariants, warnings-as-errors build,
  tests, `build.py` and bundle checks.
- **Distribution.** The project uses Developer ID and notarization outside
  the Mac App Store. The maintainer has yet to publish a notarized release.
  The app is unsandboxed (see `entitlements.plist`) so it can read `~/Library` and
  other apps' caches, and it reads sensors through private APIs.
  `.github/workflows/release.yml` builds a release on a `v*` tag once the
  Developer ID secrets exist.

## Architecture
- `CleanAppCacheLib` is the library target and contains all business logic and UI.
- `CleanAppCache` is the thin executable and contains `@main`, `AppDelegate` and `MenuBarExtra`.
- `CleanAppCacheTests` depends on `CleanAppCacheLib`.
- The app uses MVVM. `AppState.shared` holds the long-lived view models.

### Navigation (`Views/ContentView.swift`, `NavGroup` / `Screen`)
- **System**: `storage`, `systemData`, `monitor`, `history`, `security`
- **Cleanup**: `smartCleanup`, `systemJunk`, `developer`, `privacy`,
  `largeFiles`, `duplicates`
- **Uninstaller**: `apps`, `leftovers`, `orphans`, `startup`
- `settings` opens from the sidebar footer. The app opens on `storage`.

### Theming and invariants
- `AppTheme` (`Design/ThemeManager.swift`) has two options, `light` (default) and `dark`.
- Define every colour as a `DesignTokens` member in `Design/Theme.swift` and
  read it through `Palette`. `Color(hex:)` anywhere else
  fails `Scripts/check_invariants.sh` and `DesignInvariantsTests`.
- Sizes and speeds go only through `Fmt` (`Design/Format.swift`).
  `ByteCountFormatter` fails CI.
- Every user-visible string goes through `loc.s` / `loc.f`. A new key goes into
  both `en.lproj` and `ru.lproj` with identical format specifiers. Put plurals in
  `.stringsdict`. The app displays the raw name when a key is missing.
  `Scripts/check_invariants.sh` catches a missing literal key passed to
  `loc.s` / `loc.f` / `loc.opt`, but skips interpolated keys
  (`"sec.\(id).risk"`), so those must be checked by hand.
- Tables take column widths from one `TableSpec` (`Components/Table.swift`)
  with exactly one flexible column (`width: nil`). The code does not enforce
  this convention.
- One renderer draws the menu bar widget's eight `MenuBarStyle` layouts.
  `MenuBarController.widgetCells` feeds both the status bar and the Settings
  preview, so the preview matches the real bar. Only the `stack` layout pairs
  a temperature with its load. When both are pinned, it shows the
  temperature above the load. Every other layout shows them as separate cells.

### Key services
- The app checks the `PathGuard` deny-list (`Core/PathGuard.swift`) before
  every deletion. It refuses the filesystem root and top-level directories,
  system and package-manager trees (`/usr`, `/opt/homebrew`, `/opt/local`), sensitive
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
- `RemovalCheck` (`Core/RemovalCheck.swift`) checks items before removal with
  `trashObstacle` and `deleteObstacle`. It classifies failures with these
  `RemovalObstacle` values:
  `needsAdmin` (POSIX), `privacyProtected` (TCC, Full Disk Access or App
  Management), `systemProtected` (SIP, read-only volume), `locked`, `inUse`
  and `other`. A password helps with the POSIX failure but does not help with
  the TCC failure. `RemovalReport`
  presents one toast per obstacle with its action.
- `TrashService` is the default service. It moves items to the Trash and
  shows an Undo toast. It checks every URL with `PathGuard` and pins batch
  object and parent identities before measuring sizes.
  `trashEscalating` retains those identities when handing `needsAdmin` failures to
  Finder (AppleScript `delete`), which asks for the password and moves them
  where Put Back can restore them. Undo skips those items (`Trashed.viaFinder`).
  Missing items count as `alreadyGone`, not as failures.
- `DeletionService` removes items permanently and checks every URL with
  `PathGuard`. Before reporting failure, it restores the owner's write bit
  on a read-only tree the user owns. Permission repair and rollback use pinned
  descriptors, never replacement pathnames. `deleteAsAdministrator` is the
  only method that deletes as root. It requires one password per batch and
  removes groups in order.
  `administratorTarget(for:)` limits it to app bundles in application folders, items
  inside `~/.Trash`, and an app's own entry directly inside the uninstaller's
  `~/Library` folders.
- `AppleScriptRunner` runs AppleScript in an `osascript` child process off the
  main thread and passes paths as `argv`. `runPrivileged` is the only
  `do shell script … with administrator privileges`.
- `SystemDataManager` manages local Time Machine snapshots with `tmutil`.
- `CleanupHistory.shared` keeps a persistent record of cleanups. Each record
  stores `freedBytes` for permanent deletions and `trashedBytes` for items
  moved to the Trash that are still on disk. Totals count freed space only, so emptying the Trash
  through Smart Cleanup does not count the same bytes twice. Trash-based call
  sites pass `trashedBytes`, permanent ones `freedBytes`.
- `Scanner` scans the Smart Cleanup categories. `excludedChildPaths` keeps
  the app's own log folder (`~/Library/Logs/CleanAppCache`) out of the Logs category.
  Each fresh result includes the object and parent identities from the scan.
  Cached results require a fresh scan before cleanup. Confirmations hold a fixed
  selection from one scan, including quick cleanup in the menu bar.
- `StorageManager` / `DiskCacheManager` persist invalidation before notifying
  views. Cache generations reject measurements spanning a cleanup. Open detail
  views retain visible rows as stale and discard measurements still in progress.
- `SystemMonitor` reads CPU, memory, network, disk, processes and sensors. Each
  instance owns its own `IOReportFreq`, `SMCReader` and `IOHIDThermal`. The
  in-app monitor uses `SystemMonitor.shared`. `MenuBarController` creates a
  separate instance, so they never share subscription state or delta counters.
- `AppManager` finds apps, uninstalls them with `check` followed by
  `uninstall(_:adminPrompt:)`, and reads last-opened dates from Spotlight
  (`kMDItemLastUsedDate`). Associated files
  match by bundle ID (exact or `<bundleID>.` prefix) across Caches, Preferences (and ByHost),
  Containers, non-group Application Scripts, Saved Application State,
  Logs, Application Support, HTTPStorages, WebKit and Cookies. For an app without
  a bundle ID, it uses an exact folder-name match. Two installed copies
  with the same bundle ID share their data, so neither lists it
  (`sharedDataWith`). Group Containers and app-group Application Scripts stay
  because their names do not establish exclusive ownership. Uninstall checks
  scan-time object and parent identities before ordinary and privileged deletions.
  Changed targets require a rescan. `installedInventory()` adds the IDs of bundles inside
  apps, running apps, app names and vendor tokens for Leftovers.
- `LeftoversManager` / `OrphanScanner` ask LaunchServices before treating an
  app as uninstalled, so an app run from outside `/Applications` keeps its data.
  Leftovers also skips names of installed apps and marks an ID whose vendor
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
and Finder for protected items), `AppleScriptRunner.swift` (shell, for running
`do shell script` with commands others build), and `DiskCacheManager.swift`, `Log.swift`,
`DashboardViewModel.swift`, `CleanupHistory.swift` (remove, for the app's own
housekeeping files). An exempt file that calls a family outside its set fails.
Route new deletes through `DeletionService` or `TrashService`. Add an
exemption only with a reason in the comment. A delete spelled another way (a
C wrapper, a command assembled from pieces) is not detected, so review for it.

## Safety rules
- **Trash with an Undo toast** (`TrashService`): Smart Cleanup categories,
  Large Files, Duplicates, Leftovers, Orphans, System Junk (including iPhone
  backups under `MobileSync/Backup`). Protected items go through Finder after
  a password and are put back with Finder's Put Back, not the Undo.
- **Startup** leaves the items' files in place. The "turn off" action removes a login item
  (System Events), writes a per-user launchd override for user and global
  agents (no password), and disables daemons in the system domain as root
  after one password (`StartupManager.disableDaemons`).
- **Permanent** (`DeletionService` or `tmutil`), always behind a confirmation
  that says the action is permanent: emptying the Trash (Smart Cleanup's Trash
  category), the uninstaller (bundle and associated files), Developer caches
  and build artifacts, Privacy browser data (history, cookies, site data), and Time Machine local
  snapshots. Undoing a Privacy cleanup would restore live session tokens.
  Privacy clears Firefox history inside `places.sqlite`, which also holds
  the bookmarks. Removing local snapshots requires Full Disk Access and may
  be refused.
- For single and batch uninstalls, `AppManager.uninstall(_:adminPrompt:)` first
  asks running apps to quit. It skips any app still running and keeps all its
  files. It deletes each bundle first and deletes the associated files only
  after the bundle is gone. It uses one password for bundles and data that
  need root, with each app's data still deleted after its bundle.
- The confirmation says when macOS will ask for a password. macOS shows its
  own dialog. The only root operations are
  `DeletionService.deleteAsAdministrator` and `StartupManager.disableDaemons`.
  Everything else that needs rights goes through Finder. Never `rm` system
  paths.
- Duplicates re-checks size and modification date of both the kept copy and
  the copies to delete. It skips a group whose kept copy changed.
- Full Disk Access is optional (`FullDiskAccess`). Code must handle its absence.

## Low-level notes
- CPU frequencies and GPU load come from the private IOReport library. DVFS
  tables are the `voltage-states*` properties under `AppleARMIODevice`: E-cores
  `voltage-states1-sram`, P-cores `voltage-states5-sram` (non-`-sram` variants
  hold reciprocal values and are rejected), GPU `voltage-states9` first. M4 and
  later chips store kHz. Earlier chips store Hz. The app detects the unit
  from the values.
- On Apple Silicon, only the `AppleSMCKeysEndpoint` node handles SMC key reads
  for temperatures. Opening the generic `AppleSMC` parent makes `#KEY` return 0.
  The SMC `Tp*`/`Te*`/`Ts*` average is the primary CPU figure. When SMC yields
  nothing, the fallbacks are, in order: a single named SMC key, the IOHID
  per-cluster "MTR Temp Sensor" average, and the IOHID die sensors, which read
  a few degrees lower. The GPU never falls back to the CPU value. Unavailable
  values show "—".
- For subprocess pipes, call `readDataToEndOfFile()` before
  `waitUntilExit()`. Output larger than the pipe buffer otherwise deadlocks.
- Use `macmon` as a reference when checking sensor readings.

## Code style
- Use `actor` for managers that access many filesystem locations (Scanner,
  AppManager, StorageManager, StartupManager, LeftoversManager). Use
  `@MainActor` for view models and UI-facing singletons. Use `async/await`
  and keep heavy work off the main thread.
- Keep builds free of warnings. CI treats warnings as errors.
- Write comments in present-tense English. Explain why the code has a
  constraint and what breaks if it changes. No references to design
  documents, audits, section numbers or project history.
- Commit messages describe the change and its reason. Never write "the user
  asked" or narrate how the change was produced.

## Workflow
- GitHub Actions runs the full check. The repository is public, so its macOS
  runners cost nothing. Locally, run `swift build`, the test suites for the
  area you changed and `Scripts/check_invariants.sh`, then push the commits to
  a `ci/<topic>` branch, which runs `ci.yml` (`gh run list --branch
  ci/<topic>`, `gh run watch <id>`). Once it is green, fast-forward `master`
  to the branch, push `master` and delete the branch. `Scripts/verify.sh`
  runs the same checks locally when CI is unavailable.
- CI uses the `macos-15` runner's default Xcode, whose older Swift compiler
  rejects some code the local toolchain accepts, so a change is not finished
  until its branch is green there. A red CI on `master` is fixed before
  anything else is pushed. Work that is not finished is not merged.
- Build the release DMG locally with `python3 build.py` from the tagged
  commit, so the installed app matches GitHub.
- Never force-push `master` or rewrite published history.
- Pushing a change under `.github/workflows/` needs a GitHub token with the
  `workflow` scope (`gh auth refresh -h github.com -s workflow`).
- Versions follow releases, not commits. The version is the `--version`
  default in `build.py`. The build number is the commit timestamp. A batch of
  user-visible changes ships as a new version. Move the CHANGELOG `Unreleased`
  entries under `## X.Y — YYYY-MM-DD`, bump the default, commit, tag `vX.Y`,
  push the commit and the tag, and build the DMG from that commit so the
  installed app matches GitHub. A `v*` tag runs `release.yml`. If any of the
  six signing and notarization secrets is missing, the job skips signing and
  publication and the maintainer publishes the unnotarized DMG by hand.

## Testing
- Unit tests are in `Tests/CleanAppCacheTests/`. Run `swift test`.
- Sensor tests skip hardware claims under a hypervisor
  (`TestHost.isVirtualMachine`, `kern.hv_vmm_present`). `CAC_ASSUME_VM=1`
  exercises that path on a real Mac.
- Environment switches for testing and screenshots:
  `CAC_INITIAL_SCREEN=<Screen raw value>` (for example `monitor`) opens that
  screen instead of Storage. `CAC_HIDE_FDA_BANNER` (any value) hides the Full
  Disk Access banner.
- Run the integration smoke test with `swift Scripts/integration_test.swift`.
  It uses temporary fixtures and exits nonzero on failure. Both
  `Scripts/verify.sh` and CI run it. `--probe-path` can exercise a failing size probe.

## Imported Claude Cowork project instructions
