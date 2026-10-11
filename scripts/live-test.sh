#!/usr/bin/env bash
# Runs the opt-in live tests (Packages/HermesKit/Tests/HermesLiveTests) against
# real Hermes dashboards, in the `hermesapp-test` profile. Mac only.
#
#   scripts/live-test.sh            # every server with an env file
#
# Servers come from git-ignored env files at the repo root:
#   .env.live-local   HERMES_LIVE_URL + HERMES_LIVE_TOKEN     (created here)
#   .env.live-remote  HERMES_LIVE_URL + HERMES_LIVE_USERNAME + HERMES_LIVE_PASSWORD
#
# For the local one this script starts `hermes dashboard` on 127.0.0.1:9139 with
# a fixed session token passed by environment only; config.yaml is not touched.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCAL_PORT=9139
LOCAL_ENV=.env.live-local

if command -v hermes >/dev/null; then
  if [[ ! -f $LOCAL_ENV ]]; then
    token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
    printf '# Local test dashboard (loopback, un-gated), started by scripts/live-test.sh\nHERMES_LIVE_URL=http://127.0.0.1:%s\nHERMES_LIVE_TOKEN=%s\n' \
      "$LOCAL_PORT" "$token" > "$LOCAL_ENV"
    chmod 600 "$LOCAL_ENV"
  fi
  if ! curl -fsS -m 2 "http://127.0.0.1:$LOCAL_PORT/api/status" >/dev/null 2>&1; then
    token=$(sed -n 's/^HERMES_LIVE_TOKEN=//p' "$LOCAL_ENV")
    log="${TMPDIR:-/tmp}/hermesapp-live-dashboard.log"
    echo "Starting local test dashboard on 127.0.0.1:$LOCAL_PORT (log: $log)"
    HERMES_DASHBOARD_SESSION_TOKEN="$token" nohup hermes dashboard --host 127.0.0.1 --port "$LOCAL_PORT" \
      --no-open --skip-build --isolated >"$log" 2>&1 &
    for _ in $(seq 1 45); do
      curl -fsS -m 2 "http://127.0.0.1:$LOCAL_PORT/api/status" >/dev/null 2>&1 && break
      sleep 2
    done
  fi
fi

HERMES_LIVE=1 swift test --package-path Packages/HermesKit --filter HermesLiveTests "$@"
