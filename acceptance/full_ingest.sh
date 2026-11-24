#!/usr/bin/env bash
#
# full_ingest.sh -- full-library ingestion via repeated VERIFIED harness runs.
#
# NOT RUN without ALL of:
#   1. --approve-file FILE : first line must be exactly
#        AUDITOR-APPROVED: full-ingest YYYY-MM-DD
#      (auditor-only; no legacy prefix accepted for full ingest)
#   2. --i-understand      : explicit operator acknowledgment flag
#   3. --staging-dir DIR   : populated by picker/download_picker_items.py
#        --unbounded (the whole Picker selection). ONLY this dir is read.
#   4. --archive DIR       : the JU-VAULT archive root
#   5. --app-dir DIR       : dir containing ju_photos_archiver.py
#
# What it does:
#   - vault UUID gate (macOS only; skipped where diskutil is absent)
#   - master pre-evidence capture (whole archive)
#   - splits staged media (non-.json) into batches of <= --batch-size
#     (default 25), symlinking each media file AND its .json sidecar into
#     per-batch dirs (no extra disk use)
#   - runs acceptance_harness.sh per batch with a namespaced --media-id-tag
#     (B001, B002, ...) so media ids never collide across batches
#   - STOPS at the first failing batch (fail-closed; the harness already
#     rolled back archiver code and kept evidence)
#   - writes FULL_INGEST_RECEIPT.txt with per-batch results + totals
#
# It never deletes anything: no manifest rows, no archive files, no staging
# files. A failed batch keeps the harness's FAILURE_RECEIPT.
#
# Usage:
#   ./full_ingest.sh --approve-file /tmp/full_approval.txt \
#       --staging-dir /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/driver_*/staging \
#       --archive /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE \
#       --app-dir ~/JU_COMMAND_CENTER/google_photos_archiver \
#       --batch-size 25 --i-understand
#
set -euo pipefail

APPROVE_FILE=""; STAGING=""; ARCHIVE=""; APP_DIR=""; BATCH_SIZE=25
WORKDIR=""; UNDERSTAND=0
while [ $# -gt 0 ]; do
  case "$1" in
    --approve-file) APPROVE_FILE="${2:?}"; shift 2;;
    --staging-dir)  STAGING="${2:?}"; shift 2;;
    --archive)      ARCHIVE="${2:?}"; shift 2;;
    --app-dir)      APP_DIR="${2:?}"; shift 2;;
    --batch-size)   BATCH_SIZE="${2:?}"; shift 2;;
    --work-dir)     WORKDIR="${2:?}"; shift 2;;
    --i-understand) UNDERSTAND=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

blocked() { echo "BLOCKED_NO_APPROVAL: $1" >&2; exit 4; }
[ -n "$APPROVE_FILE" ] && [ -f "$APPROVE_FILE" ] || blocked "missing --approve-file"
head -1 "$APPROVE_FILE" | grep -Eq '^AUDITOR-APPROVED: full-ingest [0-9]{4}-[0-9]{2}-[0-9]{2}$' \
  || blocked "approval file first line must be exactly 'AUDITOR-APPROVED: full-ingest YYYY-MM-DD'"
[ "$UNDERSTAND" = 1 ] || blocked "missing --i-understand"
[ "$BATCH_SIZE" -ge 1 ] 2>/dev/null && [ "$BATCH_SIZE" -le 25 ] || blocked "--batch-size must be 1..25"
[ -d "$STAGING" ] || blocked "staging dir not found: $STAGING"
[ -d "$ARCHIVE" ] || blocked "archive dir not found: $ARCHIVE"
[ -d "$APP_DIR" ] || blocked "app dir not found: $APP_DIR"
[ -f "$APP_DIR/ju_photos_archiver.py" ] || blocked "archiver missing in app dir"

# ---- vault UUID gate (macOS only) ----
if command -v diskutil >/dev/null 2>&1; then
  diskutil info /Volumes/JU-VAULT 2>/dev/null | grep -q "20327ACF-C3E0-3E0E-A03B-03D10FD9438D" \
    || { echo "VAULT UUID MISMATCH -- refusing to run" >&2; exit 42; }
  echo "vault UUID OK: 20327ACF-C3E0-3E0E-A03B-03D10FD9438D"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$HERE/acceptance_harness.sh"
[ -x "$HARNESS" ] || chmod +x "$HARNESS" 2>/dev/null || true
[ -f "$HARNESS" ] || { echo "harness not found: $HARNESS" >&2; exit 2; }

[ -n "$WORKDIR" ] || WORKDIR="$ARCHIVE/full_ingest_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORKDIR/batches"
echo "approval: $(head -1 "$APPROVE_FILE")"
echo "workdir: $WORKDIR"

# ---- master pre-evidence ----
"$HERE/../ops/evidence_capture.sh" "$ARCHIVE" "$WORKDIR" "pre"
DB="$ARCHIVE/archive_manifest.db"
manifest_rows() {
  # 0 when the DB or table does not exist yet (fresh archive)
  if [ -f "$1" ] && sqlite3 "$1" \
      "SELECT name FROM sqlite_master WHERE type='table' AND name='archived_media';" \
      | grep -q archived_media; then
    sqlite3 "$1" 'SELECT COUNT(*) FROM archived_media;'
  else
    echo 0
  fi
}
MASTER_PRE_ROWS="$(manifest_rows "$DB")"

# ---- collect staged media files (sidecars excluded; they travel as symlinks) ----
# NOTE: portable loop, not mapfile -- macOS ships bash 3.2 which lacks mapfile.
MEDIA=()
while IFS= read -r -d '' f; do MEDIA+=("$f"); done \
  < <(find "$STAGING" -maxdepth 1 -type f ! -name '*.json' ! -name '*.tsv' -print0 | sort -z)
TOTAL=${#MEDIA[@]}
[ "$TOTAL" -gt 0 ] || { echo "no media files staged in $STAGING -- nothing to do" >&2; exit 0; }
echo "staged media files: $TOTAL (batch size $BATCH_SIZE)"

# ---- split into batch dirs (symlinks: media + sidecar, zero extra disk) ----
NBATCH=0; i=0
for f in "${MEDIA[@]}"; do
  b=$((i / BATCH_SIZE + 1))
  bdir="$WORKDIR/batches/b$(printf '%03d' "$b")"
  mkdir -p "$bdir"
  ln -s "$f" "$bdir/$(basename "$f")"
  if [ -f "$f.json" ]; then
    ln -s "$f.json" "$bdir/$(basename "$f").json"
  fi
  i=$((i + 1))
done
NBATCH=$(( (TOTAL + BATCH_SIZE - 1) / BATCH_SIZE ))
echo "batches: $NBATCH"

# ---- run the verified harness per batch, stop at first failure ----
ATTEMPTED=0; STORED=0; REUSED=0; DONE=0
: > "$WORKDIR/batches.tsv"
for bdir in "$WORKDIR"/batches/b*/; do
  tag="$(basename "$bdir")"          # b001
  TAG="B$(printf '%03d' "$((10#${tag#b}))")"
  n_in_batch="$(find "$bdir" -maxdepth 1 -type l ! -name '*.json' | wc -l | tr -d ' ')"
  echo "--- batch $TAG ($n_in_batch items) ---"
  if "$HARNESS" --approve-file "$APPROVE_FILE" \
      --staging-dir "$bdir" --archive "$ARCHIVE" --app-dir "$APP_DIR" \
      --max-items "$n_in_batch" --media-id-tag "$TAG" --i-understand; then
    outdir="$(find "$ARCHIVE" -maxdepth 1 -type d -name 'acceptance_*' -newer "$WORKDIR/batches.tsv" | sort | tail -1)"
    receipt="$outdir/ACCEPTANCE_RECEIPT.txt"
    a=0; s=0; r=0
    if [ -f "$receipt" ]; then
      # NB: `|| true` inside each $() shields receipt parsing from
      # `set -e`/`pipefail`: a malformed receipt must yield zeros below,
      # not kill a multi-hour ingest silently mid-loop.
      a="$(grep -o 'items_attempted=[0-9]*' "$receipt" | cut -d= -f2 || true)"
      s="$(grep -o ' stored=[0-9]*' "$receipt" | tr -dc '0-9' || true)"
      r="$(grep -o ' reused=[0-9]*' "$receipt" | tr -dc '0-9' || true)"
    fi
    ATTEMPTED=$((ATTEMPTED + ${a:-0})); STORED=$((STORED + ${s:-0})); REUSED=$((REUSED + ${r:-0}))
    DONE=$((DONE + 1))
    printf '%s\t%s\t%s\t%s\t%s\n' "$TAG" "$outdir" "${a:-0}" "${s:-0}" "${r:-0}" >> "$WORKDIR/batches.tsv"
    touch "$WORKDIR/batches.tsv"
  else
    rc=$?
    {
      echo "FULL_INGEST FAILED at batch $TAG (rc=$rc)"
      echo "batches completed: $DONE/$NBATCH"
      echo "evidence: $WORKDIR"
      echo "The harness already rolled back archiver code fail-closed and kept"
      echo "its FAILURE_RECEIPT. No manifest rows or archive files were deleted."
      echo "Fix the cause, then rerun full_ingest.sh: archived batches are"
      echo "idempotent (content-hash dedup reuses them)."
    } | tee "$WORKDIR/FULL_INGEST_FAILURE.txt"
    exit "$rc"
  fi
done

# ---- master post-evidence + receipt ----
"$HERE/../ops/evidence_capture.sh" "$ARCHIVE" "$WORKDIR" "post"
MASTER_POST_ROWS="$(manifest_rows "$DB")"
{
  echo "FULL_INGEST_RECEIPT $(date -u +%FT%TZ)"
  echo "approval: $(head -1 "$APPROVE_FILE")"
  echo "batches: $DONE/$NBATCH  batch_size=$BATCH_SIZE"
  echo "items_attempted=$ATTEMPTED stored=$STORED reused=$REUSED"
  echo "manifest_rows_before=$MASTER_PRE_ROWS manifest_rows_after=$MASTER_POST_ROWS"
  echo "per-batch: TAG OUTDIR ATTEMPTED STORED REUSED"
  cat "$WORKDIR/batches.tsv"
  echo "evidence: $WORKDIR"
} | tee "$WORKDIR/FULL_INGEST_RECEIPT.txt"
echo "FULL_INGEST_OK"
