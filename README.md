# JU Google Photos archiver — production package (2026-09-28, auditor revision)

Collision-safe archive store for JU-VAULT, implementing the auditor's
round-2 spec plus builder-found hardening plus the independent auditor's
D1-D5 fixes (see CHANGES below). Auditor: Ren (independent, 2026-09-28).

## Layout
- `ju_photos_archiver.py` — the archiver (stdlib only). CLI contract:
  `--source --media-id --taken-at [--target] [--manifest] [--sidecar] [--migrate]`
- `run_archive_batch.sh` — wrapper. Default dry-run (read-only).
  `--live` exits 3 `BLOCKED_AUDITOR`. No delete, no Picker, no launchd.
- `regression/` — `run_14_gates.py` (gates 2–13, 15, 16), `mac_gate.sh`
  (gates 1+14, backup-and-swap install, paste-back packet),
  `test_adversarial.py` (M1–M8), `mac_code_gate.sh` (auditor-authorized Mac
  code-only gate: code-only install, full regression rerun, evidence SHA
  verification, UUID confirm, read-only Takeout discovery, paste-back receipt).
- `ops/` — `backup_and_swap.sh`, `rollback.sh` (archiver CODE rollback),
  `manifest_rollback.sh` (MANIFEST DATABASE rollback, copy-only),
  `evidence_capture.sh` (read-only pre/post snapshots).
- `acceptance/` — `bounded_acceptance.sh` (single-command driver: UUID gate,
  pre-evidence, Picker auth probe, bounded download, harness, receipt);
  `acceptance_harness.sh` (GATED: refuses without a
  `(GROK-APPROVED|AUDITOR-APPROVED): bounded-acceptance YYYY-MM-DD` file +
  `--i-understand` + `--max-items 1..25`; per-item independent SHA/layout
  verification, sidecar verification, stray-.part sweep, file-inventory diff,
  idempotency rerun, fail-closed trap; NOT RUN until the auditor approves);
  `BOUNDED_ACCEPTANCE_PLAN.md` (single-command flow first).
- `takeout/` — `takeout_discover.sh` (read-only; extracts nothing),
  `TAKEOUT_PLAN.md` (import mapping; nothing ingested).
- `picker/` — `PICKER_AUTH_WORKFLOW.md` (prep only; NOT authorized),
  `download_picker_items.py` (bounded Picker download driver: 1 photo +
  1 video, metadata sidecars, mix verification; `--dry-run` = zero network).

## Guarantees
- SHA-256 before destination; content-hash dedup independent of media_id.
- Never overwrites different bytes: `stem__<sha[:12]>.ext`, lengthening
  (12 -> 16 -> 24 -> 40 -> 64) when a candidate name is occupied by foreign
  bytes; fail-closed FAIL_COLLISION when every candidate is occupied.
- `.part` files kept on HASH_FAIL / FAIL_COLLISION; no row on failure.
- Additive schema migration; `overwrite_evidence` labeling; sha256 never rewritten.
- media_id collision (same id, different bytes) → `MEDIA_ID_CONFLICT`, fail-closed.
- Evidence rows (`overwrite_evidence`) are never auto-repaired (`EVIDENCE_LOCKED`).
- ExFAT 4 GiB gate. JSON sidecars preserved + hashed. Videos routed to `videos/`.
- Manifest database rollback: `ops/manifest_rollback.sh` (copy-only; current
  manifest preserved before restore; byte-identity verified).

## CHANGES vs the 11:35 EDT Mac-verified round-2 build
1. FIX: same `media_id` + different bytes previously wrote an orphan dest file
   then died with an uncaught `sqlite3.IntegrityError`. Now fails closed
   BEFORE any write: status `media_id_conflict`, exit 1, no row, no dest.
2. FIX: same `media_id` + same sha + dead destination now repairs via row
   UPDATE (`reassociated`, 0 new files, or re-copy + UPDATE); evidence rows
   refuse (`evidence_locked`).
3. HARDEN: `dest_for` treats an unhashable primary (e.g. a directory) as a
   collision → hashed name, no traceback.
4. NEW: `regression/test_adversarial.py` — 20/20 PASS (synthetic, temp dirs).
5. NEW: `ops/` + `acceptance/` + `takeout/` + `picker/` tooling (all gated or
   read-only; acceptance harness NOT run).
6. Round-2 regression re-verified on fake vault: **30/30 PASS** after the fix.

## CHANGES in the auditor's D1-D5 revision (2026-09-28)
D1. FIX (confirmed defect): a foreign file at a 12-char collision-candidate
   name caused `dedup_reused` to point a new media_id at wrong bytes.
   `dest_for` now lengthens the hash prefix (12->16->24->40->64) and verifies
   every candidate's bytes; exhausted candidates raise `CollisionAbort` ->
   `fail_collision` with no .part and nothing copied. New regression gates
   15 (foreign-candidate clash, 4 checks) and 16 (dest_for unit, 2 checks).
D2. NEW: `ops/manifest_rollback.sh` — database-state rollback, copy-only.
D3. The acceptance approval regex now accepts `AUDITOR-APPROVED:` (Grok is
   unavailable; the independent auditor authorizes). Plan/docs updated.
D4. Harness: `*.json` staging files are skipped (sidecars auto-detected);
   `taken` prefers sidecar metadata (creationTime/photoTakenTime); per-item
   independent verification (source SHA == dest SHA, layout, sidecar SHA);
   stray `.part` sweep; pre/post file-inventory diff (0 modified, 0 deleted,
   only expected new dests/sidecars).
D5. NEW: `picker/download_picker_items.py` — bounded Picker download driver.
NEW: `acceptance/bounded_acceptance.sh` — single-command bounded driver.

## Validation receipts (this lane, synthetic only)
- `regression/run_14_gates.py`: 36/36 (gates 2-13, 15, 16)
- `regression/mac_code_gate.sh`: end-to-end fake-root rehearsal PASS — backup
  preserved, install byte-identical, manifest untouched by install, gates 36/36,
  adversarial 20/20, 15/15 pre-existing rows byte-identical, evidence files
  byte-identical, read-only Takeout discovery, complete receipt printed
  (known-good SHA anchor FAILs only on fake VM bytes, as designed)
- `regression/test_adversarial.py`: 20/20
- `run_archive_batch.sh`: dry-run OK (read-only), `--live` → exit 3
- `ops/backup_and_swap.sh` + `ops/rollback.sh`: byte-identical round-trip on
  simulated Mac layout
- `ops/evidence_capture.sh`: OK (read-only)
- `ops/manifest_rollback.sh`: fixture round-trip OK (byte-identical restore,
  current preserved)
- `acceptance/acceptance_harness.sh`: refusal gates → exit 4, 0 touched;
  empty staging dir → safe refusal (no files, exit 1 -> fail-closed trap)
- `acceptance/bounded_acceptance.sh`: FAKE_ROOT end-to-end PASS with pre-staged
  synthetic dir (full flow: UUID skip, pre-evidence, auth instruction + probe
  skip, download skip, harness archive + verify + rerun + receipt)
- `picker/download_picker_items.py`: --help OK; --dry-run OK (synthetic mix
  1/1 staged, 0 network)
- `takeout/takeout_discover.sh`: finds + sizes + zip headers on fixtures,
  0 extracted

## What is NOT done (gates, not code)
- Auditor re-audit verdict on this revised source: PENDING.
- Bounded real acceptance: NOT RUN (needs auditor approval + Ju's Picker step).
- Full ingest: NOT STARTED. Takeout: NOT LOCATED/INGESTED. Nothing deleted.
