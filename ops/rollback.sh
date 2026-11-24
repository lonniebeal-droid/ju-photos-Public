#!/usr/bin/env bash
#
# rollback.sh -- restore the archiver from a .bak-TIMESTAMP backup.
# Copy only. Never deletes the backup.
#
#   ./rollback.sh APP_DIR [TIMESTAMP]
#
# With no TIMESTAMP, restores the newest backup. Verifies the restored
# file is byte-identical to the backup and passes py_compile.
#
set -euo pipefail

APP_DIR="${1:?usage: rollback.sh APP_DIR [TIMESTAMP]}"
TARGET="$APP_DIR/ju_photos_archiver.py"

if [ -n "${2:-}" ]; then
  BACKUP="$APP_DIR/ju_photos_archiver.py.bak-$2"
else
  BACKUP="$(ls -t "$APP_DIR"/ju_photos_archiver.py.bak-* 2>/dev/null | head -1 || true)"
fi
[ -n "$BACKUP" ] && [ -f "$BACKUP" ] || { echo "ERROR: no backup found in $APP_DIR" >&2; exit 2; }

python3 -m py_compile "$BACKUP" || { echo "ERROR: backup fails py_compile: $BACKUP" >&2; exit 1; }
BACKUP_SHA="$(shasum -a 256 "$BACKUP" | awk '{print $1}')"
cp "$BACKUP" "$TARGET"
RESTORED_SHA="$(shasum -a 256 "$TARGET" | awk '{print $1}')"
[ "$RESTORED_SHA" = "$BACKUP_SHA" ] || { echo "ERROR: restored sha mismatch" >&2; exit 1; }

echo "restored: $TARGET from $BACKUP sha=$RESTORED_SHA"
echo "ROLLBACK_OK backup_kept=$BACKUP"
