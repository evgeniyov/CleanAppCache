#!/usr/bin/env bash
#
# Checks an assembled CleanAppCache.app the way a user's Mac will. Shared by CI
# and Scripts/verify.sh, so the two cannot drift apart: a hand-copied subset in
# CI silently loses checks such as the entitlement one.
#
#   • signature verifies (--deep --strict)
#   • hardened runtime is on — notarization refuses a bundle without it
#   • the apple-events entitlement survived signing: without it Startup and
#     the admin uninstall break only in the signed build, never in a debug run
#   • the binary is universal — LSMinimumSystemVersion 13.0 advertises Intel
#   • Info.plist carries the TCC usage descriptions, or the folder prompts come
#     up blank and some configurations refuse access outright
#   • the SwiftPM resource bundle contains the English and Russian catalogs
#
# Usage:  ./Scripts/check_bundle.sh [path/to/CleanAppCache.app]
#
set -uo pipefail

APP="${1:-CleanAppCache.app}"
[ -d "$APP" ] || { echo "::error::$APP not found — run python3 build.py first"; exit 1; }
fail=0

if codesign --verify --deep --strict --verbose=2 "$APP"; then
    echo "   ✓ signature verifies"
else
    echo "::error::codesign --verify failed for $APP"; fail=1
fi

# Captured, not piped into `grep -q`: under pipefail an early grep exit sends
# codesign SIGPIPE and the "check" fails on a perfectly good signature.
display=$(codesign --display --verbose=4 "$APP" 2>&1)
if grep -q 'flags=.*runtime' <<< "$display"; then
    echo "   ✓ hardened runtime"
else
    echo "::error::hardened runtime missing from the signature"; fail=1
fi

entitlements=$(codesign --display --entitlements - "$APP" 2>&1)
if grep -q 'com.apple.security.automation.apple-events' <<< "$entitlements"; then
    echo "   ✓ apple-events entitlement"
else
    echo "::error::apple-events entitlement missing — Startup and admin uninstall break in release"; fail=1
fi

archs=$(lipo -archs "$APP/Contents/MacOS/CleanAppCache" 2>/dev/null || true)
if [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]]; then
    echo "   ✓ universal ($archs)"
else
    echo "::error::binary is not universal (got: '$archs') but LSMinimumSystemVersion 13.0 advertises Intel"; fail=1
fi

missing=0
for key in NSAppleEventsUsageDescription NSDesktopFolderUsageDescription \
           NSDocumentsFolderUsageDescription NSDownloadsFolderUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
        || { echo "::error::Info.plist missing $key"; missing=1; fail=1; }
done
[ "$missing" -eq 0 ] && echo "   ✓ usage descriptions"

resources="$APP/Contents/Resources/CleanAppCache_CleanAppCacheLib.bundle"
if [ -d "$resources/Contents/Resources" ]; then
    resources="$resources/Contents/Resources"
fi
invalid=0
for lang in en ru; do
    for catalog in Localizable.strings Localizable.stringsdict; do
        path="$resources/$lang.lproj/$catalog"
        if ! plutil -lint -- "$path" >/dev/null; then
            echo "::error::missing or invalid localization catalog: $path"
            invalid=1; fail=1
        fi
    done
done
[ "$invalid" -eq 0 ] && echo "   ✓ English and Russian localization catalogs"

exit "$fail"
