#!/usr/bin/env sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON_BIN="python"
else
  echo "Python 3 is required to run validate.sh." >&2
  exit 1
fi

for candidate in \
  "$SCRIPT_DIR/.tina-starter/validate_core.py" \
  "$SCRIPT_DIR/../shared/validate_core.py"
do
  if [ -f "$candidate" ]; then
    exec "$PYTHON_BIN" "$candidate" "$SCRIPT_DIR"
  fi
done

echo "Cannot find starter validation core." >&2
exit 1
