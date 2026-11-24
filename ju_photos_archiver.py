#!/usr/bin/env python3
"""
ju_photos_archiver.py -- collision-safe archive store (audit round 2, 2026-09-28).

Implements the auditor's patch spec verbatim (pathlib dest_for, HASH_FAIL /
FAIL_COLLISION / SIDECAR_FAIL / NO_SIDECAR / FAIL_EXFAT_4GiB semantics, exact
schema, evidence labeling). Written as a complete file because the original
source was never available to the builder; the Mac-side gate script applies
it via backup-and-swap (copy, never move/delete).

Destination rule (auditor spec, D1-hardened 2026-09-28):
    primary = dest_dir / source_name; absent -> use it;
    present + identical sha256 -> reuse (caller skips copy);
    present + different sha256 -> stem__<sha[:12]>.ext, BUT every candidate
    name is hash-verified: if the 12-char candidate exists with DIFFERENT
    bytes (foreign file), the prefix lengthens (12 -> 16 -> 24 -> 40 -> 64)
    until a free name or a byte-identical name is found. Never overwrites
    different bytes; if every candidate is occupied by foreign bytes,
    raises CollisionAbort -> status FAIL_COLLISION (no .part written).

Copy path per item:
    1. source_sha = sha256_file(source)
    2. a row already has that sha256 -> do not copy. media_id new -> INSERT
       pointing at the existing (validated) destination. media_id exists ->
       no-op (0 rows, 0 bytes).
    3. dest = dest_for(...); dest exists + same sha -> skip copy; INSERT the
       media_id only if new. (dest_for guarantees exists => identical.)
    4. else write dest.with_name(dest.name + ".part").
    5. hash the .part; mismatch -> HASH_FAIL, .part KEPT, no row.
    6. os.replace(part, dest) only if dest absent or same-sha; dest exists
       with different hash -> FAIL_COLLISION, .part kept, never overwrite.
    7. INSERT only after the dest hash matches source_sha.

Schema (additive only; duplicate-column errors ignored):
    source_path TEXT, taken_at TEXT, sidecar_path TEXT, sidecar_sha256 TEXT,
    size_bytes INTEGER, media_type TEXT, status TEXT
    + CREATE INDEX IF NOT EXISTS idx_archived_sha256 ON archived_media(sha256)
No UNIQUE(sha256). No UNIQUE(destination). media_id stays PRIMARY KEY.

Evidence labeling (never rewrites sha256):
    UPDATE archived_media SET status='overwrite_evidence'
    WHERE status IS NULL AND destination IN (
        SELECT destination FROM archived_media
        GROUP BY destination HAVING COUNT(*) > 1);

Sidecars: sibling <source>.json auto-detected (+ --sidecar override); copied
as <dest>.json via .json.part + hash + the same no-overwrite rule; sidecar
hash must differ from media hash; missing -> NO_SIDECAR (ok); copy/hash fail
-> SIDECAR_FAIL (media kept if verified).

ExFAT: size_bytes > 4294967294 -> FAIL_EXFAT_4GiB, no dest, no row.

Item statuses: stored | dedup_reused | already_archived | reassociated |
               hash_fail | fail_collision | sidecar_fail | fail_exfat_4gib |
               media_id_conflict | evidence_locked

media_id guards (fail-closed, before any file is written):
    same media_id + different sha256 -> MEDIA_ID_CONFLICT, no row, no dest.
    same media_id + same sha + dead destination ->
        overwrite_evidence rows: EVIDENCE_LOCKED (never auto-repaired);
        other rows: UPDATE destination to the validated blob (REASSOCIATED),
        or re-copy from source and UPDATE when no valid blob remains.
"""

import argparse
import hashlib
import os
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

EXFAT_MAX_BYTES = 4294967294  # 2**32 - 2
MANIFEST_NAME = "archive_manifest.db"
EXPECTED_VAULT_UUID = "20327ACF-C3E0-3E0E-A03B-03D10FD9438D"

VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm",
              ".3gp", ".3g2", ".mts", ".m2ts", ".flv", ".wmv"}

SCHEMA_ALTERATIONS = [
    "ALTER TABLE archived_media ADD COLUMN source_path TEXT",
    "ALTER TABLE archived_media ADD COLUMN taken_at TEXT",
    "ALTER TABLE archived_media ADD COLUMN sidecar_path TEXT",
    "ALTER TABLE archived_media ADD COLUMN sidecar_sha256 TEXT",
    "ALTER TABLE archived_media ADD COLUMN size_bytes INTEGER",
    "ALTER TABLE archived_media ADD COLUMN media_type TEXT",
    "ALTER TABLE archived_media ADD COLUMN status TEXT",
]
INDEX_SQL = ("CREATE INDEX IF NOT EXISTS idx_archived_sha256 "
             "ON archived_media(sha256)")
LABEL_SQL = (
    "UPDATE archived_media SET status='overwrite_evidence' "
    "WHERE status IS NULL AND destination IN ("
    "SELECT destination FROM archived_media "
    "GROUP BY destination HAVING COUNT(*) > 1)"
)


class ArchiveError(Exception):
    pass


class HashFail(ArchiveError):
    """Item status: HASH_FAIL -- .part kept, no row."""


class CollisionAbort(ArchiveError):
    """Item status: FAIL_COLLISION -- .part kept, never overwrite."""


class ExfatLimit(ArchiveError):
    """Item status: FAIL_EXFAT_4GiB."""


class SidecarFail(ArchiveError):
    """Item status: SIDECAR_FAIL -- media kept if verified."""


# ------------------------------------------------------------------ hashing

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _hash_matches(path, expected_sha):
    p = Path(path)
    try:
        return p.is_file() and sha256_file(p) == expected_sha
    except OSError:
        return False


# ------------------------------------------------------- destination rule

def dest_for(dest_dir, source_name, source_sha):
    """Auditor's destination rule with prefix-lengthening collision names.

    Never returns a path whose existing bytes differ from source_sha: the
    hash prefix lengthens (12 -> 16 -> 24 -> 40 -> 64) until the candidate is
    absent or byte-identical. Raises CollisionAbort when every candidate is
    occupied by foreign bytes. The first candidate keeps the original
    12-char naming contract (stem__<sha[:12]>.ext).
    """
    dest_dir = Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    primary = dest_dir / Path(source_name).name
    if not primary.exists():
        return primary
    try:
        existing = sha256_file(primary)
    except OSError:
        existing = None  # not a regular hashable file (e.g. a directory)
    if existing == source_sha:
        return primary  # identical bytes; caller must skip copy
    for n in (12, 16, 24, 40, 64):
        cand = dest_dir / f"{primary.stem}__{source_sha[:n]}{primary.suffix}"
        if not cand.exists():
            return cand
        try:
            csha = sha256_file(cand)
        except OSError:
            csha = None  # unhashable candidate; treat as occupied
        if csha == source_sha:
            return cand  # byte-identical candidate; caller skips copy
    raise CollisionAbort(f"no free collision-safe name for {primary}")


def exfat_size_gate(size_bytes):
    """Unit-testable ExFAT 4GiB gate. Raises ExfatLimit when over."""
    if size_bytes > EXFAT_MAX_BYTES:
        raise ExfatLimit(
            f"size {size_bytes} exceeds ExFAT single-file limit "
            f"{EXFAT_MAX_BYTES}")
    return True


# ---------------------------------------------------------------- manifest

def open_manifest(manifest_path):
    """Create if missing; additive migration; evidence labeling. Idempotent."""
    manifest_path = Path(manifest_path)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(manifest_path))
    conn.execute(
        "CREATE TABLE IF NOT EXISTS archived_media ("
        "media_id TEXT PRIMARY KEY, filename TEXT NOT NULL, "
        "sha256 TEXT NOT NULL, destination TEXT NOT NULL, "
        "archived_at TEXT NOT NULL)")
    added = []
    for sql in SCHEMA_ALTERATIONS:
        try:
            conn.execute(sql)
            added.append(sql)
        except sqlite3.OperationalError as e:
            if "duplicate column name" not in str(e).lower():
                raise
    conn.execute(INDEX_SQL)
    cur = conn.execute(LABEL_SQL)  # labels stale dup-dest rows; never rewrites sha256
    conn.commit()
    return conn, added, cur.rowcount


def find_valid_blob_for_sha(conn, source_sha):
    """
    Step 2 support: first row with this sha256 whose destination exists and
    verifies. (Builder note: validating avoids INSERTing new rows that point
    at the already-stale destinations; gate behavior unchanged.)
    """
    for (destination,) in conn.execute(
            "SELECT destination FROM archived_media WHERE sha256=? "
            "ORDER BY rowid", (source_sha,)):
        if destination and _hash_matches(destination, source_sha):
            return destination
    return None


# ------------------------------------------------------------- copy/place

def verify_and_place(part_path, expected_sha, dest):
    """
    Steps 5-6. part_path is a Path. Raises HashFail (part KEPT) or
    CollisionAbort (part KEPT). Returns 'placed' or 'reused-identical'.
    """
    part_path = Path(part_path)
    dest = Path(dest)
    actual = sha256_file(part_path)
    if actual != expected_sha:
        raise HashFail(
            f".part hash mismatch for {dest}: expected {expected_sha}, "
            f"got {actual}; .part kept at {part_path}")
    if dest.exists():
        if _hash_matches(dest, expected_sha):
            part_path.unlink(missing_ok=True)
            return "reused-identical"
        raise CollisionAbort(
            f"refusing os.replace over different bytes: {dest}; "
            f".part kept at {part_path}")
    os.replace(part_path, dest)
    return "placed"


def _media_type_for(source_name):
    return "video" if Path(source_name).suffix.lower() in VIDEO_EXTS else "photo"


def _parse_taken_at(value):
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        raise ArchiveError(f"unparseable --taken-at: {value!r}")
    return f"{dt.year:04d}", f"{dt.month:02d}"


# ---------------------------------------------------------------- sidecar

def _place_sidecar(conn, media_id, media_dest, sidecar_src, media_sha):
    """
    Copies sidecar_src -> <media_dest>.json via .json.part + hash + the same
    no-overwrite rule. Returns (sidecar_dest_str|None, sidecar_sha|None,
    sidecar_status). Raises SidecarFail on copy/hash problems.
    """
    media_dest = Path(media_dest)
    sc_sha = sha256_file(sidecar_src)
    if sc_sha == media_sha:
        raise SidecarFail("sidecar hash equals media hash -- refusing")
    sc_dest = media_dest.parent / (media_dest.name + ".json")
    if sc_dest.exists() and not _hash_matches(sc_dest, sc_sha):
        sc_dest = media_dest.parent / (
            f"{media_dest.stem}__{sc_sha[:12]}.json")
    if not _hash_matches(sc_dest, sc_sha):
        sc_part = sc_dest.with_name(sc_dest.name + ".part")
        shutil.copyfile(sidecar_src, sc_part)
        try:
            verify_and_place(sc_part, sc_sha, sc_dest)
        except (HashFail, CollisionAbort) as e:
            raise SidecarFail(f"sidecar not placed: {e}")
    return str(sc_dest), sc_sha, "SIDECAR_OK"


# -------------------------------------------------------------- main flow

def archive_item(source, media_id, taken_at, dest_root, manifest_path,
                 sidecar=None):
    """
    Archive one item per the auditor's copy path. Returns a dict:
      status, destination (str|None), sha256 (str|None),
      sidecar_status (SIDECAR_OK | NO_SIDECAR | SIDECAR_FAIL | None),
      detail
    Failed items leave no row; HASH_FAIL / FAIL_COLLISION keep the .part.
    """
    src = Path(source)
    if not media_id:
        raise ArchiveError("media_id is required")
    if not src.is_file():
        raise ArchiveError(f"source not found or not a file: {source}")
    year, month = _parse_taken_at(taken_at)

    size_bytes = src.stat().st_size
    try:
        exfat_size_gate(size_bytes)
    except ExfatLimit as e:
        return {"status": "fail_exfat_4gib", "destination": None,
                "sha256": None, "sidecar_status": None, "detail": str(e)}

    source_sha = sha256_file(src)                       # step 1
    media_type = _media_type_for(src.name)              # "video" | "photo"
    kind_dir = "videos" if media_type == "video" else "photos"
    filename = src.name
    dest_dir = Path(dest_root) / year / month / kind_dir

    # sidecar discovery: explicit --sidecar wins, else sibling <source>.json
    sc_src = Path(sidecar) if sidecar else None
    if sc_src is None:
        auto = src.with_name(src.name + ".json")
        sc_src = auto if auto.is_file() else None
    elif not sc_src.is_file():
        raise ArchiveError(f"sidecar not found: {sidecar}")

    conn, _added, _labeled = open_manifest(manifest_path)
    try:
        now = datetime.now(timezone.utc).isoformat()

        def record_row(dest_str, status, sc_path=None, sc_sha=None):
            """INSERT for a new media_id; UPDATE for a repair (same media_id,
            same sha, dead destination, non-evidence row). Repair preserves
            the recorded sidecar columns when this run supplies none."""
            if mode == "repair":
                if sc_path is None:
                    sc_path, sc_sha = row[3], row[4]
                conn.execute(
                    "UPDATE archived_media SET destination=?, archived_at=?, "
                    "source_path=?, taken_at=?, sidecar_path=?, "
                    "sidecar_sha256=?, size_bytes=?, media_type=?, status=? "
                    "WHERE media_id=?",
                    (dest_str, now, str(src), taken_at, sc_path, sc_sha,
                     size_bytes, media_type, status, media_id))
            else:
                conn.execute(
                    "INSERT INTO archived_media (media_id, filename, sha256, "
                    "destination, archived_at, source_path, taken_at, "
                    "sidecar_path, sidecar_sha256, size_bytes, media_type, status)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                    (media_id, filename, source_sha, dest_str, now, str(src),
                     taken_at, sc_path, sc_sha, size_bytes, media_type, status))
            conn.commit()

        # fast path: this exact media+bytes already recorded and valid
        row = conn.execute(
            "SELECT sha256, destination, status, sidecar_path, sidecar_sha256 "
            "FROM archived_media WHERE media_id=?",
            (media_id,)).fetchone()
        if row and row[0] == source_sha and _hash_matches(row[1], source_sha):
            return {"status": "already_archived", "destination": row[1],
                    "sha256": source_sha,
                    "sidecar_status": "NO_SIDECAR" if sc_src is None else None,
                    "detail": "media_id+sha256 already recorded, 0 rows, 0 bytes"}

        # media_id collision: same id, DIFFERENT bytes -> fail closed BEFORE
        # any file is written. (Without this guard the copy path wrote an
        # orphan dest file and then died on the PRIMARY KEY constraint.)
        if row and row[0] != source_sha:
            return {"status": "media_id_conflict", "destination": None,
                    "sha256": source_sha, "sidecar_status": None,
                    "detail": "FAIL_MEDIA_ID_CONFLICT: media_id already "
                    "recorded with different sha256; refusing; no row, no dest"}

        # same media_id + same sha, but the recorded destination is dead or
        # missing. Evidence rows are never auto-repaired.
        mode = "new"
        if row:
            if row[2] == "overwrite_evidence":
                return {"status": "evidence_locked", "destination": None,
                        "sha256": source_sha, "sidecar_status": None,
                        "detail": "EVIDENCE_LOCKED: recorded destination is "
                        "stale but the row is forensic evidence; refusing "
                        "auto-repair; no row, no dest"}
            mode = "repair"

        # step 2: content-hash dedup -- a row already has these bytes
        blob = find_valid_blob_for_sha(conn, source_sha)
        if blob:
            if mode == "repair":
                record_row(blob, "reassociated")
                return {"status": "reassociated", "destination": blob,
                        "sha256": source_sha, "sidecar_status": None,
                        "detail": "recorded destination was stale; row "
                        "re-pointed at validated blob; 0 new files"}
            sc_path = sc_sha = None
            sc_status = "NO_SIDECAR"
            if sc_src is not None:
                try:
                    sc_path, sc_sha, sc_status = _place_sidecar(
                        conn, media_id, blob, sc_src, source_sha)
                except SidecarFail as e:
                    sc_status = f"SIDECAR_FAIL: {e}"
            record_row(blob, "dedup_reused", sc_path, sc_sha)
            return {"status": "dedup_reused", "destination": blob,
                    "sha256": source_sha, "sidecar_status": sc_status,
                    "detail": "0 new dest files, +1 row"}

        # steps 3-4: dest_for raises CollisionAbort when every candidate is
        # occupied by foreign bytes -> fail closed before any .part exists.
        try:
            dest = dest_for(dest_dir, filename, source_sha)
        except CollisionAbort as e:
            return {"status": "fail_collision", "destination": None,
                    "sha256": source_sha, "sidecar_status": None,
                    "detail": f"FAIL_COLLISION: {e} (no .part, nothing copied)"}
        if dest.exists() and _hash_matches(dest, source_sha):
            # dest_for guarantees exists => byte-identical (or it raised);
            # re-verified here so identical bytes are never copied.
            # Fall-through (dest absent) goes to the .part path, which stays
            # fail-closed via verify_and_place.
            if mode == "repair":
                record_row(str(dest), "reassociated")
                return {"status": "reassociated", "destination": str(dest),
                        "sha256": source_sha, "sidecar_status": None,
                        "detail": "recorded destination was stale; row "
                        "re-pointed at identical bytes; 0 new files"}
            sc_path = sc_sha = None
            sc_status = "NO_SIDECAR"
            if sc_src is not None:
                try:
                    sc_path, sc_sha, sc_status = _place_sidecar(
                        conn, media_id, dest, sc_src, source_sha)
                except SidecarFail as e:
                    sc_status = f"SIDECAR_FAIL: {e}"
            record_row(str(dest), "dedup_reused", sc_path, sc_sha)
            return {"status": "dedup_reused", "destination": str(dest),
                    "sha256": source_sha, "sidecar_status": sc_status,
                    "detail": "identical bytes on disk, copy skipped"}

        part = dest.with_name(dest.name + ".part")
        shutil.copyfile(src, part)                      # step 4
        try:
            verify_and_place(part, source_sha, dest)    # steps 5-6
        except HashFail as e:
            return {"status": "hash_fail", "destination": None,
                    "sha256": source_sha, "sidecar_status": None,
                    "detail": f"HASH_FAIL: {e}"}
        except CollisionAbort as e:
            return {"status": "fail_collision", "destination": None,
                    "sha256": source_sha, "sidecar_status": None,
                    "detail": f"FAIL_COLLISION: {e}"}

        # step 7: INSERT only after the dest hash matches
        assert _hash_matches(dest, source_sha), "post-place verification failed"

        sc_path = sc_sha = None
        sc_status = "NO_SIDECAR"
        final_status = "stored"
        if sc_src is not None:
            try:
                sc_path, sc_sha, sc_status = _place_sidecar(
                    conn, media_id, dest, sc_src, source_sha)
            except SidecarFail as e:
                sc_status = f"SIDECAR_FAIL: {e}"
                final_status = "sidecar_fail"  # media kept, it verified
        record_row(str(dest), final_status, sc_path, sc_sha)
        detail = "stored" if final_status == "stored" else "media kept, sidecar failed"
        if mode == "repair" and final_status == "stored":
            detail = "stored (repair: re-copied after stale destination; row updated)"
        return {"status": final_status, "destination": str(dest),
                "sha256": source_sha, "sidecar_status": sc_status,
                "detail": detail}
    finally:
        conn.close()


# ------------------------------------------------------------------- CLI

def build_parser():
    p = argparse.ArgumentParser(
        description="Collision-safe Google Photos archive store "
                    "(audit round 2, 2026-09-28).")
    p.add_argument("--source", help="local file to archive")
    p.add_argument("--media-id", help="media identity")
    p.add_argument("--taken-at", help="ISO-8601 timestamp, routed to YYYY/MM")
    p.add_argument("--target",
                   default="/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE",
                   help="media destination root")
    p.add_argument("--manifest", default=None,
                   help="manifest path (default: <target>/archive_manifest.db)")
    p.add_argument("--sidecar", default=None,
                   help="explicit sidecar JSON (default: auto-detect <source>.json)")
    p.add_argument("--migrate", action="store_true",
                   help="run additive schema migration + evidence labeling and exit")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    manifest = args.manifest or str(Path(args.target) / MANIFEST_NAME)
    if args.migrate:
        _conn, added, labeled = open_manifest(manifest)
        _conn.close()
        print(f"MIGRATE_OK manifest={manifest} added_columns={len(added)} "
              f"labeled_overwrite_evidence={labeled}")
        return 0
    for req in ("source", "media_id", "taken_at"):
        if not getattr(args, req):
            print(f"ERROR: --{req.replace('_', '-')} is required",
                  file=sys.stderr)
            return 2
    try:
        r = archive_item(args.source, args.media_id, args.taken_at,
                         args.target, manifest, sidecar=args.sidecar)
    except ArchiveError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    print(f"{r['status'].upper()}: {r['destination'] or '-'} "
          f"sidecar={r['sidecar_status']}")
    if r["detail"]:
        print(f"  {r['detail']}")
    return 0 if r["status"] in (
        "stored", "dedup_reused", "already_archived",
        "reassociated") else 1


if __name__ == "__main__":
    sys.exit(main())
