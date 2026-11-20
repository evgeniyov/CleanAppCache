#!/usr/bin/env bash
#
# Source-level invariants the Swift compiler cannot see. Shared by CI (the
# toolchain-free job) and Scripts/verify.sh so the two cannot drift.
#
#   1. Localization parity: en and ru carry the same key set, no key is
#      duplicated, every literal key passed to loc.s / loc.f / loc.opt exists,
#      and the %-specifier sequence of each key is identical in both languages.
#      `Localizer.s()` returns the raw key on a miss, so a missing key never
#      errors — it renders as "nav.storage" in the interface, and nothing
#      else catches it before a release.
#      The plural catalogs must parse and cover every literal Fmt.plural key.
#   2. The palette is closed: `Color(hex:)` is spelled only in Design/Theme.swift.
#   3. `Fmt` is the only size formatter: `ByteCountFormatter` follows the
#      system locale, not the in-app language switch.
#
# Usage:  ./Scripts/check_invariants.sh        (exit 1 on any violation)
#
# Runs on macOS (BSD grep/awk) and Linux (GNU) alike; `::error::` lines are
# GitHub Actions annotations and harmless in a terminal.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

R=Sources/CleanAppCacheLib/Resources
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0

# ── 1. Localization parity ──────────────────────────────────────────────────

keys() { grep -oE '^"[^"]+"' "$1" | tr -d '"' | sort; }

for lang in en ru; do
    d=$(keys "$R/$lang.lproj/Localizable.strings" | uniq -d)
    [ -n "$d" ] && { echo "::error::duplicate keys in $lang:"; echo "$d"; fail=1; }
done
keys "$R/en.lproj/Localizable.strings" | uniq > "$T/en.keys"
keys "$R/ru.lproj/Localizable.strings" | uniq > "$T/ru.keys"
d=$(comm -3 "$T/en.keys" "$T/ru.keys")
[ -n "$d" ] && { echo "::error::en/ru key sets differ (col1 en-only, col2 ru-only):"; echo "$d"; fail=1; }

# Every literal key passed to loc.s / loc.f / loc.opt must exist. Interpolated
# keys ("sec.\(id).risk") are prefix families and are skipped. The leading
# character class keeps `bloc.s("…")`-style identifiers out without `\b`,
# which BSD grep does not promise.
grep -rhoE '(^|[^A-Za-z0-9_.])(loc|Localizer\.shared)\.(s|f|opt)\("[^"]+"' Sources --include='*.swift' \
    | sed -E 's/.*\("//; s/"$//' | grep -v '\\(' | sort -u > "$T/used.keys"
m=$(comm -23 "$T/used.keys" "$T/en.keys")
[ -n "$m" ] && { echo "::error::keys used in code but missing from Localizable.strings:"; echo "$m"; fail=1; }

# %-specifier sequence must be identical per key, or String(format:) mis-reads
# its arguments in one language.
spec() {
    grep -oE '^"[^"]+" *= *".*";$' "$1" \
        | sed -E 's/^"([^"]+)" *= *"(.*)";$/\1\t\2/' \
        | awk -F'\t' '{ s=$2; gsub(/%%/,"",s); out="";
            while (match(s,/%[0-9]*\$?[-+0#]*[0-9]*(\.[0-9]+)?(ll|l)?[@dfsuxX]/)) {
                out=out substr(s,RSTART,RLENGTH) " "; s=substr(s,RSTART+RLENGTH) }
            print $1 "\t" out }' | sort
}
spec "$R/en.lproj/Localizable.strings" > "$T/en.spec"
spec "$R/ru.lproj/Localizable.strings" > "$T/ru.spec"
d=$(diff "$T/en.spec" "$T/ru.spec" || true)
[ -n "$d" ] && { echo "::error::format specifiers differ between en and ru:"; echo "$d"; fail=1; }

# Parse property lists on both macOS and Linux, then compare top-level keys.
python3 - "$R" <<'PY' || fail=1
import plistlib
import re
import sys
from pathlib import Path

literal = re.compile(r'(?<![\w.])Fmt\.plural\s*\(\s*"([^"\\]+)"')
used = set()
for source in Path("Sources").rglob("*.swift"):
    used.update(literal.findall(source.read_text(encoding="utf-8")))

catalogs = {}
failed = False
for lang in ("en", "ru"):
    path = Path(sys.argv[1]) / f"{lang}.lproj" / "Localizable.stringsdict"
    try:
        with path.open("rb") as stream:
            catalog = plistlib.load(stream)
        if not isinstance(catalog, dict):
            raise ValueError("expected a dictionary")
    except Exception as error:
        print(f"::error::{path}: {error}")
        failed = True
        continue
    catalogs[lang] = set(catalog)
    for key in sorted(used - catalogs[lang]):
        print(f"::error::{path}: missing plural key {key}")
        failed = True

if len(catalogs) == 2 and catalogs["en"] != catalogs["ru"]:
    print(f"::error::stringsdict keys differ: {', '.join(sorted(catalogs['en'] ^ catalogs['ru']))}")
    failed = True
sys.exit(int(failed))
PY

echo "localization: en=$(wc -l < "$T/en.keys" | tr -d ' ') ru=$(wc -l < "$T/ru.keys" | tr -d ' ') used-in-code=$(wc -l < "$T/used.keys" | tr -d ' ')"

# ── 2. Closed palette ───────────────────────────────────────────────────────

if grep -rn 'Color(hex' Sources --include='*.swift' | grep -v 'Design/Theme.swift'; then
    echo "::error::Color(hex:) outside Design/Theme.swift — add a DesignTokens member instead"
    fail=1
fi

# ── 3. One formatter ────────────────────────────────────────────────────────

if grep -rnE 'ByteCountFormatter(\(|\.)' Sources --include='*.swift'; then
    echo "::error::ByteCountFormatter used — go through Fmt (Design/Format.swift)"
    fail=1
fi

[ "$fail" -eq 0 ] && echo "invariants: ok"
exit "$fail"
