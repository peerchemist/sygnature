#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
readonly bundle="$script_dir/build/app/outputs/bundle/release/app-release.aab"

usage() {
  cat <<'EOF'
Usage: ./build_playstore.sh [FLUTTER_BUILD_OPTIONS]

Builds the Sygnature release Android App Bundle using the project's configured
signing key. Additional options are forwarded to `flutter build appbundle`,
for example:

  ./build_playstore.sh --build-name 1.0.0 --build-number 27
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for tool in flutter cargo java javac; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required command not found: $tool" >&2
    usage
    exit 1
  fi
done

cd -- "$script_dir"
flutter build appbundle \
  --release \
  "$@"

if [[ ! -f "$bundle" ]]; then
  echo "error: Flutter did not create the expected bundle: $bundle" >&2
  exit 1
fi

echo "Built $bundle"
