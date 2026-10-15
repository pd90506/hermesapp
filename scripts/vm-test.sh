#!/usr/bin/env bash
# Runs the tests in a headless macOS VM (Tart), so nothing runs on this Mac: the
# package live tests, the macOS window tests and the macOS UI test.
#
#   scripts/vm-test.sh          # all of the above
#   scripts/vm-test.sh --ios    # also the iOS-simulator UI test, in the VM (slow)
#   scripts/vm-test.sh --keep   # leave the VM running afterwards (faster next run)
#
# scripts/live-test.sh stays for running the live tests on this Mac by hand.
#
# The VM is a clone of Cirrus Labs' macOS + Xcode image (user admin/admin). Its disk
# persists, so it keeps its own Hermes, installed here on the first run: the macOS
# tests run against a dashboard on the VM's own 127.0.0.1, in the hermesapp-test
# profile. The model key comes from the git-ignored .env.vm-hermes
# (OPENCODE_GO_API_KEY=..., written by the user) and is copied into the VM only.
# Without it the VM's Hermes still lists profiles and sessions, but can't reply.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD

IMAGE=${HERMES_VM_IMAGE:-ghcr.io/cirruslabs/macos-golden-gate-xcode:27}
VM=${HERMES_VM_NAME:-hermesapp-test-vm}
PROFILE=hermesapp-test
PORT=9139
KEY_FILE=.env.vm-hermes
keep=0 ios=0
for arg; do
  case $arg in
    --keep) keep=1 ;;
    --ios) ios=1 ;;
    *) echo "usage: $0 [--keep] [--ios]" >&2; exit 2 ;;
  esac
done
status=0

# 1. The VM: cloned once, 8 cores / 8 GB, headless, the repo shared read-only.
if ! tart list --quiet | grep -qx "$VM"; then
  tart clone "$IMAGE" "$VM"
  tart set "$VM" --cpu 8 --memory 8192
fi
if ! tart list | awk -v vm="$VM" '$2 == vm && $NF == "running"' | grep -q .; then
  nohup tart run "$VM" --no-graphics --dir="hermesapp:$repo:ro" >"${TMPDIR:-/tmp}/hermesapp-vm.log" 2>&1 &
fi
for _ in $(seq 1 90); do tart exec "$VM" true >/dev/null 2>&1 && break; sleep 2; done
vexec() { tart exec "$VM" /bin/zsh -lc "export PATH=\$HOME/.local/bin:\$PATH; $1"; }
trap '((keep)) || tart stop "$VM" >/dev/null 2>&1 || true' EXIT

# 2. The VM's own Hermes: installed once, a hermesapp-test profile on the test model
#    (memory off, as on the Mac), and the model key from $KEY_FILE.
vexec "command -v hermes >/dev/null || curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
    | bash -s -- --non-interactive --skip-browser --skip-computer-use"
vexec "hermes profile list 2>/dev/null | grep -qw $PROFILE || hermes profile create $PROFILE --clone --no-alias >/dev/null
  for kv in model.provider=opencode-go model.default=deepseek-v4.1-flash \
      memory.memory_enabled=false memory.user_profile_enabled=false; do
    hermes -p $PROFILE config set \${kv%%=*} \${kv#*=} >/dev/null
  done"
if [[ -f $KEY_FILE ]] && grep -q '^OPENCODE_GO_API_KEY=.' "$KEY_FILE"; then
  # The key goes through a pipe into the profile's .env (and the default one); it is
  # never echoed, logged or passed on a command line.
  grep '^OPENCODE_GO_API_KEY=' "$KEY_FILE" | head -1 | tart exec -i "$VM" /bin/zsh -lc '
    export PATH=$HOME/.local/bin:$PATH
    IFS= read -r line
    for f in ~/.hermes/.env "$(hermes -p '"$PROFILE"' config env-path)"; do
      mkdir -p "${f:h}"; touch "$f"; chmod 600 "$f"
      { grep -v "^OPENCODE_GO_API_KEY=" "$f" || true; print -r -- "$line"; } >"$f.new" && mv "$f.new" "$f"
    done'
else
  echo "No $KEY_FILE with OPENCODE_GO_API_KEY: the VM's Hermes can't reply, so tests that need a reply will fail or skip."
fi

# 3. Its dashboard on the VM's loopback, with a fresh session token (as live-test.sh
#    does here). launchd keeps it running after this exec returns.
token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
url=http://127.0.0.1:$PORT
vexec "launchctl remove hermesapp.dashboard 2>/dev/null; pkill -f 'hermes dashboard' 2>/dev/null; sleep 1
  launchctl submit -l hermesapp.dashboard -o /tmp/hermesapp-dashboard.log -e /tmp/hermesapp-dashboard.log -- \
    /usr/bin/env PATH=\$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin HERMES_DASHBOARD_SESSION_TOKEN=$token \
    \$(command -v hermes) dashboard --host 127.0.0.1 --port $PORT --no-open --isolated
  for _ in \$(seq 1 90); do curl -fsS -m 2 $url/api/status >/dev/null 2>&1 && exit 0; sleep 2; done
  echo 'The VM dashboard did not start:'; tail -20 /tmp/hermesapp-dashboard.log; exit 1" || exit 1

# 4. A writable copy of the repo in the VM (secrets and build output left out), with
#    an .env.live-local pointing at the VM's dashboard for the live tests.
vexec "rsync -rlpc --delete --exclude .build --exclude DerivedData --exclude '.env*' --exclude Hermes.xcodeproj --exclude Config/Local.xcconfig \
  '/Volumes/My Shared Files/hermesapp/' ~/hermesapp/
  printf 'HERMES_LIVE_URL=%s\nHERMES_LIVE_TOKEN=%s\n' '$url' '$token' >~/hermesapp/.env.live-local"

# 5. Package live tests, then the macOS tests (and with --ios the iOS one). Automation
#    mode is the VM's own setting, not this Mac's.
vexec "cd ~/hermesapp && HERMES_LIVE=1 swift test --package-path Packages/HermesKit --filter LiveGatewayTests -q" || status=1
vexec "sudo automationmodetool enable-automationmode-without-authentication >/dev/null 2>&1 || true
  command -v xcodegen >/dev/null || brew install xcodegen >/dev/null
  cd ~/hermesapp && xcodegen generate --quiet
  export TEST_RUNNER_HERMES_UITEST_URL='$url' TEST_RUNNER_HERMES_UITEST_TOKEN='$token' TEST_RUNNER_HERMES_UITEST_PROFILE=$PROFILE
  rm -rf ~/results && mkdir -p ~/results
  s=0
  xcodebuild test -project Hermes.xcodeproj -scheme HermesMacTests -destination 'platform=macOS' \
    -resultBundlePath ~/results/mac-window.xcresult -quiet || s=1
  xcodebuild test -project Hermes.xcodeproj -scheme HermesMacUITests -destination 'platform=macOS' \
    -resultBundlePath ~/results/mac-ui.xcresult -quiet || s=1
  if (( $ios )); then
    sim=\$(xcrun simctl list devices available | sed -n 's/^ *\\(iPhone [^(]*\\) (.*/\\1/p' | head -1 | sed 's/ *\$//')
    xcodebuild test -project Hermes.xcodeproj -scheme HermesiOSUITests -destination \"platform=iOS Simulator,name=\$sim\" \\
      -resultBundlePath ~/results/ios-ui.xcresult -quiet || s=1
  fi
  for r in ~/results/*.xcresult; do
    printf '%s: ' \"\$(basename \$r .xcresult)\"
    xcrun xcresulttool get test-results summary --path \"\$r\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"result\"], d[\"passedTests\"], \"passed,\", d[\"failedTests\"], \"failed\"); [print(\"  \", f[\"testName\"], \"|\", f[\"failureText\"][:300]) for f in d.get(\"testFailures\", [])]'
  done
  exit \$s" || status=1

# 6. Remove the chats the tests left in the VM's test profile.
vexec "cd ~/hermesapp && HERMES_LIVE=1 HERMES_LIVE_SWEEP=1 swift test --package-path Packages/HermesKit --filter LiveSweepTests -q" || status=1
exit $status
