import os
from pathlib import Path
import sys


def report(run, trash):
    expected = set()
    missing = set()
    for kind, suffixes in (("large-files", ("large",)), ("duplicates", ("a", "b"))):
        for suffix in suffixes:
            name = f"cac-verify-{run.name}-{suffix}.bin"
            if (run / (name + ".identity")).is_file():
                expected.add(name)
                if not (run / "fixtures" / kind / name).exists():
                    missing.add(name)

    visible = []
    try:
        fd = os.open(trash, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            visible = sorted(name for name in os.listdir(fd) if run.name in name)
        finally:
            os.close(fd)
    except FileNotFoundError:
        print(f"Trash: no directory at {trash}")
    except OSError as error:
        print(f"Trash: unverified; cannot list {trash}: {error.strerror}")
    else:
        if visible:
            print("Trash: entries with this run ID: " + ", ".join(visible))
        else:
            print(f"Trash: no entries with run ID {run.name}")

    if missing or visible:
        if missing or expected:
            print("Expected fixture names: " + ", ".join(sorted(missing or expected)))
        print("Check the Trash in Finder and remove any leftover run fixtures yourself.")


if __name__ == "__main__":
    report(*map(Path, sys.argv[1:]))
