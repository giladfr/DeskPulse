#!/bin/zsh
set -euo pipefail

tools_dir=${0:A:h}
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
python_bin=/opt/homebrew/opt/python@3.11/bin/python3.11

if [[ ! -x "$python_bin" ]]; then
  echo "Python 3.11 is required at $python_bin" >&2
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
