import json
import os
from pathlib import Path
import stat
import sys


def link_identity(path, directory):
    info = os.lstat(path.name, dir_fd=directory)
    if not stat.S_ISLNK(info.st_mode):
        raise ValueError(f"Fixture link is no longer a symlink: {path}")
    return f"{info.st_dev}:{info.st_ino}"


def open_parent(path):
    return os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def create(record, target, path):
    if os.path.lexists(record):
        raise ValueError(f"A fixture link is already recorded at {record}")
    directory = open_parent(path)
    try:
        # symlink(2) refuses an existing entry, including a directory or dangling link.
        try:
            os.symlink(target, path.name, dir_fd=directory)
        except FileExistsError:
            raise ValueError(f"Refusing an existing fixture link path: {path}") from None
        identity = link_identity(path, directory)
        if os.readlink(path.name, dir_fd=directory) != str(target):
            raise ValueError(f"Fixture link target changed: {path}")
        with record.open("x") as file:
            json.dump({"path": str(path), "identity": identity}, file)
    finally:
        os.close(directory)
    print(path)


def remove(record, target, expected_name):
    if not os.path.lexists(record):
        return
    if record.is_symlink() or not record.is_file():
        raise ValueError(f"Invalid fixture link record: {record}")
    data = json.loads(record.read_text())
    path = Path(data["path"])
    if not path.is_absolute() or path.name != expected_name:
        raise ValueError(f"Invalid recorded fixture link path: {path}")
    # Checking the entry in the home folder and then unlinking it by name races
    # with anything that replaces the entry in between. rename(2) moves exactly
    # one directory entry atomically, so the entry is first moved into a private
    # folder inside this run's scratch and checked there. Whatever was moved is
    # either this run's link, removed with scratch, or a foreign entry, which is
    # put back or kept in the retained scratch, never deleted.
    quarantine = record.parent / f"{record.stem}.quarantine"
    try:
        os.mkdir(quarantine, 0o700)
    except FileExistsError:
        raise ValueError(f"An earlier cleanup left {quarantine}; inspect it before retrying") from None
    directory = open_parent(path)
    held = os.open(quarantine, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            os.rename(path.name, path.name, src_dir_fd=directory, dst_dir_fd=held)
        except FileNotFoundError:
            return
        info = os.lstat(path.name, dir_fd=held)
        ours = (stat.S_ISLNK(info.st_mode) and f"{info.st_dev}:{info.st_ino}" == data["identity"]
                and os.readlink(path.name, dir_fd=held) == str(target))
        if ours:
            print(f"Removed recorded fixture link: {path}")
            return
        if not os.path.lexists(path):
            os.rename(path.name, path.name, src_dir_fd=held, dst_dir_fd=directory)
            raise ValueError(f"Fixture link identity or target changed; left in place: {path}")
        raise ValueError(f"Fixture link identity or target changed and {path} is taken again; "
                         f"the moved entry is kept at {quarantine / path.name}")
    finally:
        os.close(held)
        os.close(directory)


if __name__ == "__main__":
    action, scratch, kind = sys.argv[1:]
    run = Path(scratch)
    record = run / f"{kind}.link"
    target = run / "fixtures" / kind
    name = f"cac-verify-{run.name}-{kind}"
    try:
        if action == "create":
            create(record, target, Path.home().resolve() / name)
        elif action == "remove":
            remove(record, target, name)
        else:
            raise ValueError("Use create or remove.")
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f"cac-verify: {error}")
