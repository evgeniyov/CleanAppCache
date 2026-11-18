#!/usr/bin/env bash
#
# Local mirror of .github/workflows/ci.yml. Run before pushing.
#
#   1. Source invariants (Scripts/check_invariants.sh): localization parity,
#      closed palette, one size formatter.
#   2. Debug build of lib + app + tests with warnings as errors — zero warnings
#      is a stated invariant, and a clean build is the only one that shows
#      every warning.
#   3. swift test. PathGuardTests and DeletionRoutingTests are the safety net:
#      a failure means a path that must never be deleted can be, or that new
#      code deletes files without going through the guard.
#   4. Universal release .app + DMG (build.py) and the bundle
#      checks a user's Mac will apply (Scripts/check_bundle.sh).
#
# Usage:  ./Scripts/verify.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILURES=()
step() { printf '\n\033[1m▶︎ %s\033[0m\n' "$1"; }
record() { # record <name> <exit-code>
    if [ "$2" -ne 0 ]; then
        FAILURES+=("$1")
        printf '\033[31m   ✗ %s\033[0m\n' "$1"
    else
        printf '\033[32m   ✓ %s\033[0m\n' "$1"
    fi
}

step "Source invariants"
./Scripts/check_invariants.sh
record "check_invariants.sh" $?

step "Toolchain"
swift --version || { echo "Swift not found — run this on macOS."; exit 1; }
# Says which mode the sensor tests will run in: a guest skips the hardware claims.
sysctl kern.hv_vmm_present hw.perflevel0.logicalcpu 2>/dev/null || true

step "Build (debug, lib + app + tests, warnings are errors)"
swift build --build-tests -Xswiftc -warnings-as-errors
record "debug build" $?

step "Tests"
swift test --skip-build
record "swift test" $?

step "Integration smoke checks"
swift Scripts/integration_test.swift
record "integration smoke" $?

step "Assemble universal .app + DMG"
python3 build.py
record "build.py" $?

if [ -d "CleanAppCache.app" ]; then
    step "Bundle"
    ./Scripts/check_bundle.sh CleanAppCache.app
    record "check_bundle.sh" $?
fi

printf '\n'
if [ ${#FAILURES[@]} -eq 0 ]; then
    printf '\033[32m✅ Everything passed.\033[0m\n'
    exit 0
fi
printf '\033[31m❌ Failed: %s\033[0m\n' "${FAILURES[*]}"
exit 1
