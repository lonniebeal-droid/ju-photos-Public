#!/usr/bin/env bash
#
# backup_and_swap.sh -- install a new archiver with a verified backup.
# Copy only. Never moves, never deletes.
#
#   ./backup_and_swap.sh APP_DIR NEW_FILE
#
# Steps: py_compile NEW_FILE -> cp existing to .bak-TIMESTAMP ->
#        cp NEW_FILE over target -> verify installed sha == new sha and
#        backup sha == pre-install sha. Any failure -> exit nonzero BEFORE
#        the swap completes (fail-closed).
#
set -euo pipefail

APP_DIR="${1:?usage: backup_and_swap.sh APP_DIR NEW_FILE}"
NEW_FILE="${2:?usage: backup_and_swap.sh APP_DIR NEW_FILE}"
TARGET="$APP_DIR/ju_photos_archiver.py"
TS="$(date +%Y-%m-%d-%H%M%S)"
BACKUP="$APP_DIR/ju_photos_archiver.py.bak-$TS"

[ -f "$NEW_FILE" ] || { echo "ERROR: new file not found: $NEW_FILE" >&2; exit 2; }
[ -d "$APP_DIR" ] || { echo "ERROR: app dir not found: $APP_DIR" >&2; exit 2; }
python3 -m py_compile "$NEW_FILE" || { echo "ERROR: $NEW_FILE fails py_compile" >&2; exit 2; }
NEW_SHA="$(shasum -a 256 "$NEW_FILE" | awk '{print $1}')"

if [ -f "$TARGET" ]; then
  PRE_SHA="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
  cp "$TARGET" "$BACKUP"
  BACKUP_SHA="$(shasum -a 256 "$BACKUP" | awk '{print $1}')"
  [ "$BACKUP_SHA" = "$PRE_SHA" ] || { echo "ERROR: backup sha mismatch" >&2; exit 1; }
  echo "backup: $BACKUP sha=$BACKUP_SHA"
else
  echo "WARN: no existing $TARGET (fresh install, no backup taken)"
  BACKUP="(none)"
fi

cp "$NEW_FILE" "$TARGET"
INSTALLED_SHA="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
[ "$INSTALLED_SHA" = "$NEW_SHA" ] || { echo "ERROR: installed sha mismatch" >&2; exit 1; }

echo "installed: $TARGET sha=$INSTALLED_SHA"
echo "BACKUP_AND_SWAP_OK backup=$BACKUP"
