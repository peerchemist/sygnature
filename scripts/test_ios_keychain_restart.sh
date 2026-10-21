#!/bin/sh
# Run only on a dedicated, booted iOS Simulator with no wallet data.
set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: sh scripts/test_ios_keychain_restart.sh <simulator-id>" >&2
  exit 2
fi

simulator_id=$1
bundle_id=network.noosphere.sygnature
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

flutter build ios --simulator --debug \
  --target integration_test/secure_storage_test.dart \
  --dart-define=RUN_IOS_KEYCHAIN_RESTART_TESTS=true
xcrun simctl install "$simulator_id" build/ios/iphonesimulator/Runner.app

# Leave the simulator installed for inspection but stop the synthetic test app.
trap 'xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true' EXIT

for phase in write read cleanup; do
  launch_output=$(xcrun simctl launch --terminate-running-process "$simulator_id" "$bundle_id")
  process_id=${launch_output##*: }
  case "$process_id" in
    ''|*[!0-9]*) echo "Could not parse simulator PID: $launch_output" >&2; exit 1 ;;
  esac

  attempt=0
  while :; do
    log_output=$(xcrun simctl spawn "$simulator_id" log show --last 2m \
      --style compact \
      --predicate "processIdentifier == $process_id AND eventMessage CONTAINS \"flutter:\"" 2>/dev/null)
    case "$log_output" in
      *'Some tests failed.'*|*'EXCEPTION CAUGHT'*|*'[E]'*)
        printf '%s\n' "$log_output" >&2
        exit 1
        ;;
      *'All tests passed!'*)
        case "$log_output" in
          *"Keychain restart phase $phase passed (PID $process_id)."*)
            printf '%s\n' "$log_output"
            break
            ;;
          *)
            printf 'Expected phase %s, but saw:\n%s\n' "$phase" "$log_output" >&2
            exit 1
            ;;
        esac
        ;;
    esac
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      printf 'Timed out waiting for phase %s:\n%s\n' "$phase" "$log_output" >&2
      exit 1
    fi
    sleep 1
  done
done

echo 'Keychain persistence and deletion passed across three app processes.'
