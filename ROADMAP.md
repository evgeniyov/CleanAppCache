# Roadmap

This is a list of planned work, not a schedule. Finished work is recorded in
[CHANGELOG.md](CHANGELOG.md).

## Next

### Notarized release

- Sign with a Developer ID certificate, notarize and staple, once the Apple
  Developer account is in place. `build.py` and `.github/workflows/release.yml`
  already support this; until then builds are signed with a local identity or
  ad-hoc.

### Tests for destructive paths

Several code paths that delete or change things on disk have no tests yet:

- Startup items: `StartupViewModel.turnOff(_:)` itself and the login-item
  removal through System Events (`setEnabled(_:for:)`, plist parsing, label
  validation and which items are actionable are tested).
- Everything behind a password dialog — `DeletionService.deleteAsAdministrator`,
  the Finder hand-off in `TrashService.trashEscalating`,
  `StartupManager.disableDaemons` — needs a person at the dialog; only the
  validation of what may reach them is tested.

### Hardware and OS coverage

- Run the x86_64 slice on an Intel Mac. It is built but untested.
- Run on macOS 13 and 14. The minimum deployment target is macOS 13, but the
  app has only been run on macOS 27; the test suite also runs in CI on
  macOS 15.
- Verify sensor readings (temperatures, CPU and GPU frequencies, GPU load) on
  more Apple silicon chips. So far they have been checked on one M4 Mac.

If you run the app on hardware or a macOS version not listed above, a report
is welcome: open an issue with the Mac model, chip, macOS version and what
worked or looked wrong (screenshots of the Monitor screen help).

## Later

Ideas that still make sense but have no timeline:

- Keyboard shortcuts for more actions (today only a few exist, such as Space
  for Quick Look), and a command palette.
- Scheduled scans, with a notification when a scan finishes or finds more
  than a chosen amount of junk. Anything that deletes would still require
  confirmation.
- Before/after comparison for a cleanup.
- Export a system report (HTML or PDF).
- System Junk: old iOS software update files.
- Privacy: clearing Recent Items (applications, documents, servers). PathGuard
  currently blocks `~/Library/Application Support/com.apple.sharedfilelist`,
  where these lists are stored, so this needs a deliberate exception.
- Automatic updates for directly downloaded builds (for example Sparkle).
- Shortcuts app actions such as "scan caches" or "check disk".
- A Finder context-menu action to scan or clean a folder.
- Error reporting with severity levels, and less reliance on singletons in
  favour of injectable dependencies, mainly to make the items under
  "Tests for destructive paths" easier to test.

## Not planned

- Mac App Store: the app is unsandboxed so it can read `~/Library` and other
  apps' caches, and it reads sensors through private APIs (IOReport, SMC,
  IOHID); the App Store allows neither.
- Translucent "glass" styling: the interface uses flat cards and a closed
  colour palette.
- A window toolbar: each screen keeps its actions in its own header.
- Cloud backup, network scanning, Windows or Linux versions: outside the scope
  of a local macOS disk utility.
