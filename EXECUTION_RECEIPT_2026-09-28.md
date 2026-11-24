# EXECUTION RECEIPT — 2026-09-28 ~11:36–11:45 EDT (VM lane, $0)

Directive: complete the original Google Photos archive project; continue all
non-human work while Grok audits. Hard stops honored throughout: NO real
Google Photos media, NO Picker authorization, NO Takeout ingestion,
NO deletion, NO evidence cleanup, NO full/live run.

## 1. Defect hunt (synthetic, temp dirs) — FOUND 2 REAL DEFECTS
Wrote `regression/test_adversarial.py` (M1–M8), ran against the Mac-verified
round-2 source:
- DEFECT A (confirmed): same `media_id` + different bytes → the archiver
  COPIED the file to a dest, then died with uncaught
  `sqlite3.IntegrityError: UNIQUE constraint failed: archived_media.media_id`
  (raw traceback, exit 1) — leaving an ORPHAN dest file with no manifest row.
- DEFECT B (confirmed): `dest_for` with a DIRECTORY at the primary path →
  uncaught `IsADirectoryError` (raw traceback).

## 2. Fixes applied to `ju_photos_archiver.py`
- media_id guard block placed BEFORE any file write:
  - same id + different sha → `MEDIA_ID_CONFLICT`, exit 1, no row, no dest.
  - same id + same sha + dead dest + `overwrite_evidence` → `EVIDENCE_LOCKED`.
  - same id + same sha + dead dest (normal row) → repair: re-point at a
    validated blob (`reassociated`, 0 new files) or re-copy + row UPDATE;
    recorded sidecar columns preserved when the run supplies none.
- `dest_for`: unhashable primary (OSError) → treated as collision → hashed name.
- `record_row()` replaces `insert_row()`: INSERT for new media_id, UPDATE for
  repair. Exit 0 now includes `reassociated`.
- Module docstring updated with the new statuses and guard semantics.

## 3. Re-verification (all synthetic)
- `test_adversarial.py`: **20/20 PASS** (M1 conflict fail-closed, M2 repair,
  M3 evidence locked, M4 dir-collision, M5 weird names, M6 empty file,
  M7 bad taken-at, M8 sidecar==media).
- `run_14_gates.py` on fresh fake vault (9/9/3 evidence mirror, snapshot →
  migrate → gates, mirroring mac_gate.sh): **30/30 PASS**.
- `run_archive_batch.sh`: dry-run OK (read-only, 15/14/8 fake manifest);
  `--live` → exit 3 BLOCKED_AUDITOR; bad arg → exit 2.
- `ops/backup_and_swap.sh` + `ops/rollback.sh` on simulated Mac layout:
  backup byte-identical to original; post-rollback installed file
  byte-identical to pre-patch original (sha256 verified both directions).
- `ops/evidence_capture.sh` on fake vault: OK, read-only (counts, row dump,
  per-file SHAs, manifest SHA).
- `acceptance/acceptance_harness.sh`: all 4 refusal gates → exit 4
  BLOCKED_NO_APPROVAL, zero filesystem touches. Harness NOT run beyond gates.
- `takeout/takeout_discover.sh` on synthetic fixtures: found dir + zip,
  sizes, zip central-directory headers; 0 files extracted (verified).

## 4. Built (not run where gated)
- `final-2026-09-28/`: production package — patched archiver, wrapper,
  regression (14 gates + adversarial), ops (backup/rollback/evidence),
  acceptance (GATED harness + exact plan), takeout (read-only discovery +
  import mapping), picker (auth workflow prep, NOT authorized), README.
- `D3` deviation note in round-2 README corrected to the implemented behavior.

## 5. State preserved
- All 9 TEST-MEDIA evidence rows + 3 surviving files untouched (this lane
  never opened the real vault or manifest; all tests used temp dirs).
- No Picker token minted. No Takeout touched. Nothing deleted. $0.

## 6. Pending gates (not code)
- Grok re-audit of the REVISED source (this package supersedes the 11:35
  EDT relay for the archiver file; regression evidence from the Mac stands).
- Bounded real acceptance: needs Grok PASS + Ju's one Picker step.
- Full ingest: needs bounded pass + Grok progression approval.

## 7. 2026-09-28 ~12:15 EDT — Mac code-only gate prep (Grok-authorized real-data gate)
- Fixed three rerun-safety defects in `regression/run_14_gates.py` found by
  adversarial rerun testing (fixed media_ids + fixed payloads collided with
  prior runs; gate 13 over-asserted labeling on legitimate dedup rows):
  (1) run tags now microsecond-unique (`GATE_RUN_TAG` overridable);
  (2) per-run quarantine probe dir `collision_probe/<TAG>` (old runs kept);
  (3) tag-unique synthetic payloads so each run exercises the store path;
  (4) gate 13 is status-aware (4-field snapshot, back-compat): legacy
  unlabeled dup-dest rows must be labeled; previously-labeled rows must stay
  labeled; legitimate dedup-shared dests exempt.
- Fixed the known `.part` deletion contradiction: gates 10/11 no longer
  `unlink` the intentionally-kept `.part` artifacts (keep-.part failure
  semantics + NO-deletion rule honored).
- New `regression/mac_code_gate.sh`: single Mac script executing exactly
  Grok's 6 authorized code-only steps — vault UUID confirm, read-only
  evidence snapshot, code-only install (new timestamped backup; the
  11:35 `.bak-2026-09-28` preserved; installed sha must match bundle sha;
  manifest must be untouched by install), full regression (gates 2-13 +
  adversarial), evidence integrity (all pre-existing rows byte-identical;
  evidence files byte-identical; 3 TEST-MEDIA dests vs 11:35 known-good SHAs:
  6799cc4f…/42fb7705…/ac9bae77…), read-only Takeout discovery, paste-back
  receipt. Hard stops printed in the receipt; script never calls --live.
- VM validation: 3 rapid reruns on one fake vault = 30/30, 30/30, 30/30;
  adversarial 20/20; full `mac_code_gate.sh` fake-root rehearsal PASS
  (backup preserved, install byte-identical, 15/15 pre-existing rows
  byte-identical, evidence files byte-identical; known-good SHA anchor
  correctly FAILs on fake VM bytes — on the Mac the files carry the real
  11:35 bytes).
- Archiver source UNCHANGED: still
  `df6083af965d3e7c768f43549501a184ab9c2c89aba04faffcc22770aa0d0274`.
- NOTE (lane boundary): this VM cannot execute Mac-side steps (no Mac paired;
  outbound SSH runtime-blocked). `mac_code_gate.sh` is the single-command
  Mac execution; Ju pastes one command, pastes back the receipt.

## Files
- Package dir: `~/workspace/ju-photos-migration/final-2026-09-28/`
- Bundle: `ju-final-2026-09-28.tar.gz` (refreshed 12:16 EDT with the code-gate script + rerun-safety fixes). Live download URL is recorded in `~/workspace/ju-photos-migration/BUNDLE_URL_2026-09-28.txt` (expires 2026-09-30 ~16:16 UTC).
- Round-2 dir retains the fix + corrected D3 note.
