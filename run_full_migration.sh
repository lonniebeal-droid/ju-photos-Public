#!/usr/bin/env bash
#
# run_full_migration.sh -- one-paste full-migration launcher (runs on the Mac).
#
# Chains the already-approved tools and nothing else:
#   1. vault UUID gate + free-space record (fail-closed)
#   2. picker --unbounded staging of the whole library
#      (interactive once: the user selects photos in the Google Photos picker UI)
#   3. staging capacity check (staging must fit alongside the growing archive)
#   4. approval-file gate (/tmp/full_approval.txt, created by the human launch line)
#   5. full_ingest.sh (batches of 25 through the verified harness)
#
# It never deletes anything and never touches Google data.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCHIVE="/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE"
STAGING="$ARCHIVE/picker_full_20260928/staging"
APP_DIR="$HOME/JU_COMMAND_CENTER/google_photos_archiver"
APPROVE_FILE="/tmp/full_approval.txt"

echo "=== 1/5 vault gate ==="
diskutil info /Volumes/JU-VAULT 2>/dev/null | grep -q "20327ACF-C3E0-3E0E-A03B-03D10FD9438D" \
  || { echo "VAULT UUID MISMATCH -- refusing to run" >&2; exit 42; }
echo "vault UUID OK: 20327ACF-C3E0-3E0E-A03B-03D10FD9438D"
df -h /Volumes/JU-VAULT | tail -1

echo "=== 2/5 tool checks ==="
[ -f "$APP_DIR/google_photos_client.py" ] || { echo "photos client not found in $APP_DIR" >&2; exit 2; }
[ -f "$HERE/picker/download_picker_items.py" ] || { echo "picker script missing in $HERE/picker" >&2; exit 2; }
[ -x "$HERE/acceptance/full_ingest.sh" ] || chmod +x "$HERE/acceptance/full_ingest.sh" 2>/dev/null || true

echo "=== 3/5 stage whole library via Picker ==="
echo "A Google Photos picker session will start: select the FULL library in the picker UI."
mkdir -p "$STAGING"
python3 "$HERE/picker/download_picker_items.py" \
  --app-dir "$APP_DIR" --staging-dir "$STAGING" \
  --unbounded --timeout-s 3600
echo "staging: $(du -sh "$STAGING" | awk '{print $1}')"

echo "=== 4/5 capacity + approval gates ==="
FREE_KB=$(df -k /Volumes/JU-VAULT | tail -1 | awk '{print $4}')
STAGE_KB=$(du -sk "$STAGING" | awk '{print $1}')
if [ "$STAGE_KB" -ge $((FREE_KB / 2)) ]; then
  echo "STAGING TOO LARGE: staging ${STAGE_KB}KB >= half of free ${FREE_KB}KB." >&2
  echo "The archive grows alongside staging; chunk the Picker selection instead." >&2
  exit 5
fi
echo "capacity OK (staging ${STAGE_KB}KB, free ${FREE_KB}KB)"
[ -f "$APPROVE_FILE" ] || { echo "missing $APPROVE_FILE -- launch with the approval line" >&2; exit 4; }
head -1 "$APPROVE_FILE" | grep -Eq '^AUDITOR-APPROVED: full-ingest [0-9]{4}-[0-9]{2}-[0-9]{2}$' \
  || { echo "approval file first line malformed" >&2; exit 4; }
echo "approval OK: $(head -1 "$APPROVE_FILE")"

echo "=== 5/5 full ingest ==="
"$HERE/acceptance/full_ingest.sh" \
  --approve-file "$APPROVE_FILE" \
  --staging-dir "$STAGING" \
  --archive "$ARCHIVE" \
  --app-dir "$APP_DIR" \
  --batch-size 25 --i-understand
echo "=== MIGRATION RUN FINISHED: see the FULL_INGEST_RECEIPT path printed above ==="
