# Large Files

Find a large file in one folder, move it to Trash, and undo the move from the toast.

## Sub-features

- `large-files-scope` scans the folder chosen through Profiles.
- `large-files-trash` moves the selected file into Trash.
- `large-files-undo` restores the file to its original path.

## How to get to it (user POV)

Choose **Large Files** in the Cleanup sidebar. Open **Profiles**, choose a search folder, then press **Scan**.

## Driving it with cac-verify

Start from the Audit Monitor window with a passing Doctor. Run `"$cac" press AXButton 'Large Files'`. Follow [Choose the fixture folder](README.md#choose-the-fixture-folder) with `kind=large-files`. Start the next step only once the scope button reads `large-files`.

- **Baseline.** Set `file="$fixture/cac-verify-$CAC_VERIFY_RUN-large.bin"` and `file_name="${file##*/}"`. Save `stat -f '%N inode=%i size=%z blocks=%b' "$file"` and `shasum -a 256 "$file"` in the evidence directory.
- **Scan and select.** Capture the scoped start, run `"$cac" press AXButton Scan`, and wait with `"$cac" wait-for AXButton "Select “${file_name}” for the Trash"`. Capture the results and require **Found 1 file**, the fixture folder path and the one fixture. The nested button begins with the file name and path. Run `"$cac" press-prefix AXButton "$file_name, "`, wait for `"$cac" wait-for AXButton 'Move to Trash'`, and capture the selection. Require **Selected** **1 file** and the one fixture row.
- **Move to Trash and Undo.** Prepare these commands together so the toast is still present. Run `"$cac" press AXButton 'Move to Trash'`, `"$cac" wait-for AXButton Undo 5`, then `"$cac" shot large-files-trashed`. Save the fact that `test ! -e "$file"` passes. Run `"$cac" press AXButton Undo`, wait for the file row again, and run `"$cac" shot large-files-restored`. Save the same `stat` and SHA-256 commands and compare against the baseline.

## Gotchas

- The default Home scope waits for **Scan** and can touch protected folders once scanning. The wrapper refuses **Move to Trash** there. It requires one visible result in the exact fixture folder, the matching row and file identity, and exactly one selected file. Normalize the displayed `/var` or `/private/var` spelling when comparing paths.
- The row with description `Select “…” for the Trash` encloses a nested actionable button. On the observed SwiftUI build, pressing the outer AX node left selection unchanged. Use the nested button, then verify the count.
- The fixture needs allocated blocks. A sparse file can be filtered out even with a large logical size.
- The Undo toast lasts seven seconds. If it expires or a password or Finder prompt appears, stop the journey and run cleanup. The real Trash requires separate permission to inspect, so record a denied check even after successful Undo.
- The fixture journey wrote `~/Library/Application Support/CleanAppCache-Audit/cleanup-history.json` and left the operator's history and preferences unchanged in the observed run. The Logs path comes from `AppPaths.logs` and resolves to `~/Library/Logs/CleanAppCache-Audit`. A successful fixture run didn't create a log file. The Trash, real disk, OS privacy settings and Finder remain shared.
