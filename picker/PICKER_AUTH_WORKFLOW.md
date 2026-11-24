# Google Photos Picker authorization workflow (PREP ONLY — 2026-09-28)

Status: NOT AUTHORIZED. No token has ever been minted in this project
(all 2026-09-28 attempts ended `NO_AUTHORIZATION_CODE`; the probe returned
HTTP 401, proving no valid credential exists). NOTHING TO REVOKE.

This workflow is prepared so that, when Grok approves the bounded real
acceptance test AND Ju explicitly approves this human step, exactly one
concise instruction is needed. Until then: DO NOT RUN.

## The one instruction Ju will get (when the time comes)
> Run `python3 ~/JU_COMMAND_CENTER/google_photos_archiver/setup_google_photos_auth.py`,
> approve read-only Picker access in the browser, and paste ONLY the full
> `http://localhost:8765/...` URL at the `CALLBACK URL:` prompt.

## Verification after auth (read-only probe, zero downloads)
`python3 /tmp/picker_auth_probe.py` (bundle: `picker_auth_probe.py`,
expires 2026-09-30 15:15 UTC) — creates a Picker session, prints the
`pickerUri`, polls `list_media_items` for METADATA ONLY. It never calls
`download_media`.

Expected success: session JSON with `pickerUri`, media item count.
Expected pre-auth: HTTP 401 UNAUTHENTICATED (fail-safe, nothing touched).

## Scope of the grant
- `photospicker.mediaitems.readonly` — user-selected items only.
- Tokens live in the Mac keychain path the setup script uses; never paste
  token contents into chat.

## Boundaries
- Picker auth does NOT authorize `--live`, deploy, launchd, Takeout ingest,
  deletion, or full-library work. Each needs its own explicit approval.
