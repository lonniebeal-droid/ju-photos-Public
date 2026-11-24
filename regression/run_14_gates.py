#!/usr/bin/env python3
"""
run_14_gates.py -- auditor-specified synthetic regression (round 2).

Usage: run_14_gates.py <ARCHIVE>
  ARCHIVE=/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE on the Mac.

Media is quarantined under <ARCHIVE>/collision_probe/ (via --target);
synthetic sources live in <ARCHIVE>/regression/. The REAL manifest at
<ARCHIVE>/archive_manifest.db is used (gates 2/5/6/13 require it) but only
ever appended to / additively migrated -- evidence rows are never modified
or deleted, and their sha256 values are never rewritten.

Gates:
  2  evidence intact: COUNT(*) >= 9
  3  collision: SAME.jpg twice (A then B) -> 2 dest files; first sha still A
  4  no overwrite: B lands at SAME__<12hex>.jpg; A unchanged
  5  sha256 skip: same bytes, new media_id -> 0 new dest files, +1 row
  6  same media_id rerun -> 0 new rows, 0 bytes, 0 mtime change
  7  JSON sidecar: pic.jpg + pic.jpg.json land; sidecar sha recorded, != media
  8  JSON-less photo -> succeeds, NO_SIDECAR
  9  tiny MP4 -> dest exists, sha matches, media_type=video
 10  hash fail: corrupt .part -> dest absent/unchanged, no row, .part REMAINS
 11  replace guard: dest exists w/ different hash -> no os.replace, .part kept
 12  ExFAT 4GiB gate: unit test (no 4GiB file written)
 13  overwrite_evidence: dup-dest rows labeled; sha256 values NOT rewritten
 15  D1: foreign bytes at the 12-char collision candidate -> prefix lengthens
      to 16 chars; manifest sha matches destination bytes; foreign file intact
 16  D1: dest_for unit -- 12- and 16-char candidates occupied -> returns the
      24-char name; writing identical bytes there -> reuse-identical
(Gate 1 = vault UUID, gate 14 = evidence shasum diff: both in mac_gate.sh.)

Exit 0 iff all checks pass (36 checks across gates 2-13, 15, 16; gates 1 and
14 are reported by the wrapper).
"""

import os
import hashlib
import sqlite3
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from ju_photos_archiver import (  # noqa: E402
    archive_item,
    dest_for,
    exfat_size_gate,
    sha256_file,
    verify_and_place,
    CollisionAbort,
    ExfatLimit,
    HashFail,
)

GATES = []


def gate(name, cond, detail=""):
    GATES.append(bool(cond))
    print(f"[{'PASS' if cond else 'FAIL'}] gate {name}"
          + (f" -- {detail}" if detail else ""), flush=True)


def write(p, payload: bytes):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(payload)
    return p


def rows(db):
    con = sqlite3.connect(str(db))
    try:
        return con.execute(
            "SELECT media_id, filename, sha256, destination, archived_at,"
            " source_path, taken_at, sidecar_path, sidecar_sha256,"
            " size_bytes, media_type, status FROM archived_media"
            " ORDER BY media_id").fetchall()
    finally:
        con.close()


def count_files(root):
    return sum(1 for _p in Path(root).rglob("*")
               if _p.is_file() and not _p.name.endswith(".part")
               and _p.name != "archive_manifest.db")


def main():
    archive = Path(sys.argv[1])
    db = archive / "archive_manifest.db"
    reg = archive / "regression"
    reg.mkdir(parents=True, exist_ok=True)
    TAKEN = "2026-09-28T12:00:00"  # -> 2026/09
    import os as _os, datetime as _dt
    TAG = _os.environ.get("GATE_RUN_TAG") or _dt.datetime.now().strftime("%Y%m%d%H%M%S%f")
    def mid(base):
        return f"{base}-{TAG}"
    print(f"gate run tag: {TAG}", flush=True)
    # per-run quarantine: never reuse (or delete) a previous run's probe dir
    probe = archive / "collision_probe" / TAG
    probe.mkdir(parents=True, exist_ok=True)

    def run(source, media_id, taken_at=TAKEN, sidecar=None):
        return archive_item(str(source), media_id, taken_at, str(probe),
                            str(db), sidecar=sidecar)

    # ---- gate 2: evidence intact
    n0 = len(rows(db))
    gate("2-evidence-intact", n0 >= 9, f"{n0} rows")

    # ---- gates 3+4: SAME.jpg collision regression
    A = f"PAYLOAD-A-{TAG}-".encode() * 100
    B = f"PAYLOAD-B-{TAG}-".encode() * 200
    assert A != B
    same = write(reg / "SAME.jpg", A)
    rA = run(same, mid("GATE3-A"))
    hA = sha256_file(rA["destination"])
    destA = Path(rA["destination"])
    mtimeA = destA.stat().st_mtime_ns
    same.write_bytes(B)
    rB = run(same, mid("GATE3-B"))
    destB = Path(rB["destination"])
    expB = destA.parent / f"SAME__{sha256_file(same)[:12]}.jpg"
    gate("3-two-dest-files",
         rA["status"] == "stored" and rB["status"] == "stored"
         and destA != destB and destA.is_file() and destB.is_file(),
         f"{destA.name} vs {destB.name}")
    gate("3-first-sha-still-A", sha256_file(destA) == hA, hA[:12])
    gate("4-hashed-name", destB == expB, destB.name)
    gate("4-A-unchanged",
         sha256_file(destA) == hA and destA.stat().st_mtime_ns == mtimeA)

    # ---- gate 5: sha256 skip -- same bytes, new media_id
    files_before = count_files(probe)
    rows_before = len(rows(db))
    same.write_bytes(A)  # same bytes as payload A, but a NEW media_id
    rC = run(same, mid("GATE5-C"))
    rC_row = [r for r in rows(db) if r[0] == mid("GATE5-C")]
    gate("5-zero-new-files", count_files(probe) == files_before,
         f"{files_before} -> {count_files(probe)}")
    gate("5-plus-one-row", len(rows(db)) == rows_before + 1,
         f"{rows_before} -> {len(rows(db))}")
    gate("5-row-points-at-existing",
         rC["status"] == "dedup_reused" and rC_row
         and rC_row[0][3] == str(destA),
         rC["status"])

    # ---- gate 6: same media_id rerun -> zero mutation
    rows_g6 = rows(db)
    st_before = (destA.stat().st_size, destA.stat().st_mtime_ns,
                 sha256_file(destA))
    rA2 = run(same, mid("GATE3-A"))
    st_after = (destA.stat().st_size, destA.stat().st_mtime_ns,
                sha256_file(destA))
    gate("6-zero-new-rows", rows(db) == rows_g6)
    gate("6-zero-byte-mtime-change",
         st_before == st_after and rA2["status"] == "already_archived",
         rA2["status"])

    # ---- gate 7: JSON sidecar
    P = f"PIC-{TAG}-".encode() * 100
    J = f'{{"title": "pic", "n": 7, "tag": "{TAG}"}}'.encode()
    pic = write(reg / "pic.jpg", P)
    write(reg / "pic.jpg.json", J)  # sibling auto-detect
    rP = run(pic, mid("GATE7-P"))
    rowP = [r for r in rows(db) if r[0] == mid("GATE7-P")][0]
    exp_json = str(Path(rP["destination"]).parent /
                   (Path(rP["destination"]).name + ".json"))
    gate("7-media-lands", Path(rP["destination"]).is_file())
    gate("7-sidecar-lands", Path(exp_json).is_file(), exp_json)
    gate("7-sidecar-recorded",
         rowP[7] == exp_json and rowP[8] == sha256_file(reg / "pic.jpg.json")
         and rowP[8] != rowP[2],
         f"sidecar_sha={rowP[8][:12]} media_sha={rowP[2][:12]}")

    # ---- gate 8: JSON-less photo
    nl = write(reg / "nopic.jpg", f"NOPIC-{TAG}-".encode() * 100)
    rN = run(nl, mid("GATE8-N"))
    gate("8-succeeds-no-sidecar",
         rN["status"] == "stored" and rN["sidecar_status"] == "NO_SIDECAR",
         f"{rN['status']} {rN['sidecar_status']}")

    # ---- gate 9: tiny MP4
    V = f"VID-{TAG}-".encode() * 100
    clip = write(reg / "clip.mp4", V)
    rV = run(clip, mid("GATE9-V"))
    rowV = [r for r in rows(db) if r[0] == mid("GATE9-V")][0]
    gate("9-video-dest-sha",
         Path(rV["destination"]).is_file()
         and sha256_file(rV["destination"]) == sha256_file(clip))
    gate("9-media-type-video", rowV[10] == "video", str(rowV[10]))
    gate("9-size-recorded", rowV[9] == len(V), str(rowV[9]))

    # ---- gate 10: hash fail -- corrupt .part, real code path
    d10 = probe / "2026" / "09" / "photos"
    d10.mkdir(parents=True, exist_ok=True)
    dest10 = d10 / "gate10.jpg"
    part10 = dest10.with_name(dest10.name + ".part")
    write(part10, b"GARBAGE-NOT-THE-SOURCE")
    rows_10 = len(rows(db))
    try:
        verify_and_place(part10, "0" * 64, dest10)
        gate("10-hash-fail-raises", False, "no exception")
    except HashFail as e:
        gate("10-hash-fail-raises", True, str(e)[:70])
    gate("10-part-remains", part10.is_file())
    gate("10-no-dest-no-row",
         not dest10.exists() and len(rows(db)) == rows_10)
    # KEEP part10: intentional failure artifact, never deleted.

    # ---- gate 11: replace guard -- dest exists with different hash
    dest11 = d10 / "gate11.jpg"
    write(dest11, b"EXISTING-X" * 50)
    hX = sha256_file(dest11)
    part11 = dest11.with_name(dest11.name + ".part")
    write(part11, b"NEWER-Y" * 50)
    try:
        verify_and_place(part11, sha256_file(part11), dest11)
        gate("11-replace-refused", False, "no exception")
    except CollisionAbort as e:
        gate("11-replace-refused", True, str(e)[:70])
    gate("11-part-kept", part11.is_file())
    gate("11-dest-untouched", sha256_file(dest11) == hX)
    # KEEP part11 + dest11: intentional failure artifacts, never deleted.

    # ---- gate 12: ExFAT 4GiB unit test (no 4GiB file written)
    try:
        exfat_size_gate(4294967295)
        gate("12-over-limit-raises", False, "no exception")
    except ExfatLimit:
        gate("12-over-limit-raises", True)
    gate("12-at-limit-ok", exfat_size_gate(4294967294) is True)
    gate("12-normal-ok", exfat_size_gate(10) is True)

    # ---- gate 13: overwrite_evidence labeling; sha256 never rewritten.
    # Scoped to the PRE-MIGRATION evidence rows: gate 5 legitimately creates
    # new rows that share a destination via dedup, so the check must not
    # demand labeling of those.
    pre = {}
    pre_path = Path("/tmp/evidence_sha_pre.txt")
    if pre_path.is_file():
        for line in pre_path.read_text().splitlines():
            parts = line.split("|", 3)
            mid, sha, dest = parts[0], parts[1], parts[2]
            status = parts[3] if len(parts) > 3 else ""
            pre[mid] = (sha, dest, status)
    cur = {r[0]: r for r in rows(db)}
    dest_groups = {}
    for mid, (_sha, dest, _st) in pre.items():
        dest_groups.setdefault(dest, []).append(mid)
    hashes_ok = all(mid in cur and cur[mid][2] == sha
                    for mid, (sha, _d, _s) in pre.items())
    gate("13-hashes-not-rewritten", hashes_ok,
         f"{len(pre)} pre-existing rows checked")
    # legacy rows = unlabeled at snapshot time sharing a destination:
    # migration must have labeled them overwrite_evidence.
    legacy_dup = [mid for mid, (_sha, dest, st) in pre.items()
                  if len(dest_groups[dest]) > 1 and not st and mid in cur]
    legacy_ok = all(cur[mid][11] == "overwrite_evidence" for mid in legacy_dup)
    # previously-labeled evidence rows must still carry the label.
    still_labeled = all(cur[mid][11] == "overwrite_evidence"
                        for mid, (_sha, _d, st) in pre.items()
                        if st == "overwrite_evidence" and mid in cur)
    n_ev = sum(1 for mid in pre if mid in cur
               and cur[mid][11] == "overwrite_evidence")
    gate("13-dup-dests-labeled",
         legacy_ok and still_labeled and n_ev > 0,
         f"legacy_dup={len(legacy_dup)} evidence_labeled={n_ev}")
    con = sqlite3.connect(str(db))
    cols = [c[1] for c in con.execute("PRAGMA table_info(archived_media)")]
    idx = [i[0] for i in con.execute(
        "SELECT name FROM sqlite_master WHERE type='index'")]
    con.close()
    gate("13-schema-columns",
         all(c in cols for c in ("source_path", "taken_at", "sidecar_path",
                                 "sidecar_sha256", "size_bytes",
                                 "media_type", "status")),
         ",".join(sorted(set(cols))))
    gate("13-sha-index", "idx_archived_sha256" in idx, ",".join(idx))

    # ---- gate 15: D1 -- foreign bytes occupy the 12-char candidate name.
    # Old code returned dest whose bytes would be verified only at the
    # primary; the 12-char candidate was assumed identical. New code must
    # lengthen the prefix and record the correct sha256.
    # (midx: gate 13's snapshot loop reuses the name `mid` for a string;
    # this local helper keeps a callable media-id builder for gates 15/16.)
    midx = lambda b: f"{b}-{TAG}"
    FA = f"FBC-A-{TAG}-".encode() * 100
    FB = f"FBC-B-{TAG}-".encode() * 200
    FC = f"FBC-FOREIGN-{TAG}-".encode() * 150
    assert len({FA, FB, FC}) == 3
    fbc = write(reg / "FBC.jpg", FA)
    r15a = run(fbc, midx("GATE15-A"))
    assert r15a["status"] == "stored", r15a
    d15 = Path(r15a["destination"]).parent
    fbc.write_bytes(FB)
    shaB = sha256_file(fbc)
    foreign = write(d15 / f"FBC__{shaB[:12]}.jpg", FC)
    shaC = sha256_file(foreign)
    r15b = run(fbc, midx("GATE15-B"))
    dest15b = Path(r15b["destination"])
    row15b = [r for r in rows(db) if r[0] == midx("GATE15-B")]
    gate("15-foreign-candidate-skipped",
         r15b["status"] == "stored" and sha256_file(dest15b) == shaB,
         f"{r15b['status']} {dest15b.name}")
    gate("15-16char-name", dest15b.name == f"FBC__{shaB[:16]}.jpg",
         dest15b.name)
    gate("15-row-sha-matches-dest",
         bool(row15b) and row15b[0][2] == shaB == sha256_file(dest15b))
    gate("15-foreign-file-untouched", sha256_file(foreign) == shaC,
         shaC[:12])
    # KEEP the foreign file + gate15 dests: collision-forensics artifacts.

    # ---- gate 16: D1 -- dest_for unit: prefix lengthening, reuse-identical
    u16 = probe / "unit16"
    P16 = f"P16-PAYLOAD-{TAG}-".encode() * 120
    H16 = hashlib.sha256(P16).hexdigest()  # "fake" sha: real 64-hex of P16
    write(u16 / "U.jpg", b"OTHER-BYTES-" + TAG.encode())
    write(u16 / f"U__{H16[:12]}.jpg", b"FOREIGN-12-" + TAG.encode())
    write(u16 / f"U__{H16[:16]}.jpg", b"FOREIGN-16-" + TAG.encode())
    d16a = dest_for(u16, "U.jpg", H16)
    gate("16-lengthens-to-24", d16a.name == f"U__{H16[:24]}.jpg", d16a.name)
    write(d16a, P16)  # the 24-char candidate now holds identical bytes
    d16b = dest_for(u16, "U.jpg", H16)
    gate("16-reuse-identical", d16b == d16a, d16b.name)

    n = len(GATES)
    passed = sum(GATES)
    print(f"\n{passed}/{n} regression gates passed (2-13,15,16)")
    return 0 if passed == n else 1


if __name__ == "__main__":
    sys.exit(main())
