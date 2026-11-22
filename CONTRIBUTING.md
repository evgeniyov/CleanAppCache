# Contributing to CleanAppCache

CleanAppCache deletes files on other people's Macs. These rules prevent
unintended deletions and require the app to tell users what it will do. Read
them before you open a pull request.

Report security problems and unexpected deletions privately as described in [SECURITY.md](SECURITY.md).

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
`Scripts/make_signing_identity.sh` has created one. Otherwise it signs ad hoc. A
stable local identity keeps macOS privacy grants (Full Disk Access, Apple
Events) attached to the app across rebuilds. An ad hoc signature changes on every
build. `DEVELOPER_ID` and `NOTARY_PROFILE` (or `--developer-id` and
`--notary-profile`) produce a Developer ID signed, notarized and stapled
build. Contributors do not need them.

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
battery. `SensorsTests` uses `TestHost.isVirtualMachine` (`kern.hv_vmm_present`)
to skip hardware assertions there. Set `CAC_ASSUME_VM=1` to exercise the
virtual-machine path on a real Mac.

## Required checks and practices

### Every deletion of user data goes through PathGuard

`Core/PathGuard.swift` is the deny-list the app checks before every deletion. It
refuses the filesystem root and top-level directories, system and
SIP-protected paths, package-manager trees, the home folder and its standard
folders, other users' homes, credentials and other sensitive user data, cloud
storage, backups, media libraries, virtual machine bundles and anything inside
a `.git` directory. It resolves symlinks and `..` before it compares paths.

Use one of these services for every deletion of user data:

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
| `DeletionService.swift` | FileManager remove, shell | Deletes files permanently, including the administrator `rm` it builds after `administratorTarget(for:)`. |
| `TrashService.swift` | FileManager trash, Finder | Moves files to the Trash and hands protected items to Finder after PathGuard. |
| `UvCacheCleaner.swift` | uv cache clean | Runs `uv cache clean` under uv's own cache lock, after PathGuard and scan-identity checks. |
| `AppleScriptRunner.swift` | shell | Runs the administrator commands that `DeletionService` builds. |
| `DiskCacheManager.swift` | FileManager remove | The app's own size cache. |
| `Log.swift` | FileManager remove | The app's own log files. |
| `DashboardViewModel.swift` | FileManager remove | The app's own scan cache. |
| `CleanupHistory.swift` | FileManager remove | A stale, corrupt copy of the app's own history file. |

The uninstaller removes bundles through `DeletionService`, and the remaining
exemptions cover the app's own files. Explain why a new exemption is necessary in the pull
request and add a comment in the table. The scan checks only the spellings
listed above. Reviewers must catch deletions made through a wrapper or a
command built from pieces. Do not write code that relies on this gap.

`PathGuardTests` covers the deny-list. If you change `PathGuard`, add a test
for each path you allow or refuse.

### Prefer the Trash, and say so when you cannot

Use `TrashService` and the Undo toast unless there is a concrete reason
an item cannot be recovered. The app permanently deletes the following: emptying the
Trash, the uninstaller, Developer caches and build artifacts, Privacy browser
data (restoring cookies would hand back live session tokens), Time Machine
local snapshots and the administrator force-delete. The app asks for confirmation for each.

If your change deletes permanently, the confirmation text must say plainly
that the items cannot be restored. Never escalate to administrator rights
without an explicit prompt.

### English and Russian localization

Every user-visible string goes through `loc.s`, `loc.f` or `loc.opt`
(`Design/Localizer.swift`). A new key goes into **both**
`Sources/CleanAppCacheLib/Resources/en.lproj/Localizable.strings` and
`ru.lproj/Localizable.strings`, with the same `%` format specifiers in the same
order. Plurals go in `Localizable.stringsdict`, again in both languages.

The interface displays the raw key name if a translation is missing.
`Scripts/check_invariants.sh` fails when:

- the English and Russian key sets differ or a key is duplicated;
- a literal key used in code is missing from the strings file;
- a key's format specifiers differ between the two languages;
- the `.stringsdict` plural keys differ.

If you do not write Russian, add your best attempt and say so in the pull
request. Include the key in both languages.

### Colours come from the palette

Every colour is a `DesignTokens` member in `Design/Theme.swift` and is read
through `Palette`. `Color(hex:)` may appear only in `Theme.swift`. Both
`check_invariants.sh` and `DesignInvariantsTests` fail otherwise. A new colour
needs a token with a value for both the light and the dark theme.

### Sizes go through Fmt

Use only `Fmt` (`Design/Format.swift`) to format byte counts and transfer
speeds. Do not use `ByteCountFormatter`. It uses the system locale instead of
the in-app language setting. Both checks above enforce this.

### Zero warnings

CI builds with `-warnings-as-errors`. Fix warnings rather than silencing them.
Run heavy work off the main thread. Mark view models `@MainActor` and use
actors for shared managers that access many filesystem locations.

## Tests

- Tests that touch the filesystem create a uniquely named scratch directory
  (or file) under `FileManager.default.temporaryDirectory` (for example
  `"dup_\(UUID().uuidString)"`) and remove it when the test ends. Prefer
  `defer`, `tearDown` or `addTeardownBlock`, which also run when an assertion
  throws. They never create, change or delete anything in the real
  home folder. Reading home paths to check that `PathGuard` refuses them, as
  `PathGuardTests` does, is fine.
- Code that stores state takes its location as a parameter so tests can point
  it at a scratch directory, as `CleanupHistory(directory:)` does.
- Tests never reach the user's Trash or app state. TrashService accepts a
  scratch mover for round-trip tests. The system mover and AppleScript refuse
  to run inside XCTest. App state singletons use a unique temporary root, and
  cache/layout tests inject their own directory or disable persistence and sampling.
- Tests of permanent deletion (`ScannerTests`, `AppManagerTests`) delete only
  inside their scratch directories.
- Sensor tests that assert hardware facts call `skipUnlessRealHardware` (or
  check `TestHost.isVirtualMachine`) to skip tests on virtual machines.
- Add or update tests for any change in behaviour, and above all for anything
  that selects or deletes files.

## Code comments

Use comments to explain constraints the code cannot show. Explain why
operations run in a particular order, what a platform API returns or what
would break if someone removed a line. Write them in English, in the present tense, about the code
as it is. Do not narrate history ("previously", "we changed this because"),
and do not refer to tickets, chats or documents a reader cannot see.
Change history belongs in commit messages.

## Commits and pull requests

- Start the commit message with a short summary in the imperative mood, such
  as "Skip a duplicate group whose kept copy changed". Add a body if you need
  to explain why. Keep unrelated changes in separate commits.
- Fill in the pull request template. Describe what changed and how you tested
  it, including macOS version, Mac model and the screens you tested. Complete
  the checklist.
- A change to the interface includes screenshots, in both the light and dark
  themes when it affects colours, and in both languages when it changes text
  whose length differs noticeably.
- Keep pull requests focused. Discuss large changes and changes to behaviour briefly in an issue to make
  them easier to merge.

## Reporting sensor results

Monitor reads temperatures, CPU frequencies and GPU load through private or
undocumented interfaces (SMC, IOHID, IOReport) whose keys and layouts vary by
chip and macOS version. Development takes place on an Apple M4 Mac. Other chips, Intel Macs and
macOS 13 and 14 are untested. The app shows "—" when it cannot read a value.

When reporting readings from other hardware, include:

- the Mac model identifier (`sysctl hw.model`) and the chip;
- the macOS version and build (`sw_vers`);
- whether the app was built from source or downloaded, and whether it runs in
  a virtual machine;
- what the app shows (a screenshot of the Monitor screen or menu bar widget helps) and which values show "—";
- the same readings from a reference tool, such as `sudo powermetrics` or
  `macmon`, taken at the same moment under the same load, with the tool's name
  and version.

Readings change from second to second. Compare samples taken at the same
time. Different sensors can differ by a few degrees. For example, an IOHID
die sensor can report a lower value than another tool's SMC junction
temperature. Say which sensor the reference
tool uses if you know.

## Code of conduct

Be respectful and assume good faith. Keep criticism focused on code and decisions. Stay on topic and remember that
contributors and users may be writing in a second language. Do not harass, insult or attack people anywhere in the project. The
maintainer may edit, hide or remove comments, close discussions, and block
participants who break these rules.

## License

By contributing, you agree to license your contributions under the
project's MIT License. See [LICENSE](LICENSE).
