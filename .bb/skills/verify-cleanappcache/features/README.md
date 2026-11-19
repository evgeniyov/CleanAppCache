# CleanAppCache verification map

## Safety rules

- Never press a clean, delete, move-to-Trash, uninstall, empty-Trash, or Startup “turn off” or disable control against real user data.
- Run destructive journeys only in Large Files or Duplicates using fixtures the skill creates in its scratch folder. Choose that exact folder through the search profiles menu → “Choose search folder…”. Never use “Save search profile…”. Confirm every selected item belongs to the run.
- Trashed fixtures enter the user's real Trash. Use Undo and verify the restored files. Cleanup reports any visible run-ID entry or an unverified listing. If Undo fails, use the expected fixture names from cleanup to check and remove any leftovers yourself in Finder.
- Keep Smart Cleanup, uninstaller, Startup, Privacy, System Junk, Developer, Leftovers, and Orphans journeys read-only. If a confirmation is already visible, capture its wording and dismiss it with Cancel or Escape.
- Check on-appear access before opening a screen. Monitor avoids protected-folder scans. Large Files defaults to Home and waits for a scan. Duplicates probes Downloads on appear and can trigger a privacy prompt.

## Baseline preconditions

- From the repository root, set `cac="$PWD/.bb/skills/verify-cleanappcache/scripts/cac-verify"` and `export CAC_VERIFY_RUN="$("$cac" new)"`. Use one Audit run at a time.
- Build and launch the Audit copy using [the skill](../SKILL.md). Run `"$cac" doctor` and require both permissions, an unlocked console and awake display, the expected build and PID, an AX window, and a successful window capture.
- On a fresh Audit domain, capture the onboarding, press **Get Started**, and capture the resulting screen. The Audit domain can retain onboarding across runs.
- Start with the English UI on Monitor unless the feature calls for a different initial screen. Keep screen access and window state stable during a journey.

## Driving conventions

- Use the exact selector from the current `"$cac" tree`. AX button labels can be in the title, description, or identifier. Wait for rendered results through `wait-for`, then check the current screenshot and tree.
- Before pressing any destructive button in a fixture journey, inspect the fixture folder, displayed scope, file rows, and selected count. The wrapper checks these in the live AX tree and refuses when the selection cannot be proved. Keep Escape available for dismissal and use named AX controls to perform applicable actions.
- Run each feature from its documented preconditions. A missing precondition is a failed or blocked journey.
- Clean up the Audit PID and scratch and keep the evidence. The operator's PID and the Audit domain directories outlive individual runs.

## Proof rules

- Capture the action and resulting observable state. Use paired `shot` calls for each action. For a separate window, use the PID-owned window ID shown by `windows`.
- Verify filesystem effects from a second view such as `stat` and `ls`. For Undo, check the returned fixture's inode and content against the original.
- Record the feature ID, entry point, command, and evidence filenames. Record a blocked entry point with its error and precondition. A different entry point needs its own proof.

## Feature entry contract

Start with the feature name and its user-visible purpose. Make exactly four H2s in this order.

1. `Sub-features` lists the behaviors covered.
2. `How to get to it (user POV)` identifies the user entry points.
3. `Driving it with cac-verify` states the preconditions, exact user actions, and required evidence.
4. `Gotchas` records privacy prompts, side effects, selector quirks, and blocked paths.

## Features

- [Large Files](large-files.md) covers a scoped search, selecting a fixture, moving it to Trash, and Undo.
- [Duplicates](duplicates.md) covers a scoped search, the copy-retention confirmation, and cancellation.
- [Storage](storage.md) covers the normal landing screen and read-only overview.
- [System Monitor](monitor.md) covers live CPU, memory, and sensor readings.

### Choose the fixture folder

Use this recipe from Large Files or Duplicates before pressing Scan. Set `kind` to `large-files` or `duplicates`. Each command opening or changing a view should have an adjacent `shot` before and after. Use a fresh evidence name each time.

```bash
fixture="$("$cac" fixtures "$kind")"
"$cac" press AXMenuButton Profiles
"$cac" wait-for AXMenuItem 'Choose search folder…'
"$cac" windows
"$cac" shot profiles "$profiles_window_id" &&
    "$cac" press AXMenuItem 'Choose search folder…'
"$cac" wait-for AXWindow open-panel
"$cac" windows
```

Set `profiles_window_id` to the Profiles window's ID from `windows`. If the menu closes and the shot fails with **Window ID must belong to the recorded PID**, reopen **Profiles**, run `windows` again, then capture with the fresh ID and press **Choose search folder…** in the same shell sequence. Use a fresh evidence name for the retry. If Profiles is the only nonzero-layer window, the sequence can select it directly.

```bash
"$cac" press AXMenuButton Profiles &&
    "$cac" wait-for AXMenuItem 'Choose search folder…' &&
    profiles_window_id=$("$cac" windows | awk '$2 != 0 { id = $1; count++ } END { if (count == 1) print id; else exit 1 }') &&
    "$cac" shot profiles-reopened "$profiles_window_id" &&
    "$cac" press AXMenuItem 'Choose search folder…'
```

Capture the Open panel using its own ID from `windows`. The Open panel is the native window titled **Open** on the verified machine. The generic skill describes Cmd-Shift-G. On macOS 27.2.1, the Audit window's PID did not deliver that shortcut to the native picker, so choose the folder through its AX selection controls:

```bash
link="$("$cac" fixture-link "$kind")"
"$cac" select-folder AXStaticText "${HOME##*/}"
"$cac" wait-for AXTextField "${link##*/}"
"$cac" select-folder AXTextField "${link##*/}"
"$cac" tree
"$cac" press AXButton OKButton
"$cac" wait-for AXButton "$kind"
```

The tested picker uses column view. Check `AXBrowser identifier="ColumnView"` and the sidebar's exact home-entry label in the live tree. The **View Options** menu exposes the picker display mode. Before pressing **Open**, check that the picker shows the exact fixture names and `readlink "$link"` equals `"$fixture"`. If the sidebar or folder is unavailable, record the error and stop without starting a broad scan.
