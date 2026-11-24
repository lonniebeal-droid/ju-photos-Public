#!/usr/bin/env bash
#
# manifest_rollback.sh -- roll the MANIFEST DATABASE back to a backup copy.
#
#   ./manifest_rollback.sh ARCHIVE BACKUP_DB [OUTDIR]
#
# Copy-only: never deletes anything. Steps:
#   1. Verify BACKUP_DB is a readable sqlite db containing archived_media
#      (else exit 2).
#   2. If $ARCHIVE/archive_manifest.db exists: copy it to
#      $OUTDIR/current-manifest-before-rollback-<TS>.db (default OUTDIR =
#      $ARCHIVE) and verify the copy's sha256 == the original's.
#   3. Copy BACKUP_DB -> $ARCHIVE/archive_manifest.db; verify the installed
#      sha256 == the backup's sha256.
#   4. Print row counts before/after. Exit 0 on success.
#
# Used by the auditor's post-acceptance rule: "ROLL BACK DATABASE STATE IF
# REQUIRED" (media/evidence files are preserved; only the db is restored).
#
set -euo pipefail

ARCHIVE="${1:?usage: manifest_rollback.sh ARCHIVE BACKUP_DB [OUTDIR]}"
BACKUP_DB="${2:?usage: manifest_rollback.sh ARCHIVE BACKUP_DB [OUTDIR]}"
OUTDIR="${3:-$ARCHIVE}"
TS="$(date +%Y%m%d_%H%M%S)"
DB="$ARCHIVE/archive_manifest.db"

[ -f "$BACKUP_DB" ] || { echo "ERROR: backup db not found: $BACKUP_DB" >&2; exit 2; }
BACKUP_ROWS="$(sqlite3 "$BACKUP_DB" "SELECT COUNT(*) FROM archived_media;" 2>/dev/null)" \
  || { echo "ERROR: $BACKUP_DB is not a readable sqlite db with table archived_media" >&2; exit 2; }
BACKUP_SHA="$(shasum -a 256 "$BACKUP_DB" | awk '{print $1}')"
[ -d "$ARCHIVE" ] || { echo "ERROR: archive dir not found: $ARCHIVE" >&2; exit 2; }
mkdir -p "$OUTDIR"

# ---- 2. preserve the current manifest (copy-only, sha-verified)
CUR_ROWS="(none)"
if [ -f "$DB" ]; then
  CUR_SHA="$(shasum -a 256 "$DB" | awk '{print $1}')"
  CUR_ROWS="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM archived_media;' 2>/dev/null || echo '?')"
  PRESERVED="$OUTDIR/current-manifest-before-rollback-$TS.db"
  cp "$DB" "$PRESERVED"
  [ "$(shasum -a 256 "$PRESERVED" | awk '{print $1}')" = "$CUR_SHA" ] \
    || { echo "ERROR: preserved-copy sha mismatch" >&2; exit 1; }
  echo "preserved current manifest -> $PRESERVED rows=$CUR_ROWS sha=$CUR_SHA"
else
  echo "note: no current manifest at $DB (fresh restore)"
fi

# ---- 3. restore the backup, verify byte-identity
cp "$BACKUP_DB" "$DB"
INSTALLED_SHA="$(shasum -a 256 "$DB" | awk '{print $1}')"
[ "$INSTALLED_SHA" = "$BACKUP_SHA" ] \
  || { echo "ERROR: installed manifest sha mismatch" >&2; exit 1; }
NEW_ROWS="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM archived_media;')"

echo "restored: $DB <- $BACKUP_DB"
echo "manifest_rows_before=$CUR_ROWS manifest_rows_after=$NEW_ROWS (backup had $BACKUP_ROWS)"
echo "manifest_sha256=$INSTALLED_SHA"
echo "MANIFEST_ROLLBACK_OK"
