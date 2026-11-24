#!/usr/bin/env bash
#
# acceptance_harness.sh -- bounded REAL acceptance test driver.
#
# NOT RUN until the auditor approves. This script REFUSES to run without:
#   1. --approve-file FILE : first line must match
#        (GROK-APPROVED|AUDITOR-APPROVED): (bounded-acceptance|full-ingest) YYYY-MM-DD
#   2. --i-understand      : explicit operator acknowledgment flag
#   3. --max-items N       : 1..25 (hard cap)
#   4. --media-id-tag TAG  : optional; namespaces media ids per batch so
#        repeated harness runs never collide (ACCEPT-<date>[-TAG]-NNNN).
#
# Without all three it exits 4 (BLOCKED_NO_APPROVAL) having touched nothing.
#
# When approved, it archives up to N real staged files (Picker downloads),
# captures pre/post evidence, verifies idempotency by rerunning, and on ANY
# failure automatically rolls back the ARCHIVER CODE (never deletes manifest
# rows or archive files -- failed-run rows are forensic evidence).
#
# Usage:
#   ./acceptance_harness.sh --approve-file /path/approval.txt \
#       --staging-dir /path/staged-picker-downloads \
#       --archive /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE \
#       --app-dir ~/JU_COMMAND_CENTER/google_photos_archiver \
#       --max-items 10 --i-understand
#
set -euo pipefail

APPROVE_FILE=""; STAGING=""; ARCHIVE=""; APP_DIR=""; MAX_ITEMS=0; UNDERSTAND=0; MID_TAG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --approve-file) APPROVE_FILE="${2:?}"; shift 2;;
    --staging-dir)  STAGING="${2:?}"; shift 2;;
    --archive)      ARCHIVE="${2:?}"; shift 2;;
    --app-dir)      APP_DIR="${2:?}"; shift 2;;
    --max-items)    MAX_ITEMS="${2:?}"; shift 2;;
    --media-id-tag) MID_TAG="${2:?}"; shift 2;;
    --i-understand) UNDERSTAND=1; shift;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

blocked() { echo "BLOCKED_NO_APPROVAL: $1" >&2; exit 4; }
[ -n "$APPROVE_FILE" ] && [ -f "$APPROVE_FILE" ] || blocked "missing --approve-file"
head -1 "$APPROVE_FILE" | grep -Eq '^(GROK-APPROVED|AUDITOR-APPROVED): (bounded-acceptance|full-ingest) [0-9]{4}-[0-9]{2}-[0-9]{2}$' \
  || blocked "approval file first line must be '(GROK-APPROVED|AUDITOR-APPROVED): (bounded-acceptance|full-ingest) YYYY-MM-DD'"
case "$MID_TAG" in
  "") : ;;
  *[!A-Za-z0-9_-]*|?????????????????*) blocked "--media-id-tag must be 1..16 chars of [A-Za-z0-9_-]" ;;
esac
[ "$UNDERSTAND" = 1 ] || blocked "missing --i-understand"
[ "$MAX_ITEMS" -ge 1 ] 2>/dev/null && [ "$MAX_ITEMS" -le 25 ] || blocked "--max-items must be 1..25"
[ -d "$STAGING" ] || blocked "staging dir not found: $STAGING"
[ -d "$ARCHIVE" ] || blocked "archive dir not found: $ARCHIVE"
[ -d "$APP_DIR" ] || blocked "app dir not found: $APP_DIR"

HERE="$(cd "$(dirname "$0")" && pwd)"
ARCHIVER="$APP_DIR/ju_photos_archiver.py"
OUTDIR="$ARCHIVE/acceptance_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
echo "approval: $(head -1 "$APPROVE_FILE")"
echo "outdir: $OUTDIR"

fail_closed() {
  # Explicit arg overrides (used by vfail); the ERR trap calls with no arg,
  # in which case rc is the failing command's status at function entry.
  local rc=${1:-$?}
  echo "ACCEPTANCE FAILED (rc=$rc) -- fail-closed: rolling back archiver code, keeping all data rows." >&2
  "$HERE/../ops/evidence_capture.sh" "$ARCHIVE" "$OUTDIR" "post-fail" || true
  "$HERE/../ops/rollback.sh" "$APP_DIR" || true
  echo "FAILURE_RECEIPT written to $OUTDIR" >&2
  exit 5
}
trap fail_closed ERR

# Explicit verification-failure path: log the reason, then take the
# fail_closed path (post-fail evidence capture + archiver-code rollback,
# exit 5). Every verification failure routes through here; a bare `exit 1`
# must never appear in a verification path.
vfail() { echo "verify FAIL: $1" >&2; fail_closed 1; }

# ---- D4: taken timestamp. Prefer sidecar metadata (Google Picker
# creationTime, Takeout photoTakenTime -> ISO-8601); else file mtime.
taken_for() {
  local f="$1" t=""
  if [ -f "$f.json" ]; then
    t="$(python3 - "$f.json" <<'PYEOF'
import datetime, json, sys
from datetime import timezone
try:
    m = json.load(open(sys.argv[1]))
except Exception:
    m = {}
v = m.get("creationTime") or m.get("photoTakenTime") or ""
if isinstance(v, dict):
    v = v.get("timestamp") or ""
v = str(v).strip()
if v.isdigit():  # Takeout epoch seconds -> ISO-8601
    v = datetime.datetime.fromtimestamp(int(v), tz=timezone.utc).isoformat()
print(v)
PYEOF
)"
  fi
  [ -n "$t" ] || t="$(python3 -c "import datetime,os,sys; print(datetime.datetime.fromtimestamp(os.path.getmtime(sys.argv[1])).astimezone().isoformat())" "$f")"
  printf '%s' "$t"
}

# ---- pre evidence (read-only) + manifest backup (copy, never move).
# A missing manifest is initialized empty via the archiver's own
# open_manifest (idempotent, creates if missing) so a first-ever run on a
# fresh archive does not fail_closed before archiving anything.
"$HERE/../ops/evidence_capture.sh" "$ARCHIVE" "$OUTDIR" "pre"
DB="$ARCHIVE/archive_manifest.db"
if [ -f "$DB" ]; then cp "$DB" "$OUTDIR/pre-manifest-backup.db"; else
  python3 -c "import sys; sys.path.insert(0, '$APP_DIR'); from ju_photos_archiver import open_manifest; open_manifest('$DB')"
fi
PRE_ROWS="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM archived_media;')"

# ---- archive up to MAX_ITEMS staged files (sidecars are auto-detected,
# never staged as media)
n=0; stored=0; reused=0
: > "$OUTDIR/items.tsv"
for f in "$STAGING"/*; do
  [ -f "$f" ] || continue
  case "$f" in *.json) continue;; esac  # D4: sidecar -> skip, never media
  [ "$n" -ge "$MAX_ITEMS" ] && break
  n=$((n+1))
  if [ -n "$MID_TAG" ]; then
    mid="ACCEPT-$(date +%Y%m%d)-${MID_TAG}-$(printf '%04d' "$n")"
  else
    mid="ACCEPT-$(date +%Y%m%d)-$(printf '%04d' "$n")"
  fi
  taken="$(taken_for "$f")"
  out="$(python3 "$ARCHIVER" --source "$f" --media-id "$mid" \
            --taken-at "$taken" --target "$ARCHIVE")"
  status="$(echo "$out" | head -1 | cut -d: -f1)"
  dest="$(echo "$out" | head -1 | cut -d' ' -f2)"
  printf '%s\t%s\t%s\t%s\n' "$mid" "$f" "$status" "$dest" >> "$OUTDIR/items.tsv"
  echo "[$n] $mid -> $status $dest"
  case "$status" in
    STORED) stored=$((stored+1));;
    DEDUP_REUSED|ALREADY_ARCHIVED) reused=$((reused+1));;
    *) vfail "unexpected status: $status";;
  esac

  # ---- D4: independent per-item verification (any mismatch -> vfail -> fail_closed)
  src_sha="$(shasum -a 256 "$f" | awk '{print $1}')"
  [ -n "$dest" ] && [ -f "$dest" ] \
    || vfail "dest missing for $mid (dest='$dest')"
  case "$dest" in
    "$ARCHIVE"/[0-9][0-9][0-9][0-9]/[0-9][0-9]/photos/*) :;;
    "$ARCHIVE"/[0-9][0-9][0-9][0-9]/[0-9][0-9]/videos/*) :;;
    *) vfail "dest outside archive layout: $dest";;
  esac
  dest_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
  [ "$dest_sha" = "$src_sha" ] \
    || vfail "source sha != dest sha for $mid"
  if [ -f "$f.json" ]; then
    sc_staged_sha="$(shasum -a 256 "$f.json" | awk '{print $1}')"
    sc_dir="$(dirname "$dest")"
    sc_stem="$(basename "$dest" | sed 's/\.[^.]*$//')"
    sc_dest=""
    # archiver convention: <dest>.json (sibling), or <stem>__<12hex>.json
    # on a sidecar collision
    if [ -f "$dest.json" ]; then sc_dest="$dest.json";
    elif [ -f "$sc_dir/${sc_stem}__${sc_staged_sha:0:12}.json" ]; then
      sc_dest="$sc_dir/${sc_stem}__${sc_staged_sha:0:12}.json"; fi
    [ -n "$sc_dest" ] \
      || vfail "sidecar not placed for $mid"
    sc_dest_sha="$(shasum -a 256 "$sc_dest" | awk '{print $1}')"
    [ "$sc_dest_sha" = "$sc_staged_sha" ] \
      || vfail "sidecar sha mismatch for $mid"
    echo "  sidecar verified: $sc_dest"
  fi
done
[ "$n" -ge 1 ] || vfail "no staged files found"

# ---- post evidence + pre-existing-row integrity diff
"$HERE/../ops/evidence_capture.sh" "$ARCHIVE" "$OUTDIR" "post"
python3 - "$OUTDIR/pre-manifest-rows.tsv" "$OUTDIR/post-manifest-rows.tsv" <<'EOF' || \
  vfail "pre-existing manifest rows mutated or deleted (see MUTATED/DELETED above)"
import sys
def load(p):
    d = {}
    for line in open(p):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 5:
            d[parts[0]] = tuple(parts[1:5])
    return d
pre, post = load(sys.argv[1]), load(sys.argv[2])
mutated = [m for m in pre if m in post and pre[m] != post[m]]
deleted = [m for m in pre if m not in post]
print(f"pre-existing rows: {len(pre)}, mutated: {len(mutated)}, deleted: {len(deleted)}")
if mutated or deleted:
    print("MUTATED:", mutated[:5]); print("DELETED:", deleted[:5]); sys.exit(1)
print("pre-existing rows untouched: OK")
EOF

# ---- idempotency rerun: same items must add 0 rows, 0 bytes
RERUN_ROWS_BEFORE="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM archived_media;')"
i=0
while IFS=$'\t' read -r mid src _status _dest; do
  i=$((i+1)); [ "$i" -gt "$MAX_ITEMS" ] && break
  taken="$(taken_for "$src")"
  out="$(python3 "$ARCHIVER" --source "$src" --media-id "$mid" \
            --taken-at "$taken" --target "$ARCHIVE")"
  echo "$out" | head -1 | grep -Eq '^(ALREADY_ARCHIVED|DEDUP_REUSED):' \
    || vfail "rerun not idempotent for $mid: $out"
done < "$OUTDIR/items.tsv"
RERUN_ROWS_AFTER="$(sqlite3 "$DB" 'SELECT COUNT(*) FROM archived_media;')"
[ "$RERUN_ROWS_BEFORE" = "$RERUN_ROWS_AFTER" ] || vfail "rerun added rows"
echo "idempotency rerun: 0 new rows OK"

# ---- D4: post-run archive-state checks
# 1. No NEW *.part files appeared during the acceptance run.
#    Pre-existing forensic .parts (e.g. intentionally kept regression probe
#    files under collision_probe/ from earlier synthetic runs) are
#    grandfathered via the pre-run file inventory -- the NO-deletion rule
#    forbids removing them, so this check fails only when a *.part path
#    appears in the post inventory but not in the pre inventory (acceptance
#    fallout). Paths under this run's OUTDIR (/acceptance_* ...) are
#    excluded, matching the inventory-diff convention below.
NEW_PARTS="$(python3 - "$OUTDIR/pre-file-shas.txt" "$OUTDIR/post-file-shas.txt" <<'EOF'
import os, sys
def load(p):
    d = {}
    for line in open(p):
        parts = line.rstrip("\n").split(None, 1)
        if len(parts) == 2:
            d[parts[1]] = parts[0]
    return d
pre, post = load(sys.argv[1]), load(sys.argv[2])
def in_acceptance(p): return "/acceptance_" in p
new_parts = sorted(p for p in post
                   if p.endswith(".part") and not in_acceptance(p)
                   and not os.path.basename(p).startswith("._")
                   and p not in pre)
for p in new_parts:
    print(p)
EOF
)"
[ -z "$NEW_PARTS" ] || vfail "new .part files appeared during acceptance run: $NEW_PARTS"
echo "no new .part files: OK"

# 2. File-inventory diff: no modified/deleted files outside acceptance_* dirs;
#    only expected new dests/sidecars (the manifest db itself is expected to
#    gain rows, and is covered by the pre-existing-row diff above).
cut -f4 "$OUTDIR/items.tsv" > "$OUTDIR/expected-dests.txt"
python3 - "$OUTDIR/pre-file-shas.txt" "$OUTDIR/post-file-shas.txt" "$OUTDIR/expected-dests.txt" <<'EOF' || \
  vfail "file-inventory diff reported modified/deleted/unexpected-new files (see above)"
import os, sys
def load(p):
    d = {}
    for line in open(p):
        parts = line.rstrip("\n").split(None, 1)
        if len(parts) == 2:
            d[parts[1]] = parts[0]
    return d
pre, post = load(sys.argv[1]), load(sys.argv[2])
expected = {l.strip() for l in open(sys.argv[3]) if l.strip()}
def is_manifest(p): return os.path.basename(p) == "archive_manifest.db"
def in_acceptance(p): return "/acceptance_" in p
def is_appledouble(p):
    # macOS AppleDouble metadata (._*) written by the OS/Finder alongside
    # real files on the archive volume; not archiver output. The raw
    # inventory still records them; only this diff ignores them.
    return os.path.basename(p).startswith("._")
def expected_new(p):
    for e in expected:
        if p == e or p == e + ".json":
            return True
        stem = os.path.basename(e).rsplit(".", 1)[0]
        # sidecar collision branch: <stem>__<12hex>.json next to the dest
        if (os.path.dirname(p) == os.path.dirname(e)
                and os.path.basename(p).startswith(stem + "__")
                and p.endswith(".json")):
            return True
    return False
modified = [p for p in pre if not in_acceptance(p) and not is_manifest(p)
            and not is_appledouble(p)
            and p in post and pre[p] != post[p]]
deleted = [p for p in pre if not in_acceptance(p) and not is_manifest(p)
           and not is_appledouble(p)
           and p not in post]
new = [p for p in post if not in_acceptance(p) and not is_manifest(p)
       and not is_appledouble(p)
       and p not in pre]
unexpected = [p for p in new if not expected_new(p)]
print(f"modified: {len(modified)}, deleted: {len(deleted)}, "
      f"new: {len(new)}, unexpected-new: {len(unexpected)}")
for p in modified[:5]: print("MODIFIED:", p)
for p in deleted[:5]: print("DELETED:", p)
for p in unexpected[:10]: print("UNEXPECTED-NEW:", p)
ok = not modified and not deleted and not unexpected
print("file-inventory diff: " + ("OK" if ok else "FAIL"))
sys.exit(0 if ok else 1)
EOF
echo "file inventory: 0 modified, 0 deleted, only expected new dests/sidecars: OK"

# ---- receipt
{
  echo "ACCEPTANCE_RECEIPT $(date -u +%FT%TZ)"
  echo "approval: $(head -1 "$APPROVE_FILE")"
  echo "items_attempted=$n stored=$stored reused=$reused"
  echo "manifest_rows_before=$PRE_ROWS manifest_rows_after=$RERUN_ROWS_AFTER"
  echo "pre-existing rows: untouched; rerun: 0 new rows"
  echo "evidence: $OUTDIR"
} | tee "$OUTDIR/ACCEPTANCE_RECEIPT.txt"

trap - ERR
echo "ACCEPTANCE_OK"
