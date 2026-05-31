#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$SCRIPT_DIR"
DIST_DIR="$ROOT/dist"
STAGING_DIR="$ROOT/.pack"

"$SCRIPT_DIR/validate.sh"

PLUGIN_ID="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -n 1)"
PLUGIN_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -n 1)"
OUT_FILE="$DIST_DIR/${PLUGIN_ID}-${PLUGIN_VERSION}.tinaplug"

rm -rf "$STAGING_DIR"
mkdir -p "$DIST_DIR" "$STAGING_DIR"

for entry in .* *; do
  [ "$entry" = "." ] && continue
  [ "$entry" = ".." ] && continue
  [ "$entry" = "dist" ] && continue
  [ "$entry" = ".pack" ] && continue
  [ "$entry" = ".tina-starter" ] && continue
  [ "$entry" = "README.md" ] && continue
  [ "$entry" = "pack.ps1" ] && continue
  [ "$entry" = "pack.sh" ] && continue
  [ "$entry" = "validate.ps1" ] && continue
  [ "$entry" = "validate.sh" ] && continue
  cp -R "$entry" "$STAGING_DIR/"
done

rm -f "$OUT_FILE"
(cd "$STAGING_DIR" && zip -qr "$OUT_FILE" .)
rm -rf "$STAGING_DIR"
echo "Packed to $OUT_FILE"
