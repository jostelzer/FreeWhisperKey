#!/usr/bin/env bash
set -euo pipefail

# Packages the whisper.cpp CLI binary (and optionally the ggml-base model)
# into dist/whisper-bundle. In addition to the executable we also copy all
# dylib dependencies so the bundle is fully self-contained.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_DIR="$ROOT_DIR/whisper.cpp"
BIN_SRC="$WHISPER_DIR/build/bin/whisper-cli"
MODEL_SRC="$WHISPER_DIR/models/ggml-base.bin"
DEST="$ROOT_DIR/dist/whisper-bundle"
LIB_DEST="$DEST/lib"
SKIP_MODEL=1
MAX_MIN_OS="${WHISPER_BUNDLE_MAX_MIN_OS:-13.0}"
EXEC_RPATH="@executable_path/../lib"
LIB_RPATH="@loader_path"
declare -a COPIED_LIBS=()

usage() {
  cat <<'EOF'
Usage: scripts/package_whisper_bundle.sh [--include-model]

Creates dist/whisper-bundle containing the whisper.cpp CLI binary and all
runtime dylibs. Pass --include-model to also copy ggml-base.bin into the bundle.
EOF
}

require_cmds() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "error: required tool '$cmd' not found in PATH" >&2
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
}

die() {
  echo "error: $*" >&2
  exit 1
}

parse_minos() {
  local binary="$1"
  python3 - "$binary" <<'PY'
import subprocess, sys
out = subprocess.check_output(["otool", "-l", sys.argv[1]], text=True)
for line in out.splitlines():
    line = line.strip()
    if line.startswith("minos "):
        print(line.split()[1])
        sys.exit(0)
sys.exit(1)
PY
}

ensure_deployment_target() {
  local binary="$1"
  local max_allowed="$2"
  local minos
  if ! minos="$(parse_minos "$binary")"; then
    die "unable to determine deployment target for $binary"
  fi
  python3 - "$minos" "$max_allowed" "$binary" <<'PY'
import sys
from functools import cmp_to_key

def normalize(value):
    parts = [int(p) for p in value.split(".")]
    while len(parts) < 3:
        parts.append(0)
    return parts

minos, limit, binary = sys.argv[1], sys.argv[2], sys.argv[3]
min_parts = normalize(minos)
limit_parts = normalize(limit)
if min_parts > limit_parts:
    limit_fmt = ".".join(str(x) for x in limit_parts[:2])
    print(f"{binary} targets macOS {minos}, please rebuild with MACOSX_DEPLOYMENT_TARGET={limit_fmt}")
    sys.exit(1)
PY
}

list_rpaths() {
  local binary="$1"
  python3 - "$binary" <<'PY'
import subprocess, sys
out = subprocess.check_output(["otool", "-l", sys.argv[1]], text=True)
lines = out.splitlines()
paths = []
seen = set()
capture = False
for line in lines:
    stripped = line.strip()
    if stripped == "cmd LC_RPATH":
        capture = True
        continue
    if capture and stripped.startswith("path "):
        path = stripped.split()[1]
        if path not in seen:
            seen.add(path)
            paths.append(path)
        capture = False
        continue
    if stripped.startswith("cmd ") and stripped != "cmd LC_RPATH":
        capture = False
print("\n".join(paths))
PY
}

rewrite_rpaths() {
  local binary="$1"
  local replacement="$2"
  local -a current=()
  while IFS= read -r rpath; do
    [[ -z "$rpath" ]] && continue
    current+=("$rpath")
  done < <(list_rpaths "$binary")
  if [[ ${#current[@]} -gt 0 ]]; then
    for rpath in "${current[@]}"; do
      [[ -z "$rpath" ]] && continue
      install_name_tool -delete_rpath "$rpath" "$binary" >/dev/null 2>&1 || true
    done
  fi
  install_name_tool -add_rpath "$replacement" "$binary"
}

copy_dependency_libs() {
  mkdir -p "$LIB_DEST"
  local -a deps=()
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    deps+=("$dep")
  done < <(otool -L "$BIN_SRC" | awk '/@rpath/ {print $1}')
  if [[ ${#deps[@]} -eq 0 ]]; then
    die "no @rpath dependencies found in $BIN_SRC (unexpected)"
  fi
  for dep in "${deps[@]}"; do
    [[ -z "$dep" ]] && continue
    local name="${dep##*/}"
    local already=0
    if [[ ${#COPIED_LIBS[@]} -gt 0 ]]; then
      for existing in "${COPIED_LIBS[@]}"; do
        if [[ "$existing" == "lib/$name" ]]; then
          already=1
          break
        fi
      done
    fi
    [[ $already -eq 1 ]] && continue
    local src
    src=$(find "$WHISPER_DIR/build" -name "$name" -print -quit)
    if [[ -z "$src" ]]; then
      die "unable to locate dependency $name under $WHISPER_DIR/build"
    fi
    cp -pRL "$src" "$LIB_DEST/"
    COPIED_LIBS+=("lib/$name")
  done
}

generate_manifest() {
  local manifest="$DEST/manifest.json"
  local -a files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    die "no files supplied for manifest creation"
  fi
  local -a sorted=()
  while IFS= read -r entry; do
    sorted+=("$entry")
  done < <(printf '%s\n' "${files[@]}" | LC_ALL=C sort -u)
  python3 - "$DEST" "$manifest" "${sorted[@]}" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
files = sys.argv[3:]
data = {"files": {}}
for rel in files:
    path = root / rel
    if not path.exists():
        raise SystemExit(f"Missing manifest entry target: {path}")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    data["files"][rel] = digest
manifest.write_text(json.dumps(data, indent=2) + "\n")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-model)
      SKIP_MODEL=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

require_cmds otool install_name_tool shasum python3 find

if [[ ! -x "$BIN_SRC" ]]; then
  die "whisper-cli binary not found at $BIN_SRC. Build whisper.cpp first."
fi

ensure_deployment_target "$BIN_SRC" "$MAX_MIN_OS"

if [[ $SKIP_MODEL -eq 0 && ! -f "$MODEL_SRC" ]]; then
  die "Model file not found at $MODEL_SRC. Run whisper.cpp/models/download-ggml-model.sh first."
fi

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/models"

cp "$BIN_SRC" "$DEST/bin/"
cp "$ROOT_DIR/LICENSE" "$DEST/"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$DEST/"

copy_dependency_libs
rewrite_rpaths "$DEST/bin/whisper-cli" "$EXEC_RPATH"
if [[ -d "$LIB_DEST" ]]; then
  while IFS= read -r -d '' libfile; do
    rewrite_rpaths "$libfile" "$LIB_RPATH"
  done < <(find "$LIB_DEST" -type f -print0)
fi

manifest_files=("bin/whisper-cli")
if [[ ${#COPIED_LIBS[@]} -gt 0 ]]; then
  manifest_files+=("${COPIED_LIBS[@]}")
fi

if [[ $SKIP_MODEL -eq 0 ]]; then
  cp "$MODEL_SRC" "$DEST/models/"
  manifest_files+=("models/ggml-base.bin")
fi

generate_manifest "${manifest_files[@]}"

cat >"$DEST/README.txt" <<'EOF'
whisper-bundle
===============

Contents copied from whisper.cpp for embedding or redistribution with a macOS helper app.

bin/whisper-cli          - Command-line transcriber built with Metal support.
lib/*.dylib              - Shared libraries required by whisper-cli and ggml backends.
models/*.bin             - Place Whisper ggml models here (e.g. ggml-medium.en.bin).

Usage example (run from repo root):
  dist/whisper-bundle/bin/whisper-cli \
      -m dist/whisper-bundle/models/ggml-medium.en.bin \
      -f whisper.cpp/samples/jfk.wav -otxt -of /tmp/jfk_bundle

Licensing:
  - LICENSE (BSD 3-Clause) applies to the helper glue in this repository.
  - THIRD_PARTY_NOTICES.md reproduces the MIT licenses for whisper.cpp and OpenAI's Whisper models.
Ensure you ship both files with any redistribution.
EOF

echo "Bundle created at $DEST"
