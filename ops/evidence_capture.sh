#!/usr/bin/env bash
#
# evidence_capture.sh -- read-only pre/post evidence snapshot.
# Never writes to the archive. Never modifies the manifest.
#
#   ./evidence_capture.sh ARCHIVE OUTDIR LABEL
#
# Writes:
#   OUTDIR/<LABEL>-manifest-counts.txt   rows / distinct sha / distinct dest
#   OUTDIR/<LABEL>-manifest-rows.tsv     media_id filename sha256 destination status
#   OUTDIR/<LABEL>-file-shas.txt         sha256 of every regular file under ARCHIVE
#   OUTDIR/<LABEL>-manifest.sha256       sha256 of the manifest db file itself
#
set -euo pipefail

ARCHIVE="${1:?usage: evidence_capture.sh ARCHIVE OUTDIR LABEL}"
OUTDIR="${2:?usage: evidence_capture.sh ARCHIVE OUTDIR LABEL}"
LABEL="${3:?usage: evidence_capture.sh ARCHIVE OUTDIR LABEL}"
DB="$ARCHIVE/archive_manifest.db"

[ -d "$ARCHIVE" ] || { echo "ERROR: archive dir not found: $ARCHIVE" >&2; exit 2; }
mkdir -p "$OUTDIR"

if [ -f "$DB" ]; then
  sqlite3 -separator ' ' "$DB" \
    "SELECT COUNT(*), COUNT(DISTINCT sha256), COUNT(DISTINCT destination) FROM archived_media;" \
    > "$OUTDIR/$LABEL-manifest-counts.txt"
  sqlite3 -separator '	' "$DB" \
    "SELECT media_id, filename, sha256, destination, status FROM archived_media ORDER BY media_id;" \
    > "$OUTDIR/$LABEL-manifest-rows.tsv"
  shasum -a 256 "$DB" | awk '{print $1}' > "$OUTDIR/$LABEL-manifest.sha256"
else
  echo "NO_MANIFEST" > "$OUTDIR/$LABEL-manifest-counts.txt"
  : > "$OUTDIR/$LABEL-manifest-rows.tsv"
  echo "NO_MANIFEST" > "$OUTDIR/$LABEL-manifest.sha256"
fi

find "$ARCHIVE" -type f -exec shasum -a 256 {} + 2>/dev/null | sort -k2 \
  > "$OUTDIR/$LABEL-file-shas.txt"
wc -l "$OUTDIR/$LABEL-file-shas.txt" | awk '{print $1}' > "$OUTDIR/$LABEL-file-count.txt"

echo "EVIDENCE_CAPTURE_OK label=$LABEL outdir=$OUTDIR"
cat "$OUTDIR/$LABEL-manifest-counts.txt"
