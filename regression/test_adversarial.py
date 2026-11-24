#!/usr/bin/env python3
"""
Adversarial tests for the patched archiver (synthetic only, temp dirs).

M1: same media_id + DIFFERENT bytes -> must fail closed (media_id_conflict),
    no row, no dest file, no traceback.
M2: same media_id + same sha, recorded dest deleted -> reassociate to a valid
    blob via UPDATE for normal rows (no duplicate file).
M3: M2 on an overwrite_evidence row -> fail closed (evidence_locked), row untouched.
M4: dest_for when primary exists as a DIRECTORY -> hashed name, no traceback.
M5: weird filenames (spaces, unicode, no ext, leading dots) archive fine.
M6: empty (0-byte) file archives fine.
M7: unparseable --taken-at -> clean error, exit 1, no row.
M8: sidecar with identical bytes to media -> SIDECAR_FAIL, media kept.
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

ARCHIVER = Path(__file__).resolve().parents[1] / "ju_photos_archiver.py"

PASS = []
FAIL = []


def check(name, cond, detail=""):
    (PASS if cond else FAIL).append(name)
    print(f"[{'PASS' if cond else FAIL}] {name}" + (f" -- {detail}" if detail else ""))


def run_archiver(*args):
    return subprocess.run([sys.executable, str(ARCHIVER), *args],
                          capture_output=True, text=True)


def make_env():
    tmp = Path(tempfile.mkdtemp(prefix="juadv_"))
    src = tmp / "src"
    src.mkdir()
    tgt = tmp / "vault"
    man = str(tgt / "archive_manifest.db")
    return tmp, src, tgt, man


def write(p, data):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data if isinstance(data, bytes) else data.encode())
    return str(p)


def rows(man):
    if not Path(man).exists():
        return []
    con = sqlite3.connect(man)
    try:
        return con.execute("SELECT media_id, sha256, destination, status FROM archived_media ORDER BY media_id").fetchall()
    finally:
        con.close()


def files_under(tgt):
    return sorted(p for p in Path(tgt).rglob("*")
                  if p.is_file() and p.suffix != ".part"
                  and p.name != "archive_manifest.db")


def main():
    # M1: media_id conflict -> fail closed, no traceback
    tmp, src, tgt, man = make_env()
    a = write(src / "a.jpg", b"A" * 100)
    b = write(src / "b.jpg", b"B" * 100)
    r1 = run_archiver("--source", a, "--media-id", "MID-1", "--taken-at", "2026-09-28T10:00:00",
                      "--target", str(tgt), "--manifest", man)
    r2 = run_archiver("--source", b, "--media-id", "MID-1", "--taken-at", "2026-09-28T10:00:00",
                      "--target", str(tgt), "--manifest", man)
    check("M1-conflict-status", "MEDIA_ID_CONFLICT" in r2.stdout, r2.stdout.strip().splitlines()[:1])
    check("M1-conflict-exit-nonzero", r2.returncode != 0, f"exit={r2.returncode}")
    check("M1-conflict-no-traceback", "Traceback" not in r2.stderr and "IntegrityError" not in r2.stderr,
          (r2.stderr.strip().splitlines() or [""])[0][:80])
    check("M1-conflict-one-row", len(rows(man)) == 1, f"rows={len(rows(man))}")
    check("M1-conflict-one-file", len(files_under(tgt)) == 1, f"files={len(files_under(tgt))}")

    # M2: same sha, dest deleted -> reassociate (non-evidence row)
    tmp, src, tgt, man = make_env()
    a = write(src / "a.jpg", b"A" * 100)
    run_archiver("--source", a, "--media-id", "MID-R", "--taken-at", "2026-09-28T10:00:00",
                 "--target", str(tgt), "--manifest", man)
    # second media_id with SAME bytes -> dedup to same dest
    c = write(src / "c.jpg", b"A" * 100)
    run_archiver("--source", c, "--media-id", "MID-R2", "--taken-at", "2026-09-28T10:00:00",
                 "--target", str(tgt), "--manifest", man)
    r0 = rows(man)
    dest0 = r0[0][2]
    os.remove(dest0)  # external deletion of MID-R's recorded dest
    r = run_archiver("--source", a, "--media-id", "MID-R", "--taken-at", "2026-09-28T10:00:00",
                     "--target", str(tgt), "--manifest", man)
    # repair path: either re-pointed at a surviving blob (REASSOCIATED) or
    # re-copied from source with a row UPDATE (STORED with repair detail)
    check("M2-repaired", "REASSOCIATED" in r.stdout or "repair" in r.stdout,
          r.stdout.strip().splitlines()[:1])
    r1rows = rows(man)
    check("M2-no-new-rows", len(r1rows) == 2, f"rows={len(r1rows)}")
    check("M2-no-dup-file", len(files_under(tgt)) == 1, f"files={len(files_under(tgt))}")
    check("M2-row-points-at-blob", r1rows[0][2] == r1rows[1][2] and Path(r1rows[0][2]).is_file())

    # M3: same on overwrite_evidence row -> fail closed, untouched
    tmp, src, tgt, man = make_env()
    a = write(src / "a.jpg", b"A" * 100)
    run_archiver("--source", a, "--media-id", "MID-E", "--taken-at", "2026-09-28T10:00:00",
                 "--target", str(tgt), "--manifest", man)
    con = sqlite3.connect(man)
    con.execute("UPDATE archived_media SET status='overwrite_evidence' WHERE media_id='MID-E'")
    con.commit()
    dest_e = con.execute("SELECT destination FROM archived_media WHERE media_id='MID-E'").fetchone()[0]
    con.close()
    os.remove(dest_e)
    r = run_archiver("--source", a, "--media-id", "MID-E", "--taken-at", "2026-09-28T10:00:00",
                     "--target", str(tgt), "--manifest", man)
    check("M3-evidence-locked", "EVIDENCE_LOCKED" in r.stdout, r.stdout.strip().splitlines()[:1])
    check("M3-exit-nonzero", r.returncode != 0, f"exit={r.returncode}")
    con = sqlite3.connect(man)
    st = con.execute("SELECT status, destination FROM archived_media WHERE media_id='MID-E'").fetchone()
    con.close()
    check("M3-row-untouched", st == ("overwrite_evidence", dest_e), str(st))

    # M4: primary exists as directory -> hashed name, no traceback
    tmp, src, tgt, man = make_env()
    d = tgt / "2026" / "09" / "photos"
    d.mkdir(parents=True)
    (d / "dirclash.jpg").mkdir()  # a DIRECTORY where the file would go
    a = write(src / "dirclash.jpg", b"Z" * 50)
    r = run_archiver("--source", a, "--media-id", "MID-D", "--taken-at", "2026-09-28T10:00:00",
                     "--target", str(tgt), "--manifest", man)
    check("M4-no-traceback", "Traceback" not in r.stderr, (r.stderr.strip().splitlines() or [""])[0][:80])
    check("M4-stored-hashed", "STORED" in r.stdout and "__" in r.stdout, r.stdout.strip().splitlines()[:1])

    # M5: weird filenames
    tmp, src, tgt, man = make_env()
    names = ["my photo (1).JPG", "ünïcödé_图片.jpg", "noext", ".hidden.jpg", "a.b.c.d.jpeg"]
    ok = True
    for i, n in enumerate(names):
        p = write(src / n, f"content-{i}".encode() * 20)
        r = run_archiver("--source", p, "--media-id", f"MID-W{i}", "--taken-at", "2026-09-28T10:00:00",
                         "--target", str(tgt), "--manifest", man)
        if "STORED" not in r.stdout:
            ok = False
            print(f"  M5 failed for {n!r}: {r.stdout.strip()[:100]} {r.stderr.strip()[:100]}")
    check("M5-weird-names", ok and len(rows(man)) == len(names), f"rows={len(rows(man))}")

    # M6: empty file
    tmp, src, tgt, man = make_env()
    e = write(src / "empty.jpg", b"")
    r = run_archiver("--source", e, "--media-id", "MID-0", "--taken-at", "2026-09-28T10:00:00",
                     "--target", str(tgt), "--manifest", man)
    check("M6-empty-stored", "STORED" in r.stdout, r.stdout.strip().splitlines()[:1])

    # M7: bad taken-at
    tmp, src, tgt, man = make_env()
    a = write(src / "a.jpg", b"A" * 10)
    r = run_archiver("--source", a, "--media-id", "MID-B", "--taken-at", "not-a-date",
                     "--target", str(tgt), "--manifest", man)
    check("M7-clean-error", r.returncode == 1 and "Traceback" not in r.stderr,
          f"exit={r.returncode} err={(r.stderr.strip().splitlines() or [''])[:1]}")
    check("M7-no-row", len(rows(man)) == 0)

    # M8: sidecar identical to media -> SIDECAR_FAIL, media kept
    tmp, src, tgt, man = make_env()
    m = write(src / "m.jpg", b"M" * 60)
    write(src / "m.jpg.json", b"M" * 60)
    r = run_archiver("--source", m, "--media-id", "MID-S", "--taken-at", "2026-09-28T10:00:00",
                     "--target", str(tgt), "--manifest", man)
    check("M8-sidecar-fail-media-kept", "SIDECAR_FAIL" in r.stdout, r.stdout.strip())
    rr = rows(man)
    check("M8-row-status", len(rr) == 1 and rr[0][3] == "sidecar_fail", str(rr))

    print(f"\n{len(PASS)}/{len(PASS) + len(FAIL)} adversarial checks passed")
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main())
