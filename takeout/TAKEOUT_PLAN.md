# Takeout import preparation (2026-09-28)

Status: DISCOVERY TOOLING READY. No Takeout data has been located, downloaded,
extracted, or ingested. Export expiration on record: **2026-10-01 00:37**.

## What we know
- 2026-09-28 Mac read-only search: NO Takeout zips/dirs found on JU-VAULT,
  `~/Downloads`, `~/Documents`, `~/JU_COMMAND_CENTER`.
- Recorded inventory (2026-09-26): 255 parts, ~12.3 TB total. Part 001 local
  copy NOT FOUND; 254 parts never downloaded.
- New uninspected lead: `~/organize_takeout.sh` on the Mac (found 2026-09-28,
  contents unknown to this lane).

## Discovery (safe now, read-only)
`./takeout_discover.sh [ROOT...] [--out DIR]` — finds takeout-like paths,
sizes, zip central-directory headers. Extracts nothing. Run it on the Mac
when the next Mac session opens; it cannot damage anything.

## Import mapping (for after Grok approves full ingest)
Takeout layout → archiver inputs:
- Media file (e.g. `IMG_001.jpg`, including Takeout's `(1)` dedup suffixes)
  → `--source <file>`
- Sibling `IMG_001.jpg.json` → auto-detected as sidecar (no flag needed);
  the archiver copies it to `<dest>.json` via `.json.part` + hash +
  no-overwrite, and records `sidecar_path` / `sidecar_sha256`.
- `--media-id`: derive deterministically, e.g. `takeout-<sha256-of-source>`
  or the Takeout filename stem. The archiver's content-hash dedup makes
  re-ingest safe; the media_id_conflict guard fails closed on anomalies.
- `--taken-at`: prefer the sidecar JSON's `photoTakenTime` timestamp;
  fall back to file mtime. Format: ISO-8601.
- Takeout album `.json` files (album metadata, no media sibling) are NOT
  media — skip them (no `--source`).

## Hard rules (unchanged)
- NEVER unzip Takeout over `GOOGLE_PHOTOS_ARCHIVE`.
- NEVER delete source Takeout data or Google Photos data.
- Full ingest begins ONLY after bounded acceptance passes AND Grok approves.
