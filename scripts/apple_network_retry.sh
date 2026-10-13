#!/usr/bin/env bash

# Retry ticket-delivery/assessment transport failures, never signature failures.
# Do not use for uploads: a lost response could otherwise duplicate a submission.
apple_network_retry() {
  local attempt status output delay
  output="$(mktemp "${TMPDIR:-/tmp}/sygnature-apple-retry.XXXXXX")" || return 1
  delay=10
  for attempt in 1 2 3 4; do
    if "$@" >"$output" 2>&1; then
      cat "$output"
      rm -f -- "$output"
      return 0
    else
      status=$?
    fi
    cat "$output" >&2
    # Error 68 alone also covers invalid tickets; require a transport diagnostic.
    # A rejection must not be retried even if another line mentions networking.
    if [[ "$attempt" -eq 4 ]] ||
      grep -Eiq 'rejected|invalid signature|invalid ticket|ticket is invalid|HTTP[^[:digit:]]*(401|403)|status code[^[:digit:]]*(401|403)' "$output" ||
      ! grep -Eiq 'NSURLErrorDomain Code=-(1001|1003|1004|1005|1006|1009)|network connection was lost|network connection.*(failed|interrupted)|connection (reset|timed out)|could not connect to (the )?server|HTTP[^[:digit:]]*(429|50[0-9]|51[0-9])|status code[^[:digit:]]*(429|50[0-9]|51[0-9])' "$output"; then
      rm -f -- "$output"
      return "$status"
    fi
    # Command arguments may contain credentials; report only the attempt count.
    echo "Apple service transport failure; retry $((attempt + 1))/4 in ${delay}s." >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
}
