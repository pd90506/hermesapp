#!/usr/bin/env bash
# Swift Testing time limits cancel cooperative tests. This process deadline also
# bounds continuations/synchronous work that ignore cancellation, preserving logs.
# SIGINT, not TERM: SwiftPM forwards an interrupt to the test runner it spawned;
# on TERM it exits and leaves the runner (its own process group) running.
set -euo pipefail
log=${1:?Usage: test-package-ci.sh LOG_PATH [swift test arguments...]}
shift
mkdir -p "$(dirname "$log")"
if timeout --signal=INT --kill-after=15s "${HERMES_CI_TEST_TIMEOUT:-240s}" \
    stdbuf -oL -eL swift test --package-path Packages/HermesKit "$@" 2>&1 | tee "$log"; then
    exit 0
else
    pipeline_status=("${PIPESTATUS[@]}")
    status=${pipeline_status[0]}
    if (( status == 0 )); then status=${pipeline_status[1]}; fi
fi
{
    echo "Package test command failed (exit $status)."
    if (( status == 124 || status == 137 )); then
        echo "Process deadline exceeded; inspect tests below and the per-test time-limit issues above."
    fi
    echo "Tests started without a completion line (possible blockers, not necessarily independent failures):"
    awk '
        /◇ Test (case |run started)/ { next }
        /◇ Test .* started\./ {
            name=$0; sub(/^.*◇ Test /, "", name); sub(/ started\..*$/, "", name); pending[name]=1
        }
        /[✔✘] Test .* (passed|failed)/ {
            name=$0; sub(/^.*Test /, "", name); sub(/ (passed|failed).*$/, "", name); sub(/ with [0-9]+ test cases$/, "", name); delete pending[name]
        }
        END { for (name in pending) print "  " name }
    ' "$log"
} | tee -a "$log"
exit "$status"
