"""Exercise retry decisions in macOS Bash without contacting Apple or sleeping."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "apple_network_retry.sh"
HARNESS = r'''
set -euo pipefail
source "$1"
calls=0
delays=""
sleep() { delays="${delays}${delays:+,}$1"; }
operation() {
  calls=$((calls + 1))
  if [[ "$calls" -le "$TEST_FAILURES" ]]; then
    printf '%s\n' "$TEST_MESSAGE" >&2
    return 68
  fi
  echo 'The validate action worked!'
}
if apple_network_retry operation credential-must-not-be-logged; then
  status=0
else
  status=$?
fi
printf 'RESULT:%s:%s:%s\n' "$status" "$calls" "$delays"
'''


class AppleNetworkRetryTests(unittest.TestCase):
    def check_retry(self, message, failures, expected):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["/bin/bash", "-c", HARNESS, "retry-test", str(HELPER)],
                env={**os.environ, "TMPDIR": directory, "TEST_MESSAGE": message,
                     "TEST_FAILURES": str(failures)},
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertIn(f"RESULT:{expected}\n", result.stdout)
            self.assertNotIn("credential-must-not-be-logged", result.stdout + result.stderr)
            self.assertEqual(list(Path(directory).iterdir()), [])
            return result

    def test_success_needs_no_retry(self):
        self.check_retry("", 0, "0:1:")

    def test_actual_intel_failure_recovers(self):
        result = self.check_retry(
            'error is Error Domain=NSURLErrorDomain Code=-1005 '
            '"The network connection was lost."\nThe validate action failed! Error 68.',
            1, "0:2:10",
        )
        self.assertIn("The validate action worked!", result.stdout)

    def test_persistent_network_failure_stops_after_four_attempts(self):
        self.check_retry("NSURLErrorDomain Code=-1001", 10, "68:4:10,20,40")

    def test_service_unavailable_recovers(self):
        self.check_retry("HTTP status code: 503", 2, "0:3:10,20")

    def test_rate_limit_recovers(self):
        self.check_retry("HTTP 429 Too Many Requests", 1, "0:2:10")

    def test_error_68_without_transport_diagnostic_is_not_retried(self):
        self.check_retry("The validate action failed! Error 68.", 10, "68:1:")

    def test_rejected_signature_is_not_retried_even_with_network_error(self):
        self.check_retry("rejected: invalid signature\nThe network connection was lost.",
                         10, "68:1:")

    def test_authentication_failure_is_not_retried(self):
        self.check_retry("HTTP 401 Unauthorized\nThe network connection was lost.",
                         10, "68:1:")


if __name__ == "__main__":
    unittest.main()
