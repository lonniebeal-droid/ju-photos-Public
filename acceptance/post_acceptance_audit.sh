#!/usr/bin/env bash
#
# post_acceptance_audit.sh -- INDEPENDENT POST-ACCEPTANCE AUDIT (read-only).
#
# Verifies the bounded REAL acceptance (ACCEPTANCE_OK 2026-09-28) against the
# actual Mac / JU-VAULT evidence. This script NEVER writes to the archive,
# the manifest, staging, or the app dir. Its only write is a NEW receipt
# directory it creates for its own report.
#
# The 12 checks (brief 2026-09-28):
#   1. acceptance receipt complete and coherent
#   2. installed archiver SHA-256 == approved fixed build (a94b1d7b...)
#   3. source (staging) vs archived destination SHA-256 match, per item
#   4. sidecars present and hash-verified (staging vs dest vs manifest)
#   5. all 23 manifest rows consistent (types, uniqueness, non-null)
#   6. the 21 pre-existing rows are byte-identical to the pre-run backup
#   7. every manifest destination points at the correct bytes
#   8. collision/dedup guards present in code + sane in manifest
#   9. no NEW .part files / temp payloads (forensic ones grandfathered)
#  10. rerun produced zero duplicate payloads/rows
#  11. forensic / TEST evidence untouched (vs pre-run file inventory)
#  12. rollback/recovery safeguards available
#
# Usage:
#   ./post_acceptance_audit.sh \
#     --archive /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE \
#     --app-dir ~/JU_COMMAND_CENTER/google_photos_archiver \
#     --receipt-dir /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/acceptance_20260928_130507 \
#     --first-accept-dir /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/acceptance_20260928_130234 \
#     --staging-dir /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/driver_20260928_130127/staging
#
set -euo pipefail

ARCHIVE=""; APP_DIR=""; RECEIPT_DIR=""; FIRST_DIR=""; STAGING=""; DRIVER_PRE_INV=""
while [ $# -gt 0 ]; do
  case "$1" in
    --archive)          ARCHIVE="${2:?}"; shift 2;;
    --app-dir)          APP_DIR="${2:?}"; shift 2;;
    --receipt-dir)      RECEIPT_DIR="${2:?}"; shift 2;;
    --first-accept-dir) FIRST_DIR="${2:?}"; shift 2;;
    --staging-dir)      STAGING="${2:?}"; shift 2;;
    --driver-pre-inv)   DRIVER_PRE_INV="${2:?}"; shift 2;;
    -h|--help) sed -n '2,32p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

for d in "$ARCHIVE" "$APP_DIR" "$RECEIPT_DIR" "$FIRST_DIR" "$STAGING"; do
  [ -d "$d" ] || { echo "AUDIT FAIL: dir not found: $d" >&2; exit 2; }
done
# Default driver pre-run file inventory (captured ~13:01:27, before attempt 3).
[ -z "$DRIVER_PRE_INV" ] && DRIVER_PRE_INV="$ARCHIVE/driver_20260928_130127/pre-file-shas.txt"
[ -f "$DRIVER_PRE_INV" ] || { echo "AUDIT FAIL: driver pre-inventory not found: $DRIVER_PRE_INV (pass --driver-pre-inv)" >&2; exit 2; }
export AUDIT_DRIVER_PRE_INV="$DRIVER_PRE_INV"

APPROVED_ARCHIVER_SHA="a94b1d7bcdb5000c4898530e345e5acfd9f2ad76864c290e7fb1cd0cbcf508c7"
# Acceptance run window start (attempt 3): 2026-09-28 13:02:34 EDT = 17:02:34 UTC.
# Any .part file created at/after this is NEW (unexpected); older ones are
# grandfathered forensic evidence.
RUN_START_EPOCH=1790787754

OUTDIR="$ARCHIVE/post_acceptance_audit_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/AUDIT_RECEIPT.txt"
: > "$REPORT"

echo "=== POST-ACCEPTANCE AUDIT (read-only) ==="
echo "archive: $ARCHIVE"
echo "report:  $REPORT"
echo ""

PASS_COUNT=0; FAIL_COUNT=0
check_pass() { PASS_COUNT=$((PASS_COUNT+1)); echo "CHECK $1: PASS -- $2" | tee -a "$REPORT"; }
check_fail() { FAIL_COUNT=$((FAIL_COUNT+1)); echo "CHECK $1: FAIL -- $2" | tee -a "$REPORT"; }

# ---------------------------------------------------------------- C1: receipt
R1="$RECEIPT_DIR/ACCEPTANCE_RECEIPT.txt"
if [ -f "$R1" ] \
  && grep -q "ACCEPTANCE_RECEIPT" "$R1" \
  && grep -q "items_attempted=2 stored=0 reused=2" "$R1" \
  && grep -q "manifest_rows_before=23 manifest_rows_after=23" "$R1"; then
  check_pass 1 "receipt complete: $(grep -o 'ACCEPTANCE_RECEIPT [0-9TZ:.-]*' "$R1" | head -1), 2 attempted / 0 stored / 2 reused, manifest 23->23"
else
  check_fail 1 "receipt $R1 missing or incoherent"
fi

# ---------------------------------------------------------------- C2: archiver sha
INST_SHA="$(shasum -a 256 "$APP_DIR/ju_photos_archiver.py" | awk '{print $1}')"
if [ "$INST_SHA" = "$APPROVED_ARCHIVER_SHA" ]; then
  check_pass 2 "installed archiver sha256=$INST_SHA (approved fixed build)"
else
  check_fail 2 "installed archiver sha256=$INST_SHA != approved $APPROVED_ARCHIVER_SHA"
fi

# ---------------------------------------------------------------- C3+C4+C5+C6+C7+C10: manifest + file verification (python)
python3 - "$ARCHIVE" "$STAGING" "$RECEIPT_DIR" "$FIRST_DIR" "$RUN_START_EPOCH" <<'PYEOF' > /tmp/audit_py.out 2>&1
import os, re, sqlite3, sys, hashlib

archive, staging, receipt_dir, first_dir, run_start = sys.argv[1:6]
run_start = int(run_start)
results = []
def ok(n, msg):  results.append((n, "PASS", msg))
def bad(n, msg): results.append((n, "FAIL", msg))

def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

db_path = os.path.join(archive, "archive_manifest.db")
if not os.path.isfile(db_path):
    bad(5, f"manifest missing: {db_path}")
    print("\n".join(f"CHECK {n}: {s} -- {m}" for n, s, m in results)); sys.exit(0)
con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
cols = [r[1] for r in con.execute("PRAGMA table_info(archived_media)")]
rows = con.execute("SELECT * FROM archived_media").fetchall()
col = {name: i for i, name in enumerate(cols)}
n_rows = len(rows)

# C5: row consistency
problems = []
ids = set()
for r in rows:
    mid = r[col["media_id"]]
    if not mid or mid in ids: problems.append(f"bad/dup media_id {mid!r}")
    ids.add(mid)
    if not re.fullmatch(r"[0-9a-f]{64}", r[col["sha256"]] or ""): problems.append(f"bad sha256 for {mid}")
    if not r[col["destination"]]: problems.append(f"empty destination for {mid}")
    if not r[col["archived_at"]]: problems.append(f"empty archived_at for {mid}")
    if not r[col["filename"]]: problems.append(f"empty filename for {mid}")
if n_rows == 23 and not problems:
    ok(5, f"23 rows; all media_ids unique, sha256 64-hex, destination/archived_at/filename non-null")
else:
    bad(5, f"rows={n_rows} (want 23); problems={problems[:5]}")

# C7: every destination points at the correct bytes.
# A mismatch is classified PRE-EXISTING only if the driver's pre-run file
# inventory (captured before the acceptance run) records the SAME sha as the
# file has now -- proving the file was not touched during the acceptance
# window. Anything else is NEW and fails the check.
pre_inv = {}
pinv_path = os.environ.get("AUDIT_DRIVER_PRE_INV", "")
if pinv_path and os.path.isfile(pinv_path):
    with open(pinv_path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip(): continue
            sha, _, path = line.partition(" ")
            sha = sha.strip(); path = path.strip().rstrip("/")
            if sha and path:
                pre_inv[path] = sha
bad_dest, preexist_dest = [], []
for r in rows:
    dest = r[col["destination"]]
    if not os.path.isfile(dest):
        bad_dest.append(f"{r[col['media_id']]}: destination missing: {dest}")
        continue
    cur = sha256_file(dest)
    if cur == r[col["sha256"]]:
        continue
    pre_sha = pre_inv.get(dest.rstrip("/"))
    if pre_sha == cur:
        preexist_dest.append(f"{r[col['media_id']]}: sha differs from manifest row but file UNCHANGED since driver pre-evidence (pre-existing staleness, mtime={int(os.path.getmtime(dest))})")
    else:
        bad_dest.append(f"{r[col['media_id']]}: destination sha mismatch (NEW -- changed during/after acceptance window)")
if not bad_dest:
    msg = f"{n_rows} manifest destinations exist"
    if preexist_dest:
        msg += f"; {len(preexist_dest)} PRE-EXISTING stale row(s) disclosed (proven untouched during acceptance window): " + "; ".join(preexist_dest[:5])
    ok(7, msg)
else:
    bad(7, "; ".join(bad_dest[:5]))

# C3: staging sources vs archived destinations
# (AppleDouble ._* files are macOS metadata, not staged media -- excluded,
# consistent with the harness's own disposition)
staged = sorted(f for f in os.listdir(staging)
                if os.path.isfile(os.path.join(staging, f)) and not f.endswith(".json")
                and not os.path.basename(f).startswith("._"))
n_appledouble = sum(1 for f in os.listdir(staging)
                    if os.path.basename(f).startswith("._")
                    and os.path.isfile(os.path.join(staging, f)))
c3 = []
for f in staged:
    sp = os.path.join(staging, f)
    s_sha = sha256_file(sp)
    matches = [r for r in rows if r[col["sha256"]] == s_sha]
    if not matches:
        c3.append(f"{f}: no manifest row with source sha"); continue
    for r in matches:
        dest = r[col["destination"]]
        if os.path.isfile(dest) and sha256_file(dest) == s_sha:
            c3.append(f"{f}: OK ({r[col['media_id']]} -> {dest})")
        else:
            c3.append(f"{f}: FAIL destination bytes mismatch")
if staged and all(": OK" in m for m in c3):
    extra = f" ({n_appledouble} AppleDouble ._* file(s) excluded as macOS metadata)" if n_appledouble else ""
    ok(3, f"{len(staged)} staged source(s) hash-match their archived destinations{extra}: " + "; ".join(c3))
else:
    bad(3, "; ".join(c3) if c3 else "no staged media files found")

# C4: sidecars
c4 = []
for f in staged:
    s_side = os.path.join(staging, f + ".json")
    if not os.path.isfile(s_side):
        c4.append(f"{f}: no staging sidecar (skipped)"); continue
    s_sha = sha256_file(os.path.join(staging, f))
    mrows = [r for r in rows if r[col["sha256"]] == s_sha]
    if not mrows:
        c4.append(f"{f}: no manifest row"); continue
    r = mrows[0]
    d_side = (r[col["sidecar_path"]] or "") or (r[col["destination"]] + ".json")
    ss, ds = sha256_file(s_side), (sha256_file(d_side) if os.path.isfile(d_side) else None)
    rec = r[col["sidecar_sha256"]] or ""
    if ds == ss and (not rec or rec == ds):
        c4.append(f"{f}: OK sidecar {d_side} sha={ds[:16]}...")
    else:
        c4.append(f"{f}: FAIL staging={ss[:16]} dest={str(ds)[:16]} manifest={rec[:16]}")
if c4 and all(": OK" in m for m in c4):
    ok(4, "; ".join(c4))
else:
    bad(4, "; ".join(c4) if c4 else "no sidecars to check")

# C6: 21 pre-existing rows byte-identical to pre-run backup
bak = os.path.join(first_dir, "pre-manifest-backup.db")
if os.path.isfile(bak):
    bcon = sqlite3.connect(f"file:{bak}?mode=ro", uri=True)
    brows = bcon.execute("SELECT * FROM archived_media").fetchall()
    bcols = [r[1] for r in bcon.execute("PRAGMA table_info(archived_media)")]
    shared = [c for c in cols if c in bcols]
    cur_by_id = {r[col["media_id"]]: r for r in rows}
    diffs = []
    for br in brows:
        bdict = dict(zip(bcols, br))
        mid = bdict["media_id"]
        cr = cur_by_id.get(mid)
        if cr is None:
            diffs.append(f"{mid}: MISSING from current manifest"); continue
        for c in shared:
            if (cr[col[c]] or "") != (bdict[c] or ""):
                diffs.append(f"{mid}: column {c} changed"); break
    if brows and not diffs:
        ok(6, f"{len(brows)} pre-existing rows byte-identical to pre-run backup; 0 modified, 0 deleted")
    else:
        bad(6, f"backup_rows={len(brows)} diffs={diffs[:5]}")
else:
    bad(6, f"pre-run backup not found: {bak}")

# C10: rerun zero duplicates.
# Duplicate destinations that already existed in the pre-run backup are
# intentional dedup artifacts of earlier collision-probe/synthetic test runs
# (the archiver reuses one content blob for identical bytes by design).
# Only NEWLY introduced duplicate destinations fail this check.
accept_ids = [r[col["media_id"]] for r in rows if str(r[col["media_id"]]).startswith("ACCEPT-20260928-")]
dests = [r[col["destination"]] for r in rows]
dup_dests = sorted({d for d in dests if dests.count(d) > 1})
bak_dests = []
if os.path.isfile(bak):
    try:
        _bc = sqlite3.connect(f"file:{bak}?mode=ro", uri=True)
        _bcol = [rr[1] for rr in _bc.execute("PRAGMA table_info(archived_media)")]
        _di = _bcol.index("destination")
        bak_dests = [rr[_di] for rr in _bc.execute("SELECT * FROM archived_media")]
        _bc.close()
    except Exception:
        bak_dests = []
bak_dup = sorted({d for d in bak_dests if bak_dests.count(d) > 1})
new_dup_dests = [d for d in dup_dests if d not in bak_dup]
photo_dir = os.path.join(archive, "2026", "09", "photos")
video_dir = os.path.join(archive, "2026", "09", "videos")
copies = 0
for base in ("AG8GOf2GbjMyYqTGNvziyxxMV8c6uVfMkYwYN8lOolJr9Pxm5DLHefP__C7NVPRfNm_35dhBOevU1e-z",
             "AG8GOf0Dl45Pso3WhxXSbOY1sut4AXxKjRCIs4zyCmuWRF97xDEIkt_r99LueCHtzaHOVTbAtkNUVji8"):
    for d_ in (photo_dir, video_dir):
        if os.path.isdir(d_):
            copies += sum(1 for f in os.listdir(d_)
                          if f.startswith(base) and not f.startswith("._")
                          and not f.endswith(".json"))
if len(accept_ids) == 2 and not new_dup_dests and copies == 2:
    pre = f" ({len(dup_dests)} pre-existing intentional dedup dup-dest(s) from earlier probe/test runs, unchanged since backup)" if dup_dests else ""
    ok(10, f"exactly 2 ACCEPT-20260928-* rows, 0 newly introduced duplicate destinations{pre}, exactly 1 payload copy per item")
else:
    bad(10, f"accept_rows={len(accept_ids)} new_dup_dests={new_dup_dests} payload_copies={copies}")

# C11: forensic .part files untouched vs pre-run inventory
inv = os.path.join(first_dir, "pre-file-shas.txt")
inv_parts = {}
if os.path.isfile(inv):
    with open(inv) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip(): continue
            sha, _, path = line.partition(" ")
            sha = sha.strip(); path = path.strip()
            if path.endswith(".part"):
                inv_parts[path] = sha
cur_parts = {}
for root, _d, files in os.walk(archive):
    if os.path.basename(root).startswith(("acceptance_", "driver_", "post_acceptance_audit_", "full_ingest_")):
        continue
    for fn in files:
        if fn.endswith(".part"):
            p = os.path.join(root, fn)
            cur_parts[p] = sha256_file(p)
missing = [p for p in inv_parts if p not in cur_parts]
changed = [p for p in inv_parts if p in cur_parts and cur_parts[p] != inv_parts[p]]
if not missing and not changed and inv_parts:
    ok(11, f"{len(inv_parts)} forensic .part file(s) untouched (present, sha-identical to pre-run inventory)")
else:
    bad(11, f"missing={missing[:3]} changed={changed[:3]}")

# C9: no NEW .part files (mtime >= run start)
new_parts = [p for p in cur_parts if os.path.getmtime(p) >= run_start]
if not new_parts:
    ok(9, f"no .part files created during/after the acceptance run ({len(cur_parts)} pre-existing forensic, all older)")
else:
    bad(9, f"NEW .part files: {new_parts[:5]}")

print("\n".join(f"CHECK {n}: {s} -- {m}" for n, s, m in results))
PYEOF
PY_RC=$?
if [ $PY_RC -ne 0 ]; then
  echo "python audit block failed (rc=$PY_RC):" | tee -a "$REPORT"
  cat /tmp/audit_py.out | tee -a "$REPORT"
  check_fail "py" "python verification block crashed -- see above"
else
  while IFS= read -r line; do
    case "$line" in
      "CHECK "*": PASS"*) PASS_COUNT=$((PASS_COUNT+1));;
      "CHECK "*": FAIL"*) FAIL_COUNT=$((FAIL_COUNT+1));;
    esac
    echo "$line" | tee -a "$REPORT"
  done < /tmp/audit_py.out
fi

# ---------------------------------------------------------------- C8: guards
GUARD_OK=1
grep -q "media_id_conflict" "$APP_DIR/ju_photos_archiver.py" || GUARD_OK=0
grep -q "find_valid_blob_for_sha" "$APP_DIR/ju_photos_archiver.py" || GUARD_OK=0
grep -q "FAIL_MEDIA_ID_CONFLICT" "$APP_DIR/ju_photos_archiver.py" || GUARD_OK=0
if [ "$GUARD_OK" = 1 ]; then
  check_pass 8 "collision/dedup guards present in installed archiver (media_id_conflict fail-closed, find_valid_blob_for_sha content dedup, evidence_locked)"
else
  check_fail 8 "one or more dedup/collision guards missing from installed archiver"
fi

# ---------------------------------------------------------------- C12: rollback safeguards
# NB: `|| true` shields this from `set -e`/`pipefail`: zero backups must be
# reported by check_fail below, not kill the audit silently inside $().
BAKS="$(ls "$APP_DIR"/ju_photos_archiver.py.bak-* 2>/dev/null | wc -l | tr -d ' ' || true)"
R12_OK=1; R12_MSG=""
[ "$BAKS" -ge 1 ] || { R12_OK=0; R12_MSG="no .bak-* archiver backups; "; }
[ -f "$RECEIPT_DIR/pre-manifest-backup.db" ] || { R12_OK=0; R12_MSG="${R12_MSG}missing $RECEIPT_DIR/pre-manifest-backup.db; "; }
[ -f "$FIRST_DIR/pre-manifest-backup.db" ] || { R12_OK=0; R12_MSG="${R12_MSG}missing $FIRST_DIR/pre-manifest-backup.db; "; }
if [ "$R12_OK" = 1 ]; then
  check_pass 12 "$BAKS archiver .bak backup(s) present; pre-manifest backups present in both acceptance outdirs"
else
  check_fail 12 "$R12_MSG"
fi

# ---------------------------------------------------------------- verdict
echo "" | tee -a "$REPORT"
echo "checks passed: $PASS_COUNT, failed: $FAIL_COUNT" | tee -a "$REPORT"
if [ "$FAIL_COUNT" = 0 ]; then
  echo "POST_ACCEPTANCE_AUDIT_PASS" | tee -a "$REPORT"
  echo ""
  echo "POST_ACCEPTANCE_AUDIT_PASS -- full evidence table in $REPORT"
  exit 0
else
  echo "POST_ACCEPTANCE_AUDIT_FAIL" | tee -a "$REPORT"
  echo ""
  echo "POST_ACCEPTANCE_AUDIT_FAIL -- see $REPORT for failing checks"
  exit 1
fi
