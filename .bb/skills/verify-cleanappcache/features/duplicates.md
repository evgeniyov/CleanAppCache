# Duplicates

Show two independently written files with identical contents as one duplicate group and inspect the choice of which copy to retain.

## Sub-features

- `duplicates-scope` scans only the selected fixture directory.
- `duplicates-confirm-cancel` shows the Trash and retention options, then returns to the results with both files present.

## How to get to it (user POV)

Choose **Duplicates** in the Cleanup sidebar. Pick a search folder through **Profiles**. Scan, select one group and choose **Delete the extra copies** to see the retention options.

## Driving it with cac-verify

Start from Monitor with a passing Doctor. Run `"$cac" press AXButton Duplicates`. Follow [Choose the fixture folder](README.md#choose-the-fixture-folder) with `kind=duplicates`.

- **Baseline.** Record `stat -f '%N inode=%i size=%z mtime=%m' "$fixture"/*.bin` and `shasum -a 256 "$fixture"/*.bin`. Require two different inodes and the same digest. The helper makes `-a.bin` older than `-b.bin`.
- **Scope and scan.** Wait for `"$cac" wait-for AXButton duplicates`. Press the observed minimum `"$cac" press AXButton '1 MB'`, capture the scope, then run `"$cac" press AXButton Scan`. Wait for the result with the run's `-a.bin`, capture it, and require **2 copies at 2.10 MB each** and **Newest copy stays** pointing at `-b.bin`.
- **Select one group.** Use the nested button from the tree. Define `a="cac-verify-$CAC_VERIFY_RUN-a.bin"` and `b="cac-verify-$CAC_VERIFY_RUN-b.bin"`. With the scope and row verified, run `"$cac" press-prefix AXButton "$a, Newest copy stays: $fixture/$b, $fixture,"`. Use the exact path spelling from the current tree. Wait for **Delete the extra copies** and capture the selection.
- **Open and cancel.** Run `"$cac" press AXButton 'Delete the extra copies'` and `"$cac" wait-for AXButton 'Keep the newest copy'`. Capture the dialog, including **Move 1 file to the Trash?**, both retention options and **Cancel**. Run `"$cac" key escape` to activate Cancel. Capture the return to results and verify both original files and their digests again.

## Gotchas

- The screen probes Downloads on appear, before a scan. macOS may show a Files and Folders prompt. A blocked Downloads scope can still expose the Profiles menu. Keep the proof scoped to fixtures.
- The default scan minimum is 5 MB. The fixture files need **1 MB** selected. Independent writes avoid APFS clones or hardlinks that the finder skips.
- The guard requires the scope button's full folder path in AX, the one group and both fixture identities. If the dialog hides the source selection from AX, the guard refuses its retention buttons.
- On the verified SwiftUI sheet, `press AXButton Cancel` returned AXError `-25205`. PID-targeted Escape dismissed it.
