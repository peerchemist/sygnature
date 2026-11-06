#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
project_dir="$(cd -- "$script_dir/.." && pwd)"
readonly project_dir
flutter_args=()
export_options=""

usage() {
  cat <<'USAGE'
Usage: scripts/build_appstore.sh [OPTIONS]

Build and sign the production iOS app, then export a local App Store IPA.
Uses the signing team configured in ios/Runner.xcodeproj. Requires macOS,
Xcode with iOS signing configured, and Flutter. Does not upload the build.

Options:
  --build-name VERSION          Override the pubspec.yaml version name
  --build-number NUMBER         Override the pubspec.yaml build number
  --no-pub                      Reuse resolved Flutter dependencies
  --export-options-plist PATH   Use custom App Store signing/export options
  -h, --help                    Show this help

Examples:
  scripts/build_appstore.sh --build-number 47
  scripts/build_appstore.sh --build-name 1.0.0 --build-number 48 --no-pub

Outputs: build/ios/archive/*.xcarchive and build/ios/ipa/*.ipa
The production entrypoint is always lib/main.dart and the build mode is Release.
USAGE
}

fail() { echo "error: $*" >&2; exit 1; }

while (($# > 0)); do
  case "$1" in
    --build-name | --build-number)
      if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
        fail "$1 requires a value"
      fi
      flutter_args+=("$1" "$2")
      shift 2
      ;;
    --build-name=* | --build-number=*)
      [[ -n "${1#*=}" ]] || fail "${1%%=*} requires a value"
      flutter_args+=("$1")
      shift
      ;;
    --no-pub)
      flutter_args+=("$1")
      shift
      ;;
    --export-options-plist)
      if (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
        fail "$1 requires a path"
      fi
      export_options="$2"
      shift 2
      ;;
    --export-options-plist=*)
      export_options="${1#*=}"
      [[ -n "$export_options" ]] || fail "--export-options-plist requires a path"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      fail "unsupported option: $1 (see --help)"
      ;;
  esac
done

[[ "$(uname -s)" == Darwin ]] || fail "macOS is required to build an iOS IPA"
for tool in flutter xcrun xcodebuild codesign ditto python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "required command not found: $tool"
done

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/sygnature-appstore.XXXXXX")"
readonly temporary_dir
trap 'rm -rf -- "$temporary_dir"' EXIT

# Validate before changing directories, so a caller's relative plist path works.
# Force local export and preserve the requested version/build number.
python3 - "$export_options" "$temporary_dir/ExportOptions.plist" <<'PY'
import plistlib
import sys

source, destination = sys.argv[1:]
options = {}
if source:
    try:
        with open(source, 'rb') as stream:
            options = plistlib.load(stream)
    except (OSError, ValueError) as error:
        sys.exit(f'error: cannot read export options: {error}')
    if not isinstance(options, dict):
        sys.exit('error: export options must be a plist dictionary')
    if options.get('method') not in ('app-store-connect', 'app-store'):
        sys.exit('error: export options must use the app-store-connect method')
    if options.get('destination', 'export') != 'export':
        sys.exit('error: this script only exports locally; destination must be export')
    if options.get('testFlightInternalTestingOnly', False):
        sys.exit('error: an internal-only TestFlight build cannot be released on the App Store')
else:
    options.update(signingStyle='automatic', uploadSymbols=True, stripSwiftSymbols=True)
options.update(method='app-store-connect', destination='export',
               manageAppVersionAndBuildNumber=False, testFlightInternalTestingOnly=False)
with open(destination, 'wb') as stream:
    plistlib.dump(options, stream)
PY

cd -- "$project_dir"
touch "$temporary_dir/build-start"
flutter build ipa --release --target lib/main.dart \
  --export-options-plist "$temporary_dir/ExportOptions.plist" \
  ${flutter_args[@]+"${flutter_args[@]}"}

# Flutter can exit successfully after an export failure. Accept only an IPA
# written by this invocation; never report a stale previous build as success.
ipa_path="$(python3 - "$project_dir/build/ios/ipa" "$temporary_dir/build-start" <<'PY'
from pathlib import Path
import sys

folder, marker = map(Path, sys.argv[1:])
started = marker.stat().st_mtime_ns
files = [path for path in folder.glob('*.ipa')
         if path.is_file() and path.stat().st_size > 0 and path.stat().st_mtime_ns >= started]
if len(files) != 1:
    sys.exit('error: expected one newly exported IPA; inspect the Flutter/Xcode export errors above')
print(files[0])
PY
)"
readonly ipa_path

ditto -x -k "$ipa_path" "$temporary_dir/unpacked"
shopt -s nullglob
apps=("$temporary_dir/unpacked/Payload/"*.app)
((${#apps[@]} == 1)) || fail "the exported IPA must contain exactly one application"
readonly app_path="${apps[0]}"
codesign --verify --deep --strict "$app_path"
codesign --display --entitlements :- "$app_path" \
  > "$temporary_dir/entitlements.plist"

python3 - "$app_path/Info.plist" "$temporary_dir/entitlements.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
with open(sys.argv[2], 'rb') as stream:
    entitlements = plistlib.load(stream)
if info.get('CFBundleIdentifier') != 'network.noosphere.sygnature':
    sys.exit('error: exported application has an unexpected bundle identifier')
if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
    sys.exit('error: exported application is not an iOS device build')
if entitlements.get('get-task-allow', False) is not False:
    sys.exit('error: exported application still permits debugger attachment')
if entitlements.get('aps-environment') != 'production':
    sys.exit('error: exported application must use production push notification entitlements')
print(f"Verified Sygnature {info['CFBundleShortVersionString']} (build {info['CFBundleVersion']}).")
PY

echo "Built $ipa_path"
echo "Archive and dSYMs: $project_dir/build/ios/archive/"
echo "Upload the IPA with Transporter or distribute the archive through Xcode Organizer."
