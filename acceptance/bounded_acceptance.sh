#!/usr/bin/env bash
#
# bounded_acceptance.sh -- single-command bounded REAL acceptance driver.
#
# Orchestrates the auditor-authorized bounded acceptance flow end to end:
#   1. Vault UUID gate (exit 42 on mismatch)
#   2. Step-6 pre-evidence capture (UUID, manifest backup, row counts,
#      destination inventory, SHA-256 inventory, free space, archiver sha256,
#      rollback availability) via ops/evidence_capture.sh
#   3. Picker auth ONLY if needed: a metadata-only session probe decides.
#      Stops for exactly one human step (Ju's browser approval + callback
#      URL paste) when the setup script is missing or the token is absent.
#   4. Bounded Picker download (1 photo + 1 video), unless a non-empty
#      --staging-dir was given (download skipped).
#   5. acceptance_harness.sh with --max-items (default 2) --i-understand.
#   6. Final paste-back receipt.
#
# Never deletes anything. Never runs --live. Never modifies Picker/Google
# content. Failures propagate the harness's fail-closed trap.
#
# Usage:
#   ./bounded_acceptance.sh --app-dir DIR --approve-file FILE \
#       [--archive DIR] [--staging-dir DIR] [--max-items 2] [--timeout-s 600]
#
# VM validation only: FAKE_ROOT_OK=1 ./bounded_acceptance.sh \
#     --archive /tmp/fakevault --app-dir /tmp/fakeapp ...
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"

CANONICAL="/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE"
EXPECTED_UUID="20327ACF-C3E0-3E0E-A03B-03D10FD9438D"
ARCHIVE="$CANONICAL"; APP_DIR=""; APPROVE_FILE=""; STAGING=""
MAX_ITEMS=2; TIMEOUT_S=600

while [ $# -gt 0 ]; do
  case "$1" in
    --app-dir)      APP_DIR="${2:?}"; shift 2;;
    --archive)      ARCHIVE="${2:?}"; shift 2;;
    --approve-file) APPROVE_FILE="${2:?}"; shift 2;;
    --staging-dir)  STAGING="${2:?}"; shift 2;;
    --max-items)    MAX_ITEMS="${2:?}"; shift 2;;
    --timeout-s)    TIMEOUT_S="${2:?}"; shift 2;;
    -h|--help) sed -n '2,24p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$APP_DIR" ] || { echo "ERROR: --app-dir required" >&2; exit 2; }
[ -n "$APPROVE_FILE" ] && [ -f "$APPROVE_FILE" ] \
  || { echo "ERROR: --approve-file required (auditor approval)" >&2; exit 2; }
[ -d "$APP_DIR" ] || { echo "ERROR: app dir not found: $APP_DIR" >&2; exit 2; }
[ -f "$APP_DIR/ju_photos_archiver.py" ] \
  || { echo "ERROR: no archiver in $APP_DIR" >&2; exit 2; }

# ---- 1. vault UUID gate (mirrors regression/mac_code_gate.sh)
UUID="FAKE-ROOT"
if [ "$ARCHIVE" = "$CANONICAL" ]; then
  # NB: `|| true` shields this from `set -e`/`pipefail`: a missing volume must
  # reach the WRONG_VAULT message below, not die silently inside $().
  UUID="$(diskutil info /Volumes/JU-VAULT 2>/dev/null | awk -F': *' '/Volume UUID/{print $2}' || true)"
  if [ "$UUID" != "$EXPECTED_UUID" ]; then
    echo "WRONG_VAULT: got=${UUID:-<none>} expected=$EXPECTED_UUID" >&2
    exit 42
  fi
  echo "vault UUID OK: $UUID"
else
  [ "${FAKE_ROOT_OK:-0}" = "1" ] \
    || { echo "refusing non-canonical ARCHIVE without FAKE_ROOT_OK=1" >&2; exit 42; }
  echo "FAKE ROOT MODE (VM validation only): $ARCHIVE"
fi
[ -d "$ARCHIVE" ] || { echo "ERROR: archive dir not found: $ARCHIVE" >&2; exit 2; }

OUTDIR="$ARCHIVE/driver_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
echo "driver outdir: $OUTDIR"

# ---- 2. step-6 pre-evidence capture (reuse ops/evidence_capture.sh)
echo "--- step-6 pre-evidence ---"
"$PKG/ops/evidence_capture.sh" "$ARCHIVE" "$OUTDIR" "pre"
DB="$ARCHIVE/archive_manifest.db"
if [ -f "$DB" ]; then
  cp "$DB" "$OUTDIR/driver-pre-manifest-backup.db"
  shasum -a 256 "$DB" | awk '{print $1}' > "$OUTDIR/driver-pre-manifest.sha256"
fi
ARCHIVER_SHA="$(shasum -a 256 "$APP_DIR/ju_photos_archiver.py" | awk '{print $1}')"
{
  echo "vault_uuid=$UUID"
  echo "archiver_sha256=$ARCHIVER_SHA"
  echo "archiver_source=$APP_DIR/ju_photos_archiver.py"
  echo "manifest_rows=$(sqlite3 "$DB" 'SELECT COUNT(*) FROM archived_media;' 2>/dev/null || echo NO_MANIFEST)"
  echo "destination_inventory=$(find "$ARCHIVE" -path "$ARCHIVE/20*" -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "free_space: $(df -h "$ARCHIVE" 2>/dev/null | tail -1 || echo unknown)"
  echo "rollback_backups:"
  ls -1 "$APP_DIR"/ju_photos_archiver.py.bak-* 2>/dev/null || echo "  (none)"
} | tee "$OUTDIR/driver-pre-evidence.txt"

# ---- 3. Picker auth ONLY if needed (metadata-only session probe)
token_probe() {
  python3 - "$APP_DIR" <<'PYEOF' 2>/dev/null
import sys
sys.path.insert(0, sys.argv[1])
from google_photos_client import create_session
s = create_session()
assert isinstance(s, dict) and s.get("id"), "no session id"
print("token_probe_ok")
PYEOF
}
if token_probe; then
  echo "picker token probe: OK (session created, zero downloads)"
else
  echo "picker token probe: NO valid token"
  SETUP="$APP_DIR/setup_google_photos_auth.py"
  if [ -f "$SETUP" ]; then
    echo "=== HUMAN STEP (Ju, one time): Picker authorization ==="
    echo "The setup script will now run. Approve READ-ONLY Picker access in"
    echo "the browser, then paste ONLY the full http://localhost:8765/... URL"
    echo "at the CALLBACK URL: prompt."
    python3 "$SETUP"
    token_probe \
      || { echo "ERROR: auth still not completing; run stopped before any download" >&2; exit 1; }
    echo "picker token probe: OK after setup"
  else
    echo "=== HUMAN STEP (Ju, one time): Picker authorization ==="
    echo "No valid token and no setup script at $SETUP."
    echo "Run:  python3 ~/JU_COMMAND_CENTER/google_photos_archiver/setup_google_photos_auth.py"
    echo "Approve read-only Picker access in the browser, then paste ONLY the"
    echo "full http://localhost:8765/... URL at the CALLBACK URL: prompt."
    read -r -p "Press Enter after completing the auth step above (Ctrl-C to abort): " _
    token_probe \
      || { echo "ERROR: auth still not completing; run stopped before any download" >&2; exit 1; }
    echo "picker token probe: OK after manual setup"
  fi
fi

# ---- 4. bounded Picker download (skipped when a non-empty staging dir given)
if [ -n "$STAGING" ] && [ -d "$STAGING" ] && [ -n "$(find "$STAGING" -type f | head -1)" ]; then
  echo "using pre-staged dir (download skipped): $STAGING"
else
  STAGING="$OUTDIR/staging"
  mkdir -p "$STAGING"
  echo "--- bounded Picker download: 1 photo + 1 video ---"
  python3 "$PKG/picker/download_picker_items.py" \
    --app-dir "$APP_DIR" --staging-dir "$STAGING" \
    --expect-photo 1 --expect-video 1 --timeout-s "$TIMEOUT_S"
fi

# ---- 5. acceptance harness (fail-closed; gates on approval + --i-understand)
echo "--- acceptance harness ---"
"$PKG/acceptance/acceptance_harness.sh" \
  --approve-file "$APPROVE_FILE" \
  --staging-dir "$STAGING" \
  --archive "$ARCHIVE" \
  --app-dir "$APP_DIR" \
  --max-items "$MAX_ITEMS" --i-understand

# ---- 6. paste-back receipt (|| true: an empty HARNESS_OUT must print, not die)
HARNESS_OUT="$(ls -td "$ARCHIVE"/acceptance_* 2>/dev/null | head -1 || true)"
echo
echo "================ BOUNDED ACCEPTANCE DRIVER RECEIPT ================"
echo "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "vault_uuid: $UUID"
echo "archiver_sha256: $ARCHIVER_SHA"
echo "counts_pre: $(tr '\n' ' ' < "$OUTDIR/pre-manifest-counts.txt" 2>/dev/null)"
echo "counts_post: $(tr '\n' ' ' < "$HARNESS_OUT/post-manifest-counts.txt" 2>/dev/null)"
echo "harness_receipt: $HARNESS_OUT/ACCEPTANCE_RECEIPT.txt"
echo "driver_evidence: $OUTDIR"
echo "=================================================================="
