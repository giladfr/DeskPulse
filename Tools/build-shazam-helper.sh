#!/bin/zsh
set -euo pipefail

tools_dir=${0:A:h}
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
python_bin=${DESKPULSE_PYTHON:-}

if [[ -z "$python_bin" ]]; then
  for candidate in python3.11 /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
      python_bin=$(command -v "$candidate")
      break
    fi
  done
fi

if [[ -z "$python_bin" || ! -x "$python_bin" ]]; then
  echo "Python 3.11+ is required. Set DESKPULSE_PYTHON to its executable." >&2
  exit 1
fi

if ! "$python_bin" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
  echo "Python 3.11+ is required; found $($python_bin --version 2>&1)." >&2
  exit 1
fi

"$python_bin" -m venv "$build_dir/venv"
"$build_dir/venv/bin/pip" install --quiet \
  "shazamio==0.8.1" \
  "pyinstaller==6.15.0"
"$build_dir/venv/bin/pyinstaller" \
  --clean \
  --onefile \
  --name ShazamRecognizer \
  --distpath "$build_dir/dist" \
  --workpath "$build_dir/work" \
  --specpath "$build_dir/spec" \
  "$tools_dir/shazam_recognizer.py"
mkdir -p "$tools_dir/bin"
cp "$build_dir/dist/ShazamRecognizer" "$tools_dir/bin/ShazamRecognizer"
chmod +x "$tools_dir/bin/ShazamRecognizer"
echo "$tools_dir/bin/ShazamRecognizer"
