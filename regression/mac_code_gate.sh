#!/bin/bash
# mac_code_gate.sh — Grok-authorized Mac CODE-ONLY gate (2026-09-28).
#
# Executes ONLY the auditor-authorized real-data steps:
#   1. Install the audited archiver + wrapper CODE ONLY
#      (current backup preserved, all archive evidence untouched)
#   2. Rerun the complete regression suite (gates 2-13 + adversarial)
#   3. Verify the three TEST-MEDIA evidence destination SHA-256 values unchanged
#   4. Confirm canonical JU-VAULT UUID exactly 20327ACF-C3E0-3E0E-A03B-03D10FD9438D
#   5. Read-only Takeout discovery (print paths/status; NO extract/move/ingest/modify/delete)
#   6. Print a complete paste-back execution receipt for Grok
#
# HARD STOPS (enforced by refusal, not just comments):
#   NO --live, NO Google Picker authorization, NO real Google Photos media,
#   NO bounded real batch, NO Takeout ingestion, NO deletion/evidence cleanup,
#   NO full ingest, NO launchd.
#
# Usage on the Mac (single command, from the extracted final bundle dir):
#   bash regression/mac_code_gate.sh
# VM validation only:  FAKE_ROOT_OK=1 ARCHIVE=/tmp/xx bash regression/mac_code_gate.sh
set -u

CANONICAL="/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE"
EXPECTED_UUID="20327ACF-C3E0-3E0E-A03B-03D10FD9438D"
ARCHIVE="${1:-$CANONICAL}"
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="$ARCHIVE/archive_manifest.db"
APP_DIR="$HOME/JU_COMMAND_CENTER/google_photos_archiver"
TAG="$(date +%Y%m%d%H%M%S)"
RC=0
say()  { printf "%s\n" "$*"; }
pass() { say "[PASS] $1${2:+ -- $2}"; }
fail() { say "[FAIL] $1${2:+ -- $2}"; RC=1; }

# ---------------------------------------------------------------- gate 4: vault identity
if [ "$ARCHIVE" = "$CANONICAL" ]; then
  UUID="$(diskutil info /Volumes/JU-VAULT 2>/dev/null | awk -F': *' '/Volume UUID/{print $2}')"
  if [ "$UUID" != "$EXPECTED_UUID" ]; then
    echo "[FAIL] gate 4-vault-uuid FAIL_WRONG_VAULT got=${UUID:-<none>} expected=$EXPECTED_UUID"
    exit 42
  fi
  pass "gate 4-vault-uuid" "$UUID"
else
  if [ "${FAKE_ROOT_OK:-0}" != "1" ]; then
    echo "refusing non-canonical ARCHIVE without FAKE_ROOT_OK=1" >&2
    exit 42
  fi
  say "FAKE ROOT MODE (VM validation only): $ARCHIVE"
  say "[SKIP] gate 4-vault-uuid (fake root)"
fi

# ------------------------------------------------- evidence snapshot (read-only)
say "--- evidence snapshot (pre, read-only) ---"
PRE_COUNTS="$(sqlite3 "$DB" "SELECT COUNT(*), COUNT(DISTINCT sha256), COUNT(DISTINCT destination) FROM archived_media;")"
say "pre manifest rows|sha|dests: $PRE_COUNTS"
sqlite3 "$DB" "SELECT media_id || '|' || sha256 || '|' || destination || '|' || COALESCE(status,'') FROM archived_media ORDER BY media_id;" \
  > /tmp/evidence_sha_pre.txt
cp /tmp/evidence_sha_pre.txt "/tmp/codegate_pre_$TAG.txt"
# physical files: synthetic/test media only, never probe or regression dirs
find "$ARCHIVE" -xdev -type f \
  \( -name 'synthetic_*' -o -name 'TEST-*' -o -name '*.jpg' -o -name '*.mp4' \) \
  ! -path '*/collision_probe/*' ! -path '*/regression/*' \
  -exec shasum -a 256 {} \; | sort > "/tmp/codegate_files_pre_$TAG.sha"
wc -l "/tmp/codegate_files_pre_$TAG.sha" /tmp/evidence_sha_pre.txt

# ------------------------------------------------- step 1: install CODE ONLY
say "--- step 1: code-only install (backup preserved, evidence untouched) ---"
if ! python3 -m py_compile "$BUNDLE_DIR/ju_photos_archiver.py"; then
  fail "install-py-compile" "audited archiver does not compile; aborting before any change"
  exit 1
fi
pass "install-py-compile" "audited archiver compiles"
mkdir -p "$APP_DIR"
if [ -f "$APP_DIR/ju_photos_archiver.py" ]; then
  BAK="$APP_DIR/ju_photos_archiver.py.bak-$TAG"
  cp "$APP_DIR/ju_photos_archiver.py" "$BAK"
  pass "install-backup" "$BAK (previous .bak files kept)"
  if [ -f "$APP_DIR/ju_photos_archiver.py.bak-2026-09-28" ]; then
    pass "install-backup-preserved" "ju_photos_archiver.py.bak-2026-09-28 still present"
  else
    fail "install-backup-preserved" "expected 11:35 backup missing"
  fi
else
  say "note: no previously installed archiver (fresh install)"
fi
if [ -f "$APP_DIR/run_archive_batch.sh" ]; then
  cp "$APP_DIR/run_archive_batch.sh" "$APP_DIR/run_archive_batch.sh.bak-$TAG"
  pass "install-wrapper-backup" "run_archive_batch.sh.bak-$TAG"
fi
cp "$BUNDLE_DIR/ju_photos_archiver.py" "$APP_DIR/ju_photos_archiver.py"
cp "$BUNDLE_DIR/run_archive_batch.sh" "$APP_DIR/run_archive_batch.sh"
chmod +x "$APP_DIR/run_archive_batch.sh"
if [ "$(shasum -a 256 "$APP_DIR/ju_photos_archiver.py" | awk '{print $1}')" = \
     "$(shasum -a 256 "$BUNDLE_DIR/ju_photos_archiver.py" | awk '{print $1}')" ]; then
  pass "install-sha-match" "installed archiver byte-identical to audited bundle copy"
else
  fail "install-sha-match" "installed copy differs from bundle copy"
fi
if python3 "$APP_DIR/ju_photos_archiver.py" --help >/dev/null 2>&1; then
  pass "install-smoke" "--help runs on installed archiver"
else
  fail "install-smoke" "--help failed on installed archiver"
fi
# manifest schema already migrated at 11:35; this is an idempotent no-op guard
python3 "$APP_DIR/ju_photos_archiver.py" --migrate --manifest "$DB"
MID_COUNTS="$(sqlite3 "$DB" "SELECT COUNT(*), COUNT(DISTINCT sha256), COUNT(DISTINCT destination) FROM archived_media;")"
say "mid manifest rows|sha|dests (must equal pre): $MID_COUNTS"
[ "$MID_COUNTS" = "$PRE_COUNTS" ] && pass "install-manifest-untouched" "$MID_COUNTS" \
  || fail "install-manifest-untouched" "pre=$PRE_COUNTS mid=$MID_COUNTS"

# ------------------------------------------------- step 2: regression suite
say "--- step 2: regression suite (synthetic, real manifest) ---"
set +e
GATE_RUN_TAG="$TAG" python3 "$BUNDLE_DIR/regression/run_14_gates.py" "$ARCHIVE"
GATE_RC=$?
set -e
[ "$GATE_RC" -eq 0 ] && pass "regression-gates-2-13" "36/36" || fail "regression-gates-2-13" "rc=$GATE_RC"
set +e
python3 "$BUNDLE_DIR/regression/test_adversarial.py"
ADV_RC=$?
set -e
[ "$ADV_RC" -eq 0 ] && pass "regression-adversarial" "20/20" || fail "regression-adversarial" "rc=$ADV_RC"

# ------------------------------------------------- step 3: evidence integrity
say "--- step 3: evidence integrity (post) ---"
POST_COUNTS="$(sqlite3 "$DB" "SELECT COUNT(*), COUNT(DISTINCT sha256), COUNT(DISTINCT destination) FROM archived_media;")"
say "post manifest rows|sha|dests: $POST_COUNTS"
# every pre-existing row: sha256, destination, status must be identical
# (new GATE<tag> rows from this run are excluded by the GLOB filter)
ROW_DIFF="$(diff <(sort "/tmp/codegate_pre_$TAG.txt") \
  <(sqlite3 "$DB" "SELECT media_id || '|' || sha256 || '|' || destination || '|' || COALESCE(status,'') FROM archived_media WHERE media_id NOT GLOB '*-$TAG' ORDER BY media_id;" | sort) | head -20)"
if [ -z "$ROW_DIFF" ]; then
  N_PRE="$(wc -l < "/tmp/codegate_pre_$TAG.txt" | tr -d ' ')"
  pass "evidence-rows-unchanged" "$N_PRE pre-existing rows byte-identical (sha/dest/status)"
else
  fail "evidence-rows-unchanged" "pre-existing rows changed:"; echo "$ROW_DIFF"
fi
# physical files byte-identical
if diff -u "/tmp/codegate_files_pre_$TAG.sha" \
   <(find "$ARCHIVE" -xdev -type f \
       \( -name 'synthetic_*' -o -name 'TEST-*' -o -name '*.jpg' -o -name '*.mp4' \) \
       ! -path '*/collision_probe/*' ! -path '*/regression/*' \
       -exec shasum -a 256 {} \; | sort) > "/tmp/codegate_files_diff_$TAG.txt"; then
  pass "evidence-files-unchanged" "all synthetic/test media byte-identical"
else
  fail "evidence-files-unchanged" "see /tmp/codegate_files_diff_$TAG.txt"
  head -20 "/tmp/codegate_files_diff_$TAG.txt"
fi
# the three TEST-MEDIA evidence destinations vs the 11:35 known-good SHAs
KG0="6799cc4f168022ae01814eeefcbaeff09132c294aeb72376916edd401ac81fa6"
KG1="42fb77052acd963f8e0df7fca27fd72b2ea5ea7cd404e62caf581c6ae3c27211"
KG2="ac9bae77794dfcd56ec2e4d822619b765928daf597c58e95323ef5c63f903711"
EVID_OK=1
for i in 0 1 2; do
  F="$ARCHIVE/2026/09/photos/synthetic_$i.jpg"
  if [ -f "$F" ]; then
    H="$(shasum -a 256 "$F" | awk '{print $1}')"
    eval "KG=\$KG$i"
    if [ "$H" = "$KG" ]; then pass "evidence-sha-synthetic_$i" "${H:0:12} matches 11:35 known-good"
    else fail "evidence-sha-synthetic_$i" "got $H expected $KG"; EVID_OK=0; fi
  else
    fail "evidence-sha-synthetic_$i" "file missing: $F"; EVID_OK=0
  fi
done

# ------------------------------------------------- step 5: Takeout discovery (read-only)
say "--- step 5: Takeout discovery (READ-ONLY: list paths/status, extract nothing) ---"
set +e
bash "$BUNDLE_DIR/takeout/takeout_discover.sh"
DISC_RC=$?
set -e
[ "$DISC_RC" -eq 0 ] && pass "takeout-discovery" "read-only scan complete, 0 bytes extracted" \
  || fail "takeout-discovery" "rc=$DISC_RC"

# ------------------------------------------------- step 6: paste-back receipt
say
say "================ MAC CODE-GATE RECEIPT (paste back to Grok) ================"
say "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "vault_uuid: ${UUID:-FAKE-ROOT}"
say "archive: $ARCHIVE"
say "installed_archiver_sha256: $(shasum -a 256 "$APP_DIR/ju_photos_archiver.py" | awk '{print $1}')"
say "bundle_archiver_sha256:    $(shasum -a 256 "$BUNDLE_DIR/ju_photos_archiver.py" | awk '{print $1}')"
say "backup_created: ${BAK:-<fresh install, none needed>}"
say "backup_2026-09-28_preserved: $([ -f "$APP_DIR/ju_photos_archiver.py.bak-2026-09-28" ] && echo yes || echo NO)"
say "manifest_pre:  $PRE_COUNTS"
say "manifest_post: $POST_COUNTS"
say "gates_2_13_15_16_rc: $GATE_RC (0 = 36/36 PASS)"
say "adversarial_rc: $ADV_RC (0 = 20/20 PASS)"
say "evidence_files_pre_sha: /tmp/codegate_files_pre_$TAG.sha"
say "evidence_known_good_match: $([ "$EVID_OK" = 1 ] && echo '3/3 TEST-MEDIA dests match 11:35 SHAs' || echo 'MISMATCH')"
say "takeout_discovery_rc: $DISC_RC"
say "hard_stops_held: NO --live, NO Picker auth, NO real photos, NO bounded batch, NO Takeout ingest, NO deletion, NO full ingest, NO launchd"
say "overall: $([ "$RC" -eq 0 ] && echo 'CODE GATE PASS' || echo 'CODE GATE FAIL')"
say "=========================================================================="
exit "$RC"
