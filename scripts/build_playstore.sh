#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
project_dir="$(cd -- "$script_dir/.." && pwd)"
readonly project_dir
readonly bundle="$project_dir/build/app/outputs/bundle/release/app-release.aab"
readonly signing_properties="$project_dir/android/key.properties"

usage() {
  cat <<'EOF'
Usage: ./scripts/build_playstore.sh [FLUTTER_BUILD_OPTIONS]

Builds the Sygnature release Android App Bundle using the project's configured
signing key. Additional options are forwarded to `flutter build appbundle`,
for example:

  ./scripts/build_playstore.sh --build-name 1.0.0 --build-number 27
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$signing_properties" ]]; then
  echo "error: Play Store signing properties not found: $signing_properties" >&2
  exit 1
fi

for tool in flutter cargo java javac; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: required command not found: $tool" >&2
    usage
    exit 1
  fi
done

cd -- "$project_dir"
flutter build appbundle \
  --release \
  --target-platform android-arm64,android-x64 \
  "$@"

if [[ ! -f "$bundle" ]]; then
  echo "error: Flutter did not create the expected bundle: $bundle" >&2
  exit 1
fi

echo "Built $bundle"
