#!/usr/bin/env python3
"""
download_picker_items.py -- bounded Google Photos Picker download driver.

Creates a Picker session, prints the pickerUri, polls until the user's
selection is ready, then downloads the selected items + metadata sidecars
into a staging dir. Bounded test expects exactly 1 photo + 1 video.

Writes ONLY to the staging dir: never touches the archive or the manifest.

--dry-run: no network, no client import. Synthesizes clearly-labeled
placeholder media + metadata sidecars matching --expect-photo/--expect-video
so the staging -> harness pipeline is VM-testable. (Labeled "dry_run".)

Download mechanics: prefers the app dir's google_photos_client.download_media
(when importable) with signature adaptation; otherwise downloads baseUrl
directly over urllib with the OAuth token (=d suffix for images, =dv for
videos). Sidecars carry id / mimeType / filename / creationTime only --
no tokens.
"""

import argparse
import inspect
import json
import os
import re
import shutil
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

MIME_EXT = {
    "image/jpeg": ".jpg", "image/png": ".png", "image/heic": ".heic",
    "image/heif": ".heif", "image/webp": ".webp", "image/gif": ".gif",
    "image/tiff": ".tiff", "image/bmp": ".bmp",
    "video/mp4": ".mp4", "video/quicktime": ".mov", "video/x-msvideo": ".avi",
    "video/x-matroska": ".mkv", "video/webm": ".webm", "video/3gpp": ".3gp",
    "video/3gpp2": ".3g2", "video/mp2t": ".mts",
}
POLL_EVERY_S = 10


def sanitize(item_id):
    return re.sub(r"[^A-Za-z0-9._-]", "_", str(item_id))[:80] or "item"


def ext_for(mime):
    if mime in MIME_EXT:
        return MIME_EXT[mime]
    maintype = str(mime).split("/", 1)[0]
    if maintype == "image":
        return ".bin"
    if maintype == "video":
        return ".bin"
    return ""


def creation_time_of(item, media_file):
    for src in (media_file, item):
        v = src.get("creationTime")
        if v:
            return str(v)
    meta = item.get("mediaMetadata", {}) or {}
    if meta.get("creationTime"):
        return str(meta["creationTime"])
    return datetime.now(timezone.utc).isoformat()


def download_with_client(download_media, url, dest_path):
    """Call the app's download_media defensively; return True on success."""
    sig = inspect.signature(download_media)
    n = len(sig.parameters)
    if n == 1:
        out = download_media(url)
    elif n >= 2:
        out = download_media(url, str(dest_path))
    else:
        raise TypeError(f"unsupported download_media signature: {sig}")
    if isinstance(out, (bytes, bytearray)):
        dest_path.write_bytes(bytes(out))
        return True
    if isinstance(out, (str, os.PathLike)):
        got = Path(out)
        if got != dest_path:
            shutil.copyfile(got, dest_path)
        return True
    if out is None and n >= 2 and dest_path.exists():
        return True  # it wrote to the destination itself
    raise TypeError(f"download_media returned unusable {type(out).__name__}")


def download_with_urllib(token, url, dest_path, is_video):
    """baseUrl download: '=d' for images, '=dv' for videos (Photos API)."""
    suffix = "=dv" if is_video else "=d"
    req = urllib.request.Request(url + suffix,
                                 headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=120) as resp, \
            open(dest_path, "wb") as f:
        shutil.copyfileobj(resp, f)
    return True


def import_client(app_dir):
    sys.path.insert(0, os.path.abspath(app_dir))
    import google_photos_client as client  # noqa: E402
    return client


def create_and_wait(client, timeout_s):
    session = client.create_session()
    if not isinstance(session, dict) or not session.get("id"):
        raise RuntimeError("create_session returned no session id")
    sid = session["id"]
    print(f"session id: {sid}")
    if session.get("pickerUri"):
        print("OPEN THIS URL AND SELECT THE ITEMS:")
        print(session["pickerUri"])
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        got = client.get_session(sid)
        if isinstance(got, dict) and got.get("mediaItemsSet"):
            return sid
        print(f"  waiting for selection... ({int(deadline - time.time())}s left)",
              flush=True)
        time.sleep(POLL_EVERY_S)
    raise TimeoutError(
        f"timed out after {timeout_s}s waiting for the Picker selection. "
        "Open the printed pickerUri, select 1 photo + 1 video, and rerun.")


def list_all(client, sid):
    """Fetch every selected item, following pagination.

    Fail-closed: if the session spans more than one page but the client does
    not accept a page token, raise instead of silently truncating the
    selection (a silent 50-item cap would corrupt a full-library ingest).
    """
    import inspect
    try:
        params = inspect.signature(client.list_media_items).parameters
    except (TypeError, ValueError):
        params = {}
    token_names = [n for n in ("page_token", "pageToken") if n in params]
    items = []
    page_token = None
    while True:
        kwargs = {"page_size": 100}
        if page_token is not None:
            if not token_names:
                raise RuntimeError(
                    "picker session has more than one page of selected items "
                    "but the client's list_media_items() accepts no page "
                    "token; refusing to silently truncate the selection.")
            kwargs[token_names[0]] = page_token
        resp = client.list_media_items(sid, **kwargs)
        if not isinstance(resp, dict):
            raise RuntimeError(
                f"list_media_items returned {type(resp).__name__}, not a dict")
        batch = resp.get("mediaItems", [])
        items.extend(m for m in batch if isinstance(m, dict))
        page_token = resp.get("nextPageToken")
        if not page_token:
            break
    return items


def write_sidecar(media_path, item, media_file, dry_run=False):
    meta = {
        "id": item.get("id"),
        "mimeType": media_file.get("mimeType"),
        "filename": media_file.get("filename") or media_path.name,
        "creationTime": creation_time_of(item, media_file),
        "dry_run": dry_run,
    }
    sc = media_path.with_name(media_path.name + ".json")
    sc.write_text(json.dumps(meta, indent=2) + "\n")
    return sc


def verify_mix(items, expect_photo, expect_video):
    photos = sum(1 for it in items
                 if str(it[1].get("mimeType", "")).startswith("image/"))
    videos = sum(1 for it in items
                 if str(it[1].get("mimeType", "")).startswith("video/"))
    print(f"selected mix: {photos} photo(s), {videos} video(s) "
          f"(expected {expect_photo}/{expect_video})")
    if photos != expect_photo or videos != expect_video:
        raise RuntimeError(
            f"mix mismatch: got {photos} photo(s) + {videos} video(s), "
            f"expected {expect_photo} + {expect_video}. "
            "Reselect exactly the expected mix and rerun.")
    return photos, videos


def dry_run(staging, expect_photo, expect_video):
    """No network, no client: synthesize labeled fixtures + verify the mix."""
    staging.mkdir(parents=True, exist_ok=True)
    items = []
    now = datetime.now(timezone.utc).isoformat()
    for i in range(expect_photo):
        p = staging / f"dryrun-photo-{i}.jpg"
        p.write_bytes(f"DRYRUN-PHOTO-{i}".encode() * 100)
        item = {"id": f"dryrun-photo-{i}"}
        mf = {"mimeType": "image/jpeg", "filename": p.name,
              "creationTime": now}
        write_sidecar(p, item, mf, dry_run=True)
        items.append((item, mf))
    for i in range(expect_video):
        p = staging / f"dryrun-video-{i}.mp4"
        p.write_bytes(f"DRYRUN-VIDEO-{i}".encode() * 100)
        item = {"id": f"dryrun-video-{i}"}
        mf = {"mimeType": "video/mp4", "filename": p.name,
              "creationTime": now}
        write_sidecar(p, item, mf, dry_run=True)
        items.append((item, mf))
    verify_mix(items, expect_photo, expect_video)
    print(f"DRY-RUN OK: {len(items)} synthetic items staged in {staging}, "
          "0 downloads, 0 network calls.")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=("Picker download driver: bounded mode stages exactly "
                 "--expect-photo/--expect-video (default 1/1); --unbounded "
                 "stages the whole Picker selection for full ingest."))
    ap.add_argument("--app-dir", required=True,
                    help="dir containing google_photos_client.py")
    ap.add_argument("--staging-dir", required=True,
                    help="staging dir (created if missing; ONLY this is written)")
    ap.add_argument("--expect-photo", type=int, default=1)
    ap.add_argument("--expect-video", type=int, default=1)
    ap.add_argument("--timeout-s", type=int, default=600,
                    help="max seconds to wait for the Picker selection")
    ap.add_argument("--unbounded", action="store_true",
                    help="full-ingest mode: accept any photo/video mix "
                         "(skips verify_mix); use with the auditor's "
                         "full-ingest approval, never for bounded acceptance")
    ap.add_argument("--dry-run", action="store_true",
                    help="no network: stage labeled synthetic fixtures only")
    args = ap.parse_args(argv)

    if args.expect_photo < 0 or args.expect_video < 0:
        print("ERROR: --expect-photo/--expect-video must be >= 0", file=sys.stderr)
        return 2
    staging = Path(args.staging_dir)

    if args.dry_run:
        return dry_run(staging, args.expect_photo, args.expect_video)

    client = import_client(args.app_dir)
    staging.mkdir(parents=True, exist_ok=True)

    sid = create_and_wait(client, args.timeout_s)
    items = list_all(client, sid)
    if not items:
        print("ERROR: session has no selected items", file=sys.stderr)
        return 1

    dl = getattr(client, "download_media", None)
    token = None
    if dl is None:
        loader = getattr(client, "load_token", None)
        if loader is None:
            raise RuntimeError(
                "google_photos_client has no download_media and no load_token: "
                "cannot download baseUrl securely")
        token = loader() if callable(loader) else loader
        if isinstance(token, dict):
            token = token.get("access_token") or token.get("token")
        if not isinstance(token, str) or not token:
            raise RuntimeError(
                "could not obtain a usable OAuth token for baseUrl download")

    staged = []
    skipped = []
    for item in items:
        mf = item.get("mediaFile", {})
        if not isinstance(mf, dict):
            mf = {}
        mime = mf.get("mimeType") or ""
        base_url = mf.get("baseUrl")
        if not base_url:
            print(f"WARN: item {item.get('id')} has no baseUrl; skipping",
                  file=sys.stderr)
            continue
        ext = ext_for(mime)
        if not ext:
            print(f"WARN: item {item.get('id')} mimeType={mime!r} "
                  "not media; skipping", file=sys.stderr)
            continue
        dest = staging / (sanitize(item.get("id")) + ext)
        is_video = str(mime).startswith("video/")
        ok = False
        last_err = None
        for attempt in range(1, 6):
            try:
                if callable(dl):
                    try:
                        download_with_client(dl, base_url, dest)
                    except Exception as e:
                        print(f"client download_media failed ({e}); "
                              "falling back to urllib", file=sys.stderr)
                        if token is None:
                            raise
                        download_with_urllib(token, base_url, dest, is_video)
                else:
                    download_with_urllib(token, base_url, dest, is_video)
                ok = True
                break
            except Exception as e:  # noqa: BLE001 - retry then record
                last_err = e
                print(f"WARN: download attempt {attempt}/5 failed for "
                      f"{item.get('id')}: {e}", file=sys.stderr)
                time.sleep(2 ** attempt)
        if not ok:
            print(f"WARN: item {item.get('id')} skipped after 5 attempts: "
                  f"{last_err}; recorded for follow-up, continuing",
                  file=sys.stderr)
            skipped.append((str(item.get("id")), str(mime), str(last_err)))
            continue
        write_sidecar(dest, item, mf)
        staged.append((item, mf))
        print(f"staged: {dest.name} ({mime})")

    if skipped:
        skip_path = staging / "skipped.tsv"
        with open(skip_path, "w") as sf:
            for sid_, mime_, err_ in skipped:
                sf.write(f"{sid_}\t{mime_}\t{err_}\n")
        print(f"WARN: {len(skipped)} item(s) could not be downloaded; "
              f"listed in {skip_path}", file=sys.stderr)
    if not staged:
        print("ERROR: no items were staged", file=sys.stderr)
        return 1
    if args.unbounded:
        photos = sum(1 for it in staged
                     if str(it[1].get("mimeType", "")).startswith("image/"))
        videos = sum(1 for it in staged
                     if str(it[1].get("mimeType", "")).startswith("video/"))
        print(f"unbounded mix: {photos} photo(s), {videos} video(s); "
              f"{len(skipped)} skipped")
    else:
        verify_mix(staged, args.expect_photo, args.expect_video)
    print(f"DOWNLOAD_OK: {len(staged)} item(s) in {staging} (+sidecars). "
          "archive/manifest untouched.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
