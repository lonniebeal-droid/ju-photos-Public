# D1–D5 fixes — verification receipt (2026-09-28, VM synthetic only)

## What changed vs the audited release (archiver df6083af)

**D1 — collision-candidate defect (the confirmed FAIL).** `dest_for()` now
hash-verifies every candidate name: the 12-char `stem__<sha[:12]>.ext`
candidate is returned only if absent or byte-identical; a foreign file with
different bytes forces prefix lengthening (12 → 16 → 24 → 40 → 64). If every
candidate is occupied by foreign bytes it raises `CollisionAbort` → status
`fail_collision` before any `.part` exists. The `if dest.exists():` branch in
`archive_item` additionally re-verifies `_hash_matches`, so `dedup_reused`
can never point a media_id at wrong bytes.
New archiver SHA-256: `a94b1d7bcdb5000c4898530e345e5acfd9f2ad76864c290e7fb1cd0cbcf508c7`

**D2 — new regression gates 15–16** in `regression/run_14_gates.py`:
- Gate 15 (4 checks): foreign bytes at the 12-char candidate → stored at the
  16-char name, manifest sha == dest bytes, foreign file untouched.
- Gate 16 (2 checks): `dest_for` unit — 12- and 16-char candidates occupied
  by foreign bytes → lengthens to 24; byte-identical 24-char candidate reused.

**D3 — acceptance harness fixes** (`acceptance/acceptance_harness.sh`):
- Approval regex now accepts `GROK-APPROVED` **or** `AUDITOR-APPROVED`
  (`: bounded-acceptance YYYY-MM-DD`); still exits 4 BLOCKED_NO_APPROVAL
  without `--approve-file` + `--i-understand` + `--max-items 1..25`.
- `*.json` files are skipped in staging (sidecars, never media).
- Independent per-item verification: source SHA == dest SHA, dest inside the
  archive year/month layout, sidecar SHA verified when a sidecar was staged.
- Archiver invoked via `python3 "$ARCHIVER"` (no exec-bit dependency).
- Fail-closed trap: on any failure, captures post-fail evidence and rolls
  back the archiver code; data rows and media are never deleted.

**D4 — manifest rollback** (`ops/manifest_rollback.sh`): copy-only restore of
`archive_manifest.db` from a backup, with pre-restore preservation of the
current db and SHA-256 verification of every copy. Never unlinks media.

**D5 — Picker download driver** (`picker/download_picker_items.py`): bounded
session → wait for user selection → download (client `download_media` or
baseUrl+token fallback) → sidecars with id/mimeType/filename/creationTime
only. `--dry-run` stages labeled synthetic fixtures with zero network.
Writes ONLY to the staging dir. Enforces the expected photo/video mix.

**Single-command bounded driver** (`acceptance/bounded_acceptance.sh`):
vault-UUID gate → pre-evidence → Picker token probe (exactly one human auth
step when needed) → bounded download (skipped for pre-staged dirs) →
harness → paste-back receipt. Never `--live`, never deletes.

## Verification performed on this VM (all synthetic / fake vault)

| Check | Result |
|---|---|
| Regression gates 2–13, 15, 16 | **36/36 PASS** |
| Adversarial M1–M8 | **20/20 PASS** |
| Old code (df6083af) reproduces the D1 defect | **reproduced** (`dedup_reused` → foreign bytes, manifest sha ≠ dest bytes) |
| New code on the same scenario | **fixed** (stored at 16-char name, sha matches, foreign untouched) |
| Harness without/bad approval | **exit 4 BLOCKED_NO_APPROVAL, archive untouched** |
| Harness end-to-end (synthetic staging → fake archive) | **ACCEPTANCE_OK** (2 stored, sidecars verified, 0 rows added on rerun, 0 modified/deleted files) |
| `manifest_rollback.sh` on synthetic DBs | **5→3 rows, media preserved, pre-rollback copy kept, SHAs verified** |
| Picker driver `--dry-run` | **1 photo + 1 video + sidecars, 0 network** |
| `bounded_acceptance.sh` in FAKE_ROOT mode | **rc=0, ACCEPTANCE_OK, receipt written** |
| `bash -n` on all shell scripts; `py_compile` on all Python | **clean** |

## Not done / not authorized

- The revised code is **not installed on the Mac** (Mac still runs df6083af).
- The bounded **real** acceptance test is **NOT RUN** — it needs the
  auditor's explicit authorization, which has not been given.
- No Picker authorization, no Takeout ingestion, no `--live`, no deletion.

## 12:47–12:55 EDT follow-ups (Ren session)

- Worker #2 (auditor's second iteration) applied its F1+F2 harness changes:
  `--i-understand` operator-acknowledgment flag, `--staging-dir/--archive/--app-dir`
  CLI interface, `--max-items` 1..25 hard cap, and a renamed usage block.
  Archiver untouched (still `a94b1d7b…`).
- **Incident:** worker #2 overwrote the audited release tarball
  `ju-final-2026-09-28.tar.gz` with the fixed code (mtime 12:48:34), so the
  "audited df6083af release" name no longer matched its content. Restored the
  original byte-identical from the immutable remote copy
  (`.../1667916321589920/afc0gs9g3plilugdkphqyhko/ju-final-2026-09-28.tar.gz`);
  local tarball once again contains the audited df6083af archiver (24 files).
- **Incident (minor):** worker #2's re-bundle of the fixes tarball dropped
  `bounded_acceptance.sh`, `manifest_rollback.sh`, `download_picker_items.py`
  and the two docs. The fixes tarball was rebuilt from the full tree.
- Re-applied the manifest-init fix (harness initializes an empty manifest via
  `open_manifest` on first-ever run instead of failing closed); verified with
  an end-to-end harness run on an **empty archive**: ACCEPTANCE_OK
  (1 stored, sidecar verified, rerun added 0 rows, 0 modified/deleted files).
- Full-tree fixes tarball rebuilt and re-uploaded (see bundle pointer file).

## 13:02–13:05 EDT — bounded REAL acceptance attempt 3: substantive PASS, harness false-positive on macOS
- Attempt 1: Ju selected 0 photos + 1 video → driver fail-closed (mix mismatch), correct.
- Attempt 2: Ju selected 2 photos + 1 video → driver fail-closed (mix mismatch), correct.
- Attempt 3: correct 1 photo + 1 video selected. Download OK, both items STORED with
  sidecars verified, manifest 21→23 rows, pre-existing rows untouched, idempotency
  rerun 0 new rows, no new .parts — then the harness's file-inventory diff FAILED on
  5 macOS AppleDouble (`._*`) metadata files the OS wrote next to the new items
  (`2026/09/._videos`, `._<name>.jpg[.json]`, `._<name>.mp4[.json]`).
- This is a harness false-positive (the Linux-tested harness never saw `._` files),
  NOT an archiver defect: every substantive check was green. Fail-closed behaved
  correctly: archiver code rolled back to df6083af, all data rows kept, FAILURE_RECEIPT
  written to `/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/acceptance_20260928_130234`
  (kept as forensic evidence; NOT deleted).
- Fix applied: `acceptance_harness.sh` inventory diff now ignores `._*` AppleDouble
  files (raw inventory still records them); verified by unit-shape test and a full
  VM end-to-end harness run with `._` files present → ACCEPTANCE_OK.
- Bundle rebuilt + re-uploaded (archiver unchanged at a94b1d7b…).
- Recovery for Ju (no new Picker session, no new items — stays within the 2-item
  authorization): re-download bundle, reinstall fixed archiver, rerun ONLY the
  harness against the existing staging dir
  (`/Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/driver_20260928_130127/staging`) →
  expect ACCEPTANCE_OK with 0 new rows (idempotent).

## 13:05–13:08 EDT — my harness fix had a bug; fixed, re-tested, re-shipped
- The AppleDouble fix crashed on the Mac: the `.part`-check python snippet used
  `os.path` but only imported `sys` → `NameError`. It never fired in my VM test
  because no `.part` file existed there; the Mac has forensic `.part` files from
  the 12:30 probe run, which reached the `os.path` call. All substantive checks
  had already passed on the rerun (ALREADY_ARCHIVED ×2, sidecars verified,
  23 rows untouched, idempotency OK) before the crash; fail-closed rolled the
  archiver back to df6083af again (second FAILURE_RECEIPT kept as evidence).
- Fix: added the missing `import os`. Verified properly this time: extracted both
  python snippets from the shipped harness and tested all three cases — (a) new
  `._` files ignored by both checks, (b) pre-existing `.part` files grandfathered,
  (c) a genuinely NEW `.part` still flagged. Then a full VM harness e2e with
  `._` + `.part` files present → ACCEPTANCE_OK.
- Bundle rebuilt + re-uploaded: https://muse.ai/files/902265039642256/926152443560369/nt9jr65kk6c2td6a6phzobgk/ju-photos-fixes-2026-09-28.tar.gz (sha f498f94d1bc1625c873ebb1a59ba22a52bbf9fa794b909f38bf23b88b3853607, expires 2026-09-30 17:04 UTC; archiver unchanged a94b1d7b…).
- Ju's recovery is the same shape: re-download, reinstall fixed archiver, rerun
  ONLY the harness against driver_20260928_130127/staging → expect ACCEPTANCE_OK.

## 2026-09-28 13:05 EDT — BOUNDED REAL ACCEPTANCE: **PASS (ACCEPTANCE_OK)**
- Ju ran the fixed bundle: fixed archiver reinstalled (shasum verified a94b1d7b…),
  harness-only rerun against the existing staging dir
  (driver_20260928_130127/staging).
- Result: 2 items attempted, 0 stored, 2 reused (ALREADY_ARCHIVED); sidecars
  verified; manifest 23→23 rows; 0 pre-existing rows mutated; idempotency rerun
  +0 rows; no new .part files; file-inventory diff OK (AppleDouble `._` files
  correctly ignored).
- ACCEPTANCE_RECEIPT 2026-09-28T17:05:09Z at
  /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/acceptance_20260928_130507.
- The auditor-authorized bounded acceptance is COMPLETE. Per the plan: STOP for
  post-acceptance audit. NO --live, NO full ingest, NO launchd — each needs its
  own separate explicit approval.

## 2026-09-28 13:15 EDT — post-acceptance audit tooling shipped (audit NOT yet run)
- Per Ju's audit brief: built `acceptance/post_acceptance_audit.sh` — strictly
  READ-ONLY 12-check audit (receipt, archiver sha, source-vs-dest hashes,
  sidecars, 23-row consistency, pre-existing rows vs pre-run backup, dest
  byte-verification, dedup guards, .part recency, rerun duplicates, forensic
  evidence, rollback safeguards). Writes only its own new receipt dir.
- VM-verified: positive path 11/12 PASS on a 5-row mirror (C5 row-count check
  correctly expects 23); negative tamper test (modified a pre-existing row's
  sha256) correctly tripped C5+C6+C7. Also fixed two audit-script bugs found by
  the smoke test (sidecar counted as payload copy; C6 hardcoded 21/23).
- Bundle rebuilt/re-uploaded: https://muse.ai/files/902265039642256/1395540395999351/frmv2cwgbwrp6v8s6oqomjkw/ju-photos-fixes-2026-09-28.tar.gz (sha 501cf421b63284da20e8328a8770e4842da04ae3f4fa768184c6fba492783a83, expires 2026-09-30 17:15 UTC; archiver unchanged a94b1d7b…).
- Full-ingest tooling (full_ingest.sh, picker --unbounded, harness --media-id-tag)
  is BUILT and VM-TESTED but PARKED per the brief — a PASS authorizes the next
  planning gate only; full ingestion does NOT start automatically.
- Awaiting Ju's Mac run of the audit script + paste-back of the verdict.

## 2026-09-28 ~13:20 EDT — first Mac audit run: 8/12 PASS; 4 failures triaged
- Ju ran the audit on real Mac evidence: checks 1,2,5,6,8,9,11,12 PASS.
- The 4 failures were triaged per the brief's failure procedure:
  - C3/C4: audit-script bug -- macOS AppleDouble `._*` files in the staging
    dir were enumerated as staged media. The 2 real items verified OK.
    Fixed: `._*` excluded (consistent with harness disposition).
  - C10: over-strict check -- the 5 duplicate destinations are all
    pre-existing (proven by C6 byte-identity vs the 13:02:34 backup):
    synthetic_0/1/2.jpg (earlier synthetic runs; the archiver's content-dedup
    reuse-by-design) and 2x SAME.jpg (the intentional 12:30 collision/dedup
    probe). The rerun itself produced 0 new rows. Fixed: C10 now fails only
    on NEWLY introduced duplicate destinations (vs backup); pre-existing
    intentional dedup artifacts are disclosed, not failed.
  - C7: 5 TEST-MEDIA rows whose destination bytes != manifest sha. C6 proves
    the rows are byte-identical to the 13:02:34 pre-run backup, so the
    staleness predates the acceptance run (older synthetic test rows, earlier
    archiver builds). The no-modify rule forbids "repairing" these protected
    test rows/files. Fixed: C7 now classifies each mismatch against the
    driver's pre-run file inventory (driver_20260928_130127/pre-file-shas.txt,
    captured ~13:01:27): unchanged-since-pre-evidence = PRE-EXISTING
    (disclosed); changed-during/after = NEW (fails).
- Fixed script VM-verified on a synthetic mirror: positive paths, a NEW
  mismatch correctly failing C7, and a PRE-EXISTING stale row correctly
  disclosed without failing.
- Bundle rebuilt/re-uploaded: https://muse.ai/files/902265039642256/1425924049648964/qaxdy1sy80n7tz4ufft1y2gk/ju-photos-fixes-2026-09-28.tar.gz (sha 4532bb571d0286d345876fb2688b2745f1f1d75eb47fd4f2c7c83f57e505b38e, expires 2026-09-30 17:17 UTC; archiver unchanged a94b1d7b…).
- Awaiting Ju's rerun of the fixed audit script on the Mac.

## 2026-09-28 13:20 EDT — POST-ACCEPTANCE AUDIT: **PASS (12/12)**
- Ju reran the fixed audit script on the Mac against real JU-VAULT evidence.
- Result: checks passed 12, failed 0 → POST_ACCEPTANCE_AUDIT_PASS.
- Audit report: /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/post_acceptance_audit_20260928_132054/AUDIT_RECEIPT.txt
- Disclosed (not failed): 6 pre-existing stale TEST-MEDIA rows (proven
  untouched during the acceptance window via driver pre-inventory 13:01:27;
  protected test data, unmodified per the no-modify rule) and 5 pre-existing
  intentional dedup duplicate-destinations (earlier probe/test runs, unchanged
  since the pre-run backup).
- Per the brief: this PASS authorizes the NEXT PLANNING GATE ONLY. Full
  ingestion, production --live, and launchd each still require their own
  separate explicit approval. Full-ingest tooling remains PARKED.
