---
name: verify-cleanappcache
description: Build and verify CleanAppCache through its native macOS window using Accessibility by PID. Use after user-visible changes to drive the Audit copy and capture behavior and filesystem evidence.
---

# Verify CleanAppCache

## Safety rules

- Never press a clean, delete, move-to-Trash, uninstall, empty-Trash, or Startup “turn off” or disable control against real user data.
- Only Large Files and Duplicates may run a destructive journey, and only against fixtures the skill creates in scratch. Use **Profiles** → **Choose search folder…** to scope the search. Never use **Save search profile…**, which writes a profile. Confirm the scope and every selected item before a mutation.
- Trashed fixtures enter the user's real Trash. Use the Undo toast and verify the files at their original paths. Cleanup only lists run-ID entries in Trash. If it finds an entry or a fixture is missing from scratch, it prints the expected fixture names for the operator to check and remove in Finder. A denied listing is reported as unverified.
- For Smart Cleanup, uninstaller, Startup, Privacy, System Junk, Developer, Leftovers, and Orphans, limit the journey to read-only actions. If a confirmation is already visible, capture the permanent-deletion or password wording and dismiss it with Cancel or Escape.
- Before opening any screen, check its on-appear behavior in the view source. Use Monitor for startup. Large Files defaults to Home and waits for Scan. Duplicates probes Downloads on appear. Storage measures the real disk and may encounter protected folders while building its breakdown.

## Launch

This skill uses `${MACOS_GUI_DRIVE_DIR:-$HOME/.bb/skills/macos-gui-drive}/scripts/macos-gui-drive`. Read that skill for the desktop driving and evidence commands.

```bash
cac="$PWD/.bb/skills/verify-cleanappcache/scripts/cac-verify"
export CAC_VERIFY_RUN="$("$cac" new)"
"$cac" build
"$cac" launch --screen monitor
"$cac" doctor
"$cac" paths
```

Use the same run ID, `TMPDIR` and driver location in later shells. Set the evidence location before build. Build records it and marks the new scratch directory with its run ID, filesystem identity and creation time. Build stages the current Swift package and bundle inputs in scratch, runs the repo's `python3 build.py`, and keeps the normal app bundle and DMG there. The repo script has no app-only option. The wrapper copies the app to `CleanAppCache Audit.app`, sets the ID to `com.cleanappcache.CleanAppCache.Audit`, changes its bundle names to `CleanAppCache Audit` and re-signs it ad hoc. Its main SwiftUI window title remains `CleanAppCache`.

The driver uses LaunchServices through `NSWorkspace.openApplication`. It receives the new PID from LaunchServices and the app stays running after the shell exits. Launch passes `CAC_INITIAL_SCREEN` and `CAC_HIDE_FDA_BANNER=1`. The arguments `-app.language en -AppleLanguages '(en)'` select English in `Localizer` and app-owned native controls. System services can still use the system language. Launch checks that the console is usable before opening the app. It waits for the main AX window and verifies capture. On a fresh Audit domain, complete onboarding with `"$cac" press AXButton 'Get Started'` after capturing it.

If the main window is initially missing, launch checks the desktop again while activating Audit and tries the **CleanAppCache** item in the app's window menu. The item has the SwiftUI window title. The driver searches menus by AX role and item name, regardless of the menu heading's language.

## Doctor

`"$cac" doctor` checks host permissions, the console and display, and the recorded Audit executable. It requires a layer-0 window for that PID, an actual `AXWindow` in its Accessibility tree, and a successful temporary window capture. It also reports the Info.plist version and checks the build against the saved revision and current HEAD timestamp. A locked Mac or sleeping display gets its own instruction to unlock or wake the Mac and rerun. Stop driving and record the output on a failure. Before launch, Doctor reports the absent PID and window.

## Drive

Follow the [feature map](features/README.md). Use `cac-verify` for project actions so its guard runs. It checks the actual Accessibility control resolved by `press` or `press-prefix` against labels from every shipped localization. The fixture routes use the same localization to check the exact fixture scope, fixture row, and full selection count in AX. The files must still match their identities. The guard also checks Duplicate confirmation controls and refuses them when the selected group is unavailable in AX. Cancel and unmodified Escape remain available. The project wrapper limits other keys to the focused native Open panel because Return or Space could activate an unnamed default action. Use the staged or updated generic driver, which supports this check.

## Evidence

`"$cac" shot NAME [WINDOW_ID]` writes the screenshot and AX tree to the directory recorded at build. The default is `${BB_THREAD_STORAGE:-$HOME/Library/Caches}/verify-cleanappcache/<run-id>/evidence/`. The exact fallback is `$HOME/Library/Caches/verify-cleanappcache/<run-id>/evidence/`. Keep evidence outside scratch and use `paths` for its recorded location. Capture the state before and after each action. For Trash and Undo, record the file's identity and contents before the move, observe the missing file, then verify the restored identity and contents.

## Cleanup

```bash
"$cac" cleanup
```

Cleanup requires the build ownership marker and refuses to delete scratch if the recorded evidence lies inside it. It verifies the recorded executable is inside the run and asks the matching LaunchServices instance to quit. If the driver cannot verify exit, it reports the PID for the operator to inspect and retains scratch. Cleanup moves the recorded home fixture link into a private quarantine folder inside scratch with one atomic rename, then checks its device, inode and target there, so nothing in the home folder is unlinked by name. A matching link goes away with scratch. A changed entry is put back at its path (or kept in the retained scratch if the path was taken again), cleanup fails, and nothing is deleted. Trash inspection is read-only. An unverified Trash listing is informational, including when the host lacks Full Disk Access. Check that evidence survives, the Audit PID, scratch and owned links are gone, and the operator's own instance still has its original PID.

## Helpers

```bash
"$cac" help
"$cac" paths
"$cac" activate
"$cac" tree
"$cac" windows
"$cac" wait-for AXStaticText 'System Monitor'
"$cac" shot monitor
"$cac" fixtures large-files
"$cac" fixture-link large-files
"$cac" fixtures duplicates
"$cac" fixture-link duplicates
"${cac%/*}/check-action" --self-test
```

`fixtures` creates the files under `${TMPDIR:-/tmp}/verify-cleanappcache/<run-id>/fixtures/`. The scanner and Trash operation accept fixture files in this descendant of the macOS temp directory. Large Files uses 101 MiB of allocated data to exceed the 100 MB minimum. The optional `fixture-link` creates a unique link directly in the home folder, so the native picker can reach the fixture directory by its visible name. It refuses any existing entry at the link path. See the [picker recipe](features/README.md#choose-the-fixture-folder).

`check-action --self-test` runs without the app. It feeds the validator synthetic Home and fixture-scoped AX trees, checks refusal for every protected key in each shipped localization, and checks that the exact fixture scope permits **Move to Trash**.

## Permissions

Commands that launch the app, drive it or capture the screen must run outside the agent's command sandbox (macOS seatbelt blocks LaunchServices, Apple Events and window-server access). On the verification Mac, SwiftPM's manifest sandbox also requires an outside-sandbox build.

The host `/Applications/bb.app` needs **Accessibility** for AX and **Screen Recording** for screenshots. The generic skill documents the canonical Accessibility deep link on macOS 27, the macOS 13–15 path, and **Quit & Reopen** after enabling Screen Recording. The driver needs no Automation or Full Disk Access grant. Optional Trash inspection can require Full Disk Access and is reported separately.

LaunchServices attributes protected-folder access to the Audit app. Monitor and the scratch-scoped Large Files route produced no folder prompt in the proof. Duplicates probes Downloads and can prompt on a fresh grant state. Broad Home or Storage scans and Documents, Desktop or Downloads scopes can also prompt. The keyboard and panel routes stay within the recorded app. Never grant additional permissions to get a journey to pass.
