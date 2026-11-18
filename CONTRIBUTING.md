# Contributing to CleanAppCache

CleanAppCache deletes files on other people's Macs. Most of the rules below
exist so that a change cannot delete something it should not, or hide from
the user what it is about to do. Please read them before you open a pull
request.

Security problems and unexpected deletions are not public issues: report them
privately as described in [SECURITY.md](SECURITY.md).

## Building and running

Requirements: macOS with Xcode (CI uses Xcode 16, a Swift 6 toolchain) and
`python3`. `Package.swift` declares swift-tools-version 5.9, so the code
compiles in the Swift 5 language mode with the `StrictConcurrency`
experimental feature enabled. The app targets macOS 13 and later.

| Command | What it does |
| --- | --- |
| `swift build` | Debug build of the library and the app (add `--build-tests` to include the tests). |
| `swift test` | Builds and runs the XCTest suite in `Tests/CleanAppCacheTests`. |
| `python3 build.py` | Release build of a universal (arm64 + x86_64) `CleanAppCache.app` and `CleanAppCache.dmg` in the repository root. |
| `open CleanAppCache.app` | Runs the bundle `build.py` produced. |
| `Scripts/check_invariants.sh` | Source checks the compiler cannot make (see below). Needs no toolchain. |
| `Scripts/verify.sh` | Everything CI runs, in the same order. |

`build.py` signs with a local "CleanAppCache Local" identity if
`Scripts/make_signing_identity.sh` has created one, and ad-hoc otherwise. A
stable local identity keeps macOS privacy grants (Full Disk Access, Apple
Events) attached to the app across rebuilds; an ad-hoc signature changes on
every build. `DEVELOPER_ID` and `NOTARY_PROFILE` (or `--developer-id` and
`--notary-profile`) produce a Developer ID signed, notarized and stapled
build; contributors do not need them.

### Before you open a pull request

Run `Scripts/verify.sh` and make sure it ends with "Everything passed". It
runs, in order:

1. `Scripts/check_invariants.sh`;
2. `swift build --build-tests -Xswiftc -warnings-as-errors`;
3. `swift test --skip-build`;
4. `python3 build.py`;
5. `Scripts/check_bundle.sh CleanAppCache.app` (signature, hardened runtime,
   entitlements, universal binary, usage descriptions in `Info.plist`).

CI (`.github/workflows/ci.yml`) runs the invariants on Linux and the rest on a
macOS 15 runner. The runner is a virtual machine with no SMC, IOReport or
battery, so the hardware assertions in `SensorsTests` are skipped there. They
use `TestHost.isVirtualMachine` (`kern.hv_vmm_present`); set `CAC_ASSUME_VM=1`
to exercise the virtual-machine path on a real Mac.

## Rules that are not negotiable

### Every delete of user data goes through PathGuard

`Core/PathGuard.swift` is a deny-list checked before every deletion. It
refuses the filesystem root and top-level directories, system and
SIP-protected paths, package-manager trees, the home folder and its standard
folders, other users' homes, credentials and other sensitive user data, cloud
storage, backups, media libraries, virtual machine bundles and anything inside
a `.git` directory. It resolves symlinks and `..` before it compares.

The guard only helps if nothing goes around it. All user-data deletions must
call one of two services:

- `TrashService.trash` moves items to the Trash and can restore them. This is
  the default.
- `DeletionService.delete` removes items permanently.

Both run `PathGuard` first and report blocked paths separately from failures.
Never call `FileManager.removeItem`, `trashItem`, `unlink`, `rm` or similar
directly from a feature.

`Tests/CleanAppCacheTests/DeletionRoutingTests.swift` enforces this. It scans
every Swift file under `Sources` (comments stripped, string literals kept) for
these spellings, grouped into families:

- FileManager remove: `removeItem(`, `replaceItemAt(`, `replaceItem(`
- FileManager trash: `trashItem(`
- POSIX: `unlink(`, `unlinkat(`, `rmdir(`, `removefile(`
- NSWorkspace: `.recycle(`
- Shell: `/bin/rm`, `"rm"`, `"-delete"`, `do shell script`

A file may use a family only if it is listed in the test's `exemptions` table
for that family:

| File | Allowed | Why |
| --- | --- | --- |
| `DeletionService.swift` | FileManager remove | The permanent-delete routing point. |
| `TrashService.swift` | FileManager trash | The move-to-Trash routing point. |
| `AppManager.swift` | FileManager remove, shell | Removes an `.app` bundle after `PathGuard.reject`; the administrator force-delete runs `rm` through AppleScript after the same validation. |
| `DiskCacheManager.swift` | FileManager remove | The app's own size cache. |
| `Log.swift` | FileManager remove | The app's own log files. |
| `DashboardViewModel.swift` | FileManager remove | The app's own scan cache. |
| `CleanupHistory.swift` | FileManager remove | A stale, corrupt copy of the app's own history file. |

Apart from the two services, the exemptions cover the uninstaller's bundle
removal and the app deleting its own housekeeping files. A new exemption needs
a strong reason in the pull request and a comment in the table. The scan finds
only these spellings; a delete hidden behind a wrapper or a command built from
pieces will not be caught, and review has to find it instead. Do not write
code that relies on that gap.

`PathGuardTests` covers the deny-list. If you change `PathGuard`, add a test
for each path you allow or refuse.

### Prefer the Trash, and say so when you cannot

Use `TrashService` and the Undo toast unless there is a concrete reason
something cannot be recovered. Current permanent deletions are: emptying the
Trash, the uninstaller, Developer caches and build artifacts, Privacy browser
data (restoring cookies would hand back live session tokens), Time Machine
local snapshots and the administrator force-delete. Each of them sits behind a
confirmation.

If your change deletes permanently, the confirmation text must say plainly
that the items cannot be restored. Never escalate to administrator rights
without an explicit prompt.

### Localization: English and Russian together

Every user-visible string goes through `loc.s`, `loc.f` or `loc.opt`
(`Design/Localizer.swift`). A new key goes into **both**
`Sources/CleanAppCacheLib/Resources/en.lproj/Localizable.strings` and
`ru.lproj/Localizable.strings`, with the same `%` format specifiers in the same
order. Plurals go in `Localizable.stringsdict`, again in both languages.

A missing key is not an error at runtime: the interface shows the raw key
name. `Scripts/check_invariants.sh` therefore fails when:

- the English and Russian key sets differ or a key is duplicated;
- a literal key used in code is missing from the strings file;
- a key's format specifiers differ between the two languages;
- the `.stringsdict` plural keys differ.

If you do not write Russian, add your best attempt and say so in the pull
request; do not leave the key out.

### Colours come from the palette

Every colour is a `DesignTokens` member in `Design/Theme.swift` and is read
through `Palette`. `Color(hex:)` may appear only in `Theme.swift`. Both
`check_invariants.sh` and `DesignInvariantsTests` fail otherwise. A new colour
needs a token with a value for both the light and the dark theme.

### Sizes go through Fmt

Byte counts and transfer speeds are formatted only by `Fmt`
(`Design/Format.swift`). Do not use `ByteCountFormatter`: it follows the system
locale instead of the in-app language setting. Both checks above enforce this.

### Zero warnings

CI builds with `-warnings-as-errors`. Fix warnings rather than silencing them.
Heavy work belongs off the main thread; view models are `@MainActor`, and
shared managers that touch the filesystem broadly are actors.

## Tests

- Tests that touch the filesystem create a uniquely named scratch directory
  (or file) under `FileManager.default.temporaryDirectory` (for example
  `"dup_\(UUID().uuidString)"`) and remove it when the test ends; prefer
  `defer`, `tearDown` or `addTeardownBlock`, which also run when an assertion
  throws. They never create, change or delete anything in the real
  home folder. Reading home paths to check that `PathGuard` refuses them, as
  `PathGuardTests` does, is fine.
- Code that stores state takes its location as a parameter so tests can point
  it at a scratch directory, as `CleanupHistory(directory:)` does.
- Tests never reach the user's Trash or app state. TrashService accepts a
  scratch mover for round-trip tests; the system mover and AppleScript refuse
  to run inside XCTest. App state singletons use a unique temporary root, and
  cache/layout tests inject their own directory or disable persistence and sampling.
- Tests of permanent deletion (`ScannerTests`, `AppManagerTests`) delete only
  inside their scratch directories.
- Sensor tests that assert hardware facts call `skipUnlessRealHardware` (or
  check `TestHost.isVirtualMachine`) so they skip on virtual machines instead
  of failing.
- Add or update tests for any change in behaviour, and above all for anything
  that selects or deletes files.

## Code comments

Comments explain constraints the code cannot show on its own: why an order of
operations matters, what a platform API really returns, what would break if a
line were removed. Write them in English, in the present tense, about the code
as it is. Do not narrate history ("previously", "we changed this because"),
and do not refer to tickets, chats or documents a reader cannot see.
Change history belongs in commit messages.

## Commits and pull requests

- A commit message describes the change itself: a short summary line in the
  imperative mood ("Skip a duplicate group whose kept copy changed"), then,
  if needed, a body explaining why. Keep unrelated changes in separate commits.
- Fill in the pull request template: what the change does, how you tested it
  (macOS version, Mac model, the screens you exercised), and the checklist.
- A change to the interface includes screenshots, in both the light and dark
  themes when it affects colours, and in both languages when it changes text
  whose length differs noticeably.
- Keep pull requests focused. Large or behaviour-changing work is easier to
  land after a short discussion in an issue.

## Reporting sensor results

Temperatures, CPU frequencies and GPU load are read through private or
undocumented interfaces (SMC, IOHID, IOReport) whose keys and layouts vary by
chip and macOS version. The app is developed on an Apple M4 Mac; other chips,
Intel Macs and macOS 13 and 14 are untested. Values the app cannot read show
"—", which is expected behaviour rather than a bug.

Reports from other hardware are useful. Please include:

- the Mac model identifier (`sysctl hw.model`) and the chip;
- the macOS version and build (`sw_vers`);
- whether the app was built from source or downloaded, and whether it runs in
  a virtual machine;
- what the app shows (the Monitor screen or the menu-bar widget; a screenshot
  helps) and which values show "—";
- the same readings from a reference tool, such as `sudo powermetrics` or
  `macmon`, taken at the same moment under the same load, with the tool's name
  and version.

Readings change from second to second, so compare samples taken together
rather than at different times. Different sensors can legitimately disagree by
a few degrees; for example, a die sensor read through IOHID can sit below the
SMC junction temperature another tool reports. Say which sensor the reference
tool uses if you know.

## Code of conduct

Be respectful and assume good faith. Criticise code and decisions, not the
people who wrote them. Keep discussion on topic, and remember that
contributors and users may be writing in a second language. Harassment,
insults and personal attacks are not welcome in any project space. The
maintainer may edit, hide or remove comments, close discussions, and block
participants who do not follow these expectations.

## License

By contributing, you agree that your contributions are licensed under the MIT
License that covers the project (see [LICENSE](LICENSE)).
