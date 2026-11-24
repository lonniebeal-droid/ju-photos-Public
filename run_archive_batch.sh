#!/usr/bin/env bash
#
# run_archive_batch.sh -- reconstructed 2026-09-28 (audit round 2).
#
# DEFAULT MODE IS DRY-RUN / SYNTHETIC. This script never deletes, never
# launches anything, never calls the Photos Picker, and never archives
# real photos.
#
#   ./run_archive_batch.sh                 -> dry-run over synthetic fixtures
#   ./run_archive_batch.sh --synthetic      -> same, explicit
#   ./run_archive_batch.sh --live           -> BLOCKED_AUDITOR, exit 3
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIVER="$SCRIPT_DIR/ju_photos_archiver.py"
TARGET="${JU_ARCHIVE_TARGET:-/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE}"
MODE="dry-run"

while [ $# -gt 0 ]; do
  case "$1" in
    --live)
      echo "BLOCKED_AUDITOR: live batches are not approved by the auditor." >&2
      echo "Bounded real batch: NO. Full ingest: NO." >&2
      exit 3
      ;;
    --synthetic|--dry-run) MODE="dry-run" ;;
    --target=*) TARGET="${1#--target=}" ;;
    --target) TARGET="${2:?--target needs a directory}"; shift ;;
    -h|--help)
      echo "usage: $0 [--dry-run|--synthetic] [--target DIR] [--live]"
      echo "default: dry-run. --live exits 3 (BLOCKED_AUDITOR)."
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "mode=$MODE target=$TARGET"
echo "DRY-RUN: no files copied, no manifest writes. Planned actions:"
echo "  - verify archiver CLI contract (--help)"
echo "  - verify manifest schema (read-only)"

python3 "$ARCHIVER" --help >/dev/null
echo "  [ok] archiver CLI responds"

MANIFEST="$TARGET/archive_manifest.db"
if [ -f "$MANIFEST" ]; then
  sqlite3 -separator ' ' "$MANIFEST" \
    "SELECT COUNT(*), COUNT(DISTINCT sha256), COUNT(DISTINCT destination) FROM archived_media;" \
    | awk '{print "  [ok] manifest rows=" $1 " distinct_sha=" $2 " distinct_dest=" $3}'
else
  echo "  [info] no manifest yet at $MANIFEST (nothing to do in dry-run)"
fi

echo "DRY-RUN COMPLETE: 0 files copied, 0 rows written, 0 deleted."
