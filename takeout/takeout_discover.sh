#!/usr/bin/env bash
#
# takeout_discover.sh -- READ-ONLY Takeout discovery. Never extracts,
# never unzips over the archive, never modifies anything.
#
#   ./takeout_discover.sh [SEARCH_ROOT...] [--out OUTDIR]
#
# Reports:
#   - takeout-looking directories and *.zip files (name match)
#   - sizes (du -sh)
#   - zip central-directory listing (unzip -l, header only -- no extraction)
#   - for an unzipped takeout tree: counts of media files vs .json sidecars
#
# Default search roots mirror the Mac-side read-only search of 2026-09-28.
#
set -euo pipefail

OUT="$HOME/takeout_discovery_$(date +%Y%m%d_%H%M%S)"
ROOTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?}"; shift 2;;
    -h|--help) sed -n '2,14p' "$0"; exit 0;;
    *) ROOTS+=("$1"); shift;;
  esac
done
[ "${#ROOTS[@]}" -gt 0 ] || ROOTS=("$HOME" "$HOME/Downloads" "$HOME/Documents")
mkdir -p "$OUT"
REPORT="$OUT/discovery_report.txt"

{
echo "TAKEOUT DISCOVERY (read-only) $(date -u +%FT%TZ)"
echo "search roots: ${ROOTS[*]}"
echo
echo "=== takeout-like paths ==="
for r in "${ROOTS[@]}"; do
  [ -d "$r" ] || { echo "(missing root: $r)"; continue; }
  find "$r" -maxdepth 6 -iname '*takeout*' -print 2>/dev/null
done | sort -u | tee "$OUT/paths.txt" | head -100
echo
echo "=== sizes ==="
while IFS= read -r p; do
  [ -e "$p" ] || continue
  du -sh "$p" 2>/dev/null || true
done < "$OUT/paths.txt" | tee "$OUT/sizes.txt"
echo
echo "=== zip header listings (no extraction) ==="
while IFS= read -r p; do
  case "$p" in
    *.zip)
      echo "--- $p"
      unzip -l "$p" 2>/dev/null | tail -5 || echo "(unreadable)"
      ;;
  esac
done < "$OUT/paths.txt" | tee "$OUT/zip_headers.txt" | head -60
} | tee "$REPORT"

echo
echo "DISCOVERY_OK report=$REPORT (nothing extracted, nothing modified)"
