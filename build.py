#!/usr/bin/env python3
"""Builds CleanAppCache in release mode, assembles a .app bundle and packages
it into a drag-and-drop DMG installer. No third-party dependencies — the
VS Code Run button (or a bare `python3 build.py`) does the whole job.

Usage:
    python3 build.py                    # CleanAppCache.dmg; signs with the
                                        # "CleanAppCache Local" identity when
                                        # make_signing_identity.sh has created
                                        # it, else ad-hoc
    SIGN_IDENTITY="..." python3 build.py            # a specific local identity
    DEVELOPER_ID="..."  python3 build.py            # Developer ID sign
    DEVELOPER_ID="..." NOTARY_PROFILE="..." python3 build.py  # + notarize + staple
    VERSION=1.0 BUILD_NUMBER=... python3 build.py   # override the stamps

The same knobs exist as flags (they win over the environment):
    python3 build.py --developer-id "..." --notary-profile "..." --version 1.0
"""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

APP_NAME = "CleanAppCache"
BUNDLE_ID = "com.cleanappcache.CleanAppCache"
MIN_OS = "13.0"

ROOT = Path(__file__).resolve().parent
APP = ROOT / f"{APP_NAME}.app"
DMG = ROOT / f"{APP_NAME}.dmg"
DMG_TMP = ROOT / "_dmg_staging"
# Where the build puts its products depends on the toolchain: SwiftPM's
# native build system used .build/apple/Products/Release for multi-arch
# builds, the Swift Build system (Xcode 27) uses .build/out/Products/Release.
# The path is asked of SwiftPM after building (see `products_dir`); a fixed
# path silently packaged a stale binary from whichever layout came before.
BUILD_ARGS = ("-j", "2", "-c", "release", "--product", APP_NAME, "--arch", "arm64", "--arch", "x86_64")


def run(*argv: str, capture: bool = False) -> str:
    """Runs a command from the repo root, failing the build on any error."""
    result = subprocess.run(argv, cwd=ROOT, check=True, text=True,
                            capture_output=capture)
    return result.stdout if capture else ""


def step(title: str) -> None:
    print(f"▶︎ {title}", flush=True)


def fail(message: str) -> "sys.NoReturn":
    print(f"✗ {message}", file=sys.stderr)
    sys.exit(1)


def build_number() -> str:
    # Monotonic build number. Notarization, crash reports and update checks all
    # key off CFBundleVersion; hardcoding "1" made every build
    # indistinguishable. The commit timestamp is stable across rebuilds of the
    # same commit AND ordered across branches — `rev-list --count` collided at
    # equal counts on two branches and went DOWN after a rebase/squash. There
    # is deliberately no `date` fallback: its ~2×10^11 value permanently
    # dwarfed every later real build number, so LaunchServices treated
    # genuinely newer builds as older.
    try:
        return run("git", "show", "-s", "--format=%ct", "HEAD",
                   capture=True).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def make_info_plist(version: str, build: str) -> None:
    info: dict = {
        "CFBundleExecutable": APP_NAME,
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        "LSApplicationCategoryType": "public.app-category.utilities",
        "LSMinimumSystemVersion": MIN_OS,
        "LSUIElement": False,
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": APP_NAME,
        "NSAppleEventsUsageDescription":
            "CleanAppCache uses System Events to list the apps that open at "
            "login, and Finder to move files your account cannot change to the "
            "Trash — Finder asks for your password first.",
        # TCC prompts the user the first time the app reaches into these
        # folders. Without a usage description the prompt has no explanation,
        # and on some configurations the access is refused outright and scans
        # come back empty. The app reaches all four: Duplicates scans
        # Documents/Desktop/Downloads, Large Files scans the whole volume.
        "NSDesktopFolderUsageDescription":
            "CleanAppCache scans your Desktop to find duplicate and unusually "
            "large files. Nothing is deleted without your confirmation.",
        "NSDocumentsFolderUsageDescription":
            "CleanAppCache scans your Documents to find duplicate and "
            "unusually large files. Nothing is deleted without your "
            "confirmation.",
        "NSDownloadsFolderUsageDescription":
            "CleanAppCache scans your Downloads to find old installers, "
            "duplicates and large files. Nothing is deleted without your "
            "confirmation.",
        "NSRemovableVolumesUsageDescription":
            "CleanAppCache reports how much space is used on connected "
            "volumes.",
    }
    if (ROOT / "Resources/AppIcon.icns").exists():
        shutil.copy2(ROOT / "Resources/AppIcon.icns",
                     APP / "Contents/Resources/AppIcon.icns")
        info["CFBundleIconFile"] = "AppIcon"
        info["CFBundleIconName"] = "AppIcon"
    else:
        print("  (no Resources/AppIcon.icns — run ./Scripts/make_icon.sh "
              "to generate one)")
    with open(APP / "Contents/Info.plist", "wb") as f:
        plistlib.dump(info, f)


def sign_bundle(identity: str, *extra: str) -> None:
    # `--deep` is deprecated for signing (Apple: verification only) and signs
    # nested code with the wrong flags. Sign inner bundles first, then the
    # app. The hardened runtime and entitlements are applied in EVERY branch:
    # a local build that behaves differently from the shipped one hides
    # exactly the class of bug that matters here (Apple events silently
    # blocked in release only).
    for inner in sorted((APP / "Contents/Resources").glob("*.bundle")):
        run("codesign", "--force", "--options", "runtime",
            "--sign", identity, *extra, str(inner))
    run("codesign", "--force", "--options", "runtime",
        "--entitlements", str(ROOT / "entitlements.plist"),
        "--sign", identity, *extra, str(APP))


def local_identity_exists() -> bool:
    try:
        out = run("security", "find-identity", "-v", "-p", "codesigning",
                  capture=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False
    return "CleanAppCache Local" in out


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build CleanAppCache.app and CleanAppCache.dmg")
    parser.add_argument("--version", default=os.environ.get("VERSION", "0.9.1"))
    parser.add_argument("--build-number",
                        default=os.environ.get("BUILD_NUMBER", ""))
    parser.add_argument("--developer-id",
                        default=os.environ.get("DEVELOPER_ID", ""))
    parser.add_argument("--sign-identity",
                        default=os.environ.get("SIGN_IDENTITY", ""))
    parser.add_argument("--notary-profile",
                        default=os.environ.get("NOTARY_PROFILE", ""))
    args = parser.parse_args()

    os.chdir(ROOT)

    build = args.build_number or build_number()
    if not build:
        fail("BUILD_NUMBER is unset and git is unavailable — "
             "pass --build-number (or export BUILD_NUMBER) explicitly.")

    # 1. Build ────────────────────────────────────────────────────────────────
    step("Building release binary (universal)…")
    # Both architectures, always: Intel Macs still ship macOS 13–15, and
    # LSMinimumSystemVersion 13.0 advertises support for them. A
    # host-arch-only binary made Finder refuse launch on Intel with "not
    # supported on this type of Mac" while the DMG claimed otherwise.
    run("swift", "build", *BUILD_ARGS)
    PRODUCTS = Path(run("swift", "build", *BUILD_ARGS, "--show-bin-path", capture=True).strip())
    binary = PRODUCTS / APP_NAME
    # A binary older than the sources is left over from another layout or
    # toolchain; shipping it would ship old code under a new version. (An
    # up-to-date incremental build leaves the binary as it was, so the
    # comparison is with the sources, not with the time the build started.)
    newest_source = max(f.stat().st_mtime for f in
                        [ROOT / "Package.swift", *(ROOT / "Sources").rglob("*") ] if f.is_file())
    if not binary.exists() or binary.stat().st_mtime < newest_source:
        fail(f"{binary} is older than the sources — refusing to package a stale binary.")

    # 2. Assemble .app bundle ─────────────────────────────────────────────────
    step(f"Assembling {APP.name}…")
    shutil.rmtree(APP, ignore_errors=True)
    (APP / "Contents/MacOS").mkdir(parents=True)
    (APP / "Contents/Resources").mkdir(parents=True)
    shutil.copy2(PRODUCTS / APP_NAME, APP / "Contents/MacOS" / APP_NAME)

    # SwiftPM resource bundles (localizations, assets). Without them
    # `Bundle.module` finds no strings and the UI shows raw keys.
    for bundle in sorted(PRODUCTS.glob("*.bundle")):
        shutil.copytree(bundle, APP / "Contents/Resources" / bundle.name)

    make_info_plist(args.version, build)

    # 3. Code signing ─────────────────────────────────────────────────────────
    # Default to the stable local identity whenever it exists and nothing was
    # chosen explicitly. Ad-hoc signing changes the app's identity on every
    # rebuild, so macOS revoked Full Disk Access and folder grants each time
    # and the app re-prompted for the same permissions on every launch of a
    # new build. Scripts/make_signing_identity.sh creates the identity once.
    sign_identity = args.sign_identity
    if not args.developer_id and not sign_identity and local_identity_exists():
        sign_identity = "CleanAppCache Local"

    if args.developer_id:
        step("Code signing with Developer ID (hardened runtime)…")
        sign_bundle(args.developer_id, "--timestamp")
    elif sign_identity:
        step(f"Code signing with stable local identity '{sign_identity}'…")
        # A stable identity keeps the same designated requirement across
        # rebuilds, so macOS remembers granted permissions (Full Disk Access,
        # etc.) instead of resetting them on every reinstall.
        sign_bundle(sign_identity)
    else:
        step("Code signing (ad-hoc)…")
        # No fallback that re-signs without entitlements: that produced a
        # bundle that could not send Apple events, and swallowed the reason.
        sign_bundle("-")
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(APP))
    if not args.developer_id:
        print("   (stable local signature — permissions persist across "
              "rebuilds on this Mac)" if sign_identity else
              "   (ad-hoc signed — permissions reset on each rebuild; "
              "set SIGN_IDENTITY to keep them)")

    # 4. Package into DMG (drag-and-drop installer) ───────────────────────────
    step("Creating DMG installer…")
    shutil.rmtree(DMG_TMP, ignore_errors=True)
    DMG.unlink(missing_ok=True)
    DMG_TMP.mkdir()
    shutil.copytree(APP, DMG_TMP / APP.name, symlinks=True)
    (DMG_TMP / "Applications").symlink_to("/Applications")
    run("hdiutil", "create", "-volname", APP_NAME,
        "-srcfolder", str(DMG_TMP), "-ov", "-format", "UDZO",
        str(DMG), capture=True)
    shutil.rmtree(DMG_TMP)

    # 5. Notarize DMG (optional — requires DEVELOPER_ID + NOTARY_PROFILE) ─────
    if args.developer_id and args.notary_profile:
        step("Signing DMG…")
        # --timestamp is required: notarization rejects a signature without a
        # secure timestamp, and the app bundle already gets one above.
        run("codesign", "--timestamp", "--sign", args.developer_id, str(DMG))
        step("Submitting DMG to Apple notary service…")
        # Check the verdict explicitly: some notarytool releases exit 0 even
        # when `--wait` ends on "status: Invalid", and the rejection would
        # then surface only as a cryptic stapler error. Fail loudly here.
        submit_out = run("xcrun", "notarytool", "submit", str(DMG),
                         "--keychain-profile", args.notary_profile, "--wait",
                         capture=True)
        print(submit_out, file=sys.stderr)
        if "status: Accepted" not in submit_out:
            fail("Notarization not accepted — inspect it with:\n"
                 f"  xcrun notarytool log <submission-id> "
                 f"--keychain-profile {args.notary_profile}")
        step("Stapling notarization ticket…")
        run("xcrun", "stapler", "staple", str(DMG))
        print("   ✓ Notarized & stapled.")
    elif args.developer_id:
        print("   (export NOTARY_PROFILE to also notarize)")

    # 6. Done ─────────────────────────────────────────────────────────────────
    size_mb = DMG.stat().st_size / 1_000_000
    print(f"✅ Done: {DMG}  ({size_mb:.1f}M)")
    print(f'\n   Open "{DMG.name}" — drag {APP_NAME} to Applications')


if __name__ == "__main__":
    main()
