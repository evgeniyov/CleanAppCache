# Roadmap

The work below has no scheduled dates. See [CHANGELOG.md](CHANGELOG.md) for
completed changes.

## Next

### Notarized release

- Once the Apple Developer account is ready, sign the release with a Developer
  ID certificate, notarize it and staple the notarization ticket. `build.py` and `.github/workflows/release.yml`
  already support these steps. Until then, builds use a local signature or an
  ad hoc signature.

### Tests for destructive paths

These operations delete files or change disk state and still need tests:

- Test `StartupViewModel.turnOff(_:)` and login-item removal through System
  Events. Existing tests cover `setEnabled(_:for:)`, plist parsing, label
  validation and which items the user can act on.
- Test the operations that require someone to respond to a password dialog: `DeletionService.deleteAsAdministrator`,
  the Finder request in `TrashService.trashEscalating` and
  `StartupManager.disableDaemons`. Existing tests cover only the checks on
  what these operations accept.

### Hardware and OS coverage

- Run the x86_64 slice on an Intel Mac. The build includes it, but no one has tested it on Intel.
- Run on macOS 13 and 14. The minimum deployment target is macOS 13. Testing has run the app only on
  macOS 27. CI also runs the test suite on macOS 15.
- Verify sensor readings (temperatures, CPU and GPU frequencies, GPU load) on
  more Apple silicon chips. Testing has covered one M4 Mac.

If you run the app on other hardware or macOS versions, open an issue with
the Mac model, chip, macOS version and what worked or looked wrong. Include
Monitor screenshots if they show the issue.

## Later

These changes have no timeline:

- Keyboard shortcuts for more actions (today only a few exist, such as Space
  for Quick Look), and a command palette.
- Scheduled scans, with a notification when a scan finishes or finds more
  than a chosen amount of junk. Anything that deletes would still require
  confirmation.
- Compare disk usage before and after a cleanup.
- Export a system report (HTML or PDF).
- Add old iOS software update files to System Junk.
- Add Recent Items cleanup to Privacy for applications, documents and servers.
  macOS stores these lists in `~/Library/Application Support/com.apple.sharedfilelist`.
  PathGuard blocks that path, so the cleanup needs an explicit exception.
- Automatic updates for directly downloaded builds (for example Sparkle).
- Shortcuts app actions such as "scan caches" or "check disk".
- A Finder context-menu action to scan or clean a folder.
- Add severity levels to error reports. Pass dependencies in place of some
  singletons to make the operations under "Tests for destructive paths"
  easier to test.

## Not planned

- The Mac App Store requires sandboxing and forbids private APIs. The app
  runs unsandboxed to read `~/Library` and other apps' caches. It reads
  sensors through private APIs (IOReport, SMC, IOHID).
- The interface uses flat cards and a fixed colour palette in place of
  translucent "glass" styling.
- Each screen keeps its actions in its own header in place of a window toolbar.
- Cloud backup, network scanning and Windows or Linux versions fall outside
  the scope of a local macOS disk utility.
