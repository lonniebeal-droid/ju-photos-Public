# Bounded real acceptance — exact plan (2026-09-28, auditor revision)

Grok is unavailable. The INDEPENDENT AUDITOR (Ren) authorizes this flow.

PREREQUISITES (all must hold; the harness enforces them and refuses otherwise):
1. The auditor's verdict on the current patched source is PASS (or PASS with
   fixes incorporated and re-verified).
2. An approval file exists whose first line is exactly:
   `AUDITOR-APPROVED: bounded-acceptance YYYY-MM-DD`
   (the harness also accepts the legacy `GROK-APPROVED:` prefix).
3. Ju has completed the ONE Picker auth step (see `../picker/PICKER_AUTH_WORKFLOW.md`).
4. The bounded selection is 1 photo + 1 video (+ their JSON sidecars).

## Single command (Mac) — preferred

```bash
cd <this bundle dir>
./acceptance/bounded_acceptance.sh \
  --app-dir ~/JU_COMMAND_CENTER/google_photos_archiver \
  --approve-file /tmp/auditor_approval.txt \
  --max-items 2
```

The driver runs the whole flow in order and fails closed at any step:
1. Vault UUID gate: `diskutil info /Volumes/JU-VAULT` must report exactly
   `20327ACF-C3E0-3E0E-A03B-03D10FD9438D`, else exit 42.
2. Step-6 pre-evidence: UUID, manifest backup (`cp` to driver outdir),
   row counts, destination inventory, SHA-256 inventory, `df` free space,
   archiver sha256, rollback backup availability (`ls .bak-*`).
3. Picker auth probe (metadata-only session create). If no token and the
   setup script exists at `$APP_DIR/setup_google_photos_auth.py`, it runs it
   (Ju's ONE human step: browser approval + paste ONLY the
   `http://localhost:8765/...` URL at the prompt). If the setup script is
   absent, it prints the exact one-line instruction and waits for Ju's
   confirmation.
4. Bounded Picker download (`picker/download_picker_items.py`):
   1 photo + 1 video + `<file>.json` metadata sidecars into a staging dir.
   Skipped when `--staging-dir` points at a non-empty pre-staged dir.
5. `acceptance_harness.sh --max-items 2 --i-understand`:
   stages files (skipping `*.json`), takes `taken` from sidecar metadata when
   present, archives each, then independently verifies per item:
   source SHA == dest SHA, dest under `YYYY/MM/(photos|videos)/`, sidecar
   placed + SHA-verified; then pre-existing-row diff, idempotency rerun
   (0 new rows), no-NEW-`.part` check (pre/post inventory diff; pre-existing
   forensic `.parts` grandfathered, NO-deletion rule), file-inventory diff
   (0 modified, 0 deleted, only expected new dests/sidecars). Fail-closed trap on any error.
6. Final paste-back receipt (UUID, counts pre/post, archiver sha, receipt path).

## Manual equivalent (if the driver is unavailable)

```bash
# 0. Preflight: vault identity + archiver sanity (read-only)
diskutil info /Volumes/JU-VAULT | grep -E "Volume UUID|File System Personality"
python3 ~/JU_COMMAND_CENTER/google_photos_archiver/ju_photos_archiver.py --help

# 1. Stage real files (Picker downloads; operator copies them here)
mkdir -p /tmp/picker_staging && cp <downloaded files> /tmp/picker_staging/

# 2. Write the approval file (the auditor's verdict, dated)
echo "AUDITOR-APPROVED: bounded-acceptance 2026-09-28" > /tmp/auditor_approval.txt

# 3. Run the harness (refuses without approval; fail-closed on any error)
./acceptance/acceptance_harness.sh \
  --approve-file /tmp/auditor_approval.txt \
  --staging-dir /tmp/picker_staging \
  --archive /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE \
  --app-dir ~/JU_COMMAND_CENTER/google_photos_archiver \
  --max-items 2 --i-understand

# 4. Inspect the receipt
cat /Volumes/JU-VAULT/GOOGLE_PHOTOS_ARCHIVE/acceptance_*/ACCEPTANCE_RECEIPT.txt
```

## What the harness does (and proves)
- Pre/post evidence capture (manifest dump + SHA-256 of every file).
- Archives ≤25 real files via the patched archiver (media_id `ACCEPT-<date>-NNNN`).
- Per item: source SHA == destination SHA; destination layout correct;
  sidecar preserved + hash-verified.
- Verifies ZERO pre-existing rows mutated or deleted (byte-compare of dumps).
- Verifies ZERO pre-existing files modified or deleted; only expected new
  dests/sidecars; no NEW `.part` files (pre-existing forensic `.parts`
  grandfathered via the pre-run inventory; the NO-deletion rule forbids
  removing them).
- Reruns all items → expects `ALREADY_ARCHIVED`/`DEDUP_REUSED`, 0 new rows.
- On ANY failure: automatic archiver-code rollback, post-fail evidence kept,
  exit 5. Manifest rows from the run are NEVER auto-deleted (forensic);
  `ops/manifest_rollback.sh` restores database state from a backup if required.

## Artifacts produced
- `$ARCHIVE/acceptance_YYYYMMDD_HHMMSS/` — items.tsv, pre/post evidence,
  pre-manifest-backup.db, ACCEPTANCE_RECEIPT.txt (or FAILURE state).
- Paste `ACCEPTANCE_RECEIPT.txt` + the receipt dir listing back for the
  auditor's post-test audit.

## After bounded acceptance passes
Full-library ingestion begins ONLY with the auditor's explicit progression
approval (the post-acceptance audit). The same harness pattern scales: staged
batches, evidence per batch, rerun idempotency per batch. Takeout import
follows `../takeout/TAKEOUT_PLAN.md`. Original Takeout exports, if located
before expiry, are preserved untouched under `JU-VAULT/SOURCES/` — that is
preservation, not archive ingestion.
