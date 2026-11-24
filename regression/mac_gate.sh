#!/usr/bin/env bash
#
# mac_gate.sh -- auditor-specified 14-gate run (round 2, 2026-09-28).
#
# Usage (Mac, authoritative):
#   ./mac_gate.sh
#   ./mac_gate.sh /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE
#
# VM validation only (never touches the real vault):
#   FAKE_ROOT_OK=1 ./mac_gate.sh /tmp/fakevault/GOOGLE_PHOTOS_ARCHIVE
#
# What it does, in order:
#   gate  1  vault UUID check (real path only) -- STOP 42 on mismatch
#   snapshot evidence: manifest counts, media_id|sha256, shasum of the
#            3 production dest files (probe/regression excluded)
#   backup installed archiver -> .bak-2026-09-28 (copy), install patched
#            archiver + reconstructed run_archive_batch.sh (copy)
#   explicit additive migration + overwrite_evidence labeling (visible)
#   gates 2-13 via regression/run_14_gates.py (media quarantined under
#            collision_probe/, sources under regression/)
#   gate 14  evidence shasum diff -- FAIL_EVIDENCE_MUTATED on any change
#   paste-back packet: schema dump, row SELECT, probe find+shasum, full
#            patched source text
#
# It never deletes, never runs --live, never calls the Picker, never
# touches Takeout. Failed gates stop nothing destructively: files are kept.
#
set -euo pipefail

CANONICAL="/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE"
EXPECTED_UUID="20327ACF-C3E0-3E0E-A03B-03D10FD9438D"
ARCHIVE="${1:-$CANONICAL}"
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB="$ARCHIVE/archive_manifest.db"
APP_DIR="$HOME/JU_COMMAND_CENTER/google_photos_archiver"
RC=0

# ---- gate 1: vault identity
if [ "$ARCHIVE" = "$CANONICAL" ]; then
  # NB: `|| true` shields this from `set -e`/`pipefail`: an unmounted vault must
  # reach the FAIL_WRONG_VAULT message below, not die silently inside $().
  UUID="$(diskutil info /Volumes/JU-VAULT | awk -F': *' '/Volume UUID/{print $2}' || true)"
  if [ "$UUID" != "$EXPECTED_UUID" ]; then
    echo "[FAIL] gate 1-vault-uuid FAIL_WRONG_VAULT got=$UUID"
    exit 42
  fi
  echo "[PASS] gate 1-vault-uuid $UUID"
else
  if [ "${FAKE_ROOT_OK:-0}" != "1" ]; then
    echo "refusing non-canonical ARCHIVE without FAKE_ROOT_OK=1" >&2
    exit 42
  fi
  echo "FAKE ROOT MODE (VM validation only): $ARCHIVE"
  echo "[SKIP] gate 1-vault-uuid (fake root)"
fi

# ---- snapshot evidence (do not modify)
echo "--- evidence snapshot (pre) ---"
sqlite3 "$DB" "SELECT COUNT(*), COUNT(DISTINCT sha256), COUNT(DISTINCT destination) FROM archived_media;"
sqlite3 "$DB" "SELECT media_id || '|' || sha256 || '|' || destination FROM archived_media ORDER BY media_id;" \
  > /tmp/evidence_sha_pre.txt
find "$ARCHIVE" -xdev -type f \
  \( -name 'synthetic_*' -o -name 'TEST-*' -o -name '*.jpg' -o -name '*.mp4' \) \
  ! -path '*/collision_probe/*' ! -path '*/regression/*' \
  -exec shasum -a 256 {} \; | sort > /tmp/pre_patch_dest.sha
wc -l /tmp/pre_patch_dest.sha /tmp/evidence_sha_pre.txt

# ---- backup + install (copy, never move/delete)
if [ "$ARCHIVE" = "$CANONICAL" ]; then
  if [ -f "$APP_DIR/ju_photos_archiver.py" ]; then
    cp "$APP_DIR/ju_photos_archiver.py" "$APP_DIR/ju_photos_archiver.py.bak-2026-09-28"
    echo "backup: $APP_DIR/ju_photos_archiver.py.bak-2026-09-28"
  else
    echo "note: no installed archiver found at $APP_DIR (fresh install)"
    mkdir -p "$APP_DIR"
  fi
  cp "$BUNDLE_DIR/ju_photos_archiver.py" "$APP_DIR/ju_photos_archiver.py"
  cp "$BUNDLE_DIR/run_archive_batch.sh" "$APP_DIR/run_archive_batch.sh"
  chmod +x "$APP_DIR/run_archive_batch.sh"
  echo "installed patched archiver + reconstructed batch script"
else
  echo "FAKE ROOT MODE: skipping install (testing bundle copy directly)"
fi

# ---- explicit migration (visible, additive only)
python3 "$BUNDLE_DIR/ju_photos_archiver.py" --migrate --manifest "$DB"

# ---- gates 2-13
set +e
python3 "$BUNDLE_DIR/regression/run_14_gates.py" "$ARCHIVE"
GATE_RC=$?
set -e
if [ "$GATE_RC" -ne 0 ]; then RC=1; fi

# ---- gate 14: production evidence must be byte-identical
echo "--- evidence diff (post) ---"
if diff -u /tmp/pre_patch_dest.sha \
   <(find "$ARCHIVE" -xdev -type f \
       \( -name 'synthetic_*' -o -name 'TEST-*' -o -name '*.jpg' -o -name '*.mp4' \) \
       ! -path '*/collision_probe/*' ! -path '*/regression/*' \
       -exec shasum -a 256 {} \; | sort) > /tmp/evidence_diff.txt; then
  echo "[PASS] gate 14-evidence-unmutated"
else
  echo "[FAIL] gate 14 FAIL_EVIDENCE_MUTATED"
  cat /tmp/evidence_diff.txt
  RC=1
fi

sqlite3 "$DB" "SELECT COUNT(*), COUNT(DISTINCT sha256), COUNT(DISTINCT destination) FROM archived_media;"

# ---- paste-back packet for the auditor
echo
echo "===================== PASTE-BACK PACKET ====================="
echo "===== SCHEMA ====="
sqlite3 "$DB" ".schema archived_media"
echo "===== ROWS ====="
sqlite3 "$DB" "SELECT media_id,filename,sha256,destination,status FROM archived_media ORDER BY media_id;"
echo "===== COLLISION_PROBE find+shasum ====="
find "$ARCHIVE/collision_probe" -xdev -type f -exec shasum -a 256 {} \; | sort
echo "===== PATCHED SOURCE (full text) ====="
cat "$BUNDLE_DIR/ju_photos_archiver.py"
echo "===================== END PACKET (rc=$RC) ====================="
exit "$RC"
