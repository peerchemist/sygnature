#!/bin/sh
# Uses only synthetic Keychain entries and a test-specific sandbox marker.
set -eu

if [ "$(uname -s)" != Darwin ] || [ "$#" -ne 0 ]; then
  echo "Usage (on macOS): sh scripts/test_macos_keychain_restart.sh" >&2
  exit 2
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

flutter build macos --debug \
  --target integration_test/secure_storage_test.dart \
  --dart-define=RUN_KEYCHAIN_RESTART_TESTS=true

# Start the same binary three times without rebuilding or clearing its sandbox.
# Stop only the processes started here, leaving any normal wallet app alone.
python3 - "$project_dir/build/macos/Build/Products/Debug/sygnature.app/Contents/MacOS/sygnature" <<'PY'
import pathlib
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory(prefix="sygnature-keychain-restart-") as directory:
    for phase in ("write", "read", "cleanup"):
        log_path = pathlib.Path(directory) / f"{phase}.log"
        with log_path.open("w") as log:
            process = subprocess.Popen([sys.argv[1]], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 60
                expected = f"Keychain restart phase {phase} passed (PID {process.pid})."
                while True:
                    output = log_path.read_text()
                    if any(error in output for error in (
                        "Some tests failed.", "EXCEPTION CAUGHT", "[E]",
                    )):
                        raise RuntimeError(output)
                    if "All tests passed!" in output:
                        if expected not in output:
                            raise RuntimeError(f"Expected {expected}\n{output}")
                        print(output, end="", flush=True)
                        break
                    if process.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError(f"Phase {phase} exited or timed out:\n{output}")
                    time.sleep(1)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()

print("Keychain persistence and deletion passed across three app processes.")
PY
