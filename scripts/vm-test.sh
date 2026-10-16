#!/usr/bin/env bash
# Runs the tests in a headless macOS VM (Tart), so nothing runs on this Mac: the
# package live tests, the macOS window tests and the macOS UI test.
#
#   scripts/vm-test.sh          # all of the above
#   scripts/vm-test.sh --ios    # also the iOS-simulator UI test, in the VM (slow)
#   scripts/vm-test.sh --keep   # leave the VM running afterwards (faster next run)
#
# While iterating, run only what the change touches; run the whole set once before merge:
#   scripts/vm-test.sh --only window                           # just the window tests
#   scripts/vm-test.sh --only live,ui                          # suites: live, window, ui
#   scripts/vm-test.sh --test HermesMacTests/HoverTests        # one suite (repeatable;
#   scripts/vm-test.sh --test HermesMacUITests/LiveChatUITests/testTwoServersConnectAndAreNamed
#                                                              #  runs only its scheme)
#
# Only one run uses the VM at a time: a second run waits for the first (it would
# otherwise overwrite the VM's copy of the repo and restart its dashboard mid-run).
# Each step's time is printed at the end.
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
keep=0 ios=0 only="" tests=()
usage() { echo "usage: $0 [--keep] [--ios] [--only live,window,ui] [--test Scheme/Suite[/test]]..." >&2; exit 2; }
while (($#)); do
  case $1 in
    --keep) keep=1 ;;
    --ios) ios=1 ;;
    --only) only=${2:?--only needs live, window and/or ui}; shift ;;
    --only=*) only=${1#*=} ;;
    --test) tests+=("${2:?--test needs Scheme/Suite[/test]}"); shift ;;
    --test=*) tests+=("${1#*=}") ;;
    *) usage ;;
  esac
  shift
done
# Which parts run: everything by default; with --test, only the schemes it names.
if [[ -z $only && ${#tests[@]} -gt 0 ]]; then
  for t in "${tests[@]}"; do
    case ${t%%/*} in
      HermesMacTests) [[ $only == *window* ]] || only+=,window ;;
      HermesMacUITests) [[ $only == *ui* ]] || only+=,ui ;;
      HermesiOSUITests) ios=1 ;;
      *) echo "--test $t: the scheme must be HermesMacTests, HermesMacUITests or HermesiOSUITests" >&2; exit 2 ;;
    esac
  done
  only=${only#,}; [[ -n $only ]] || only=none
fi
[[ -n $only ]] || only=live,window,ui
for part in ${only//,/ }; do
  case $part in live|window|ui|none) ;; *) usage ;; esac
done
runs() { [[ ,$only, == *,$1,* ]]; }
only_testing() {  # -only-testing flags for one scheme, from --test
  local t
  for t in ${tests[@]+"${tests[@]}"}; do [[ ${t%%/*} == "$1" ]] && printf ' -only-testing:%q' "$t"; done
  return 0
}
status=0

# Step timings, printed at the end.
timings="" step_name="" step_start=0
step() {
  local now; now=$(date +%s)
  [[ -n $step_name ]] && timings+=$(printf '\n  %4ss  %s' $((now - step_start)) "$step_name")
  step_name=$1 step_start=$now
}
report_times() { step ""; [[ -n $timings ]] && printf 'vm-test.sh step times (total %ss):%s\n' "$SECONDS" "$timings"; }

# One run at a time: wait for another run's lock (taken over if its process is gone).
lock=${TMPDIR:-/tmp}/hermesapp-vm-test.lock
until mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [[ -n $holder ]] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$lock"; continue
  fi
  [[ -n ${waited:-} ]] || { echo "Another vm-test.sh run (pid ${holder:-?}) is using the VM; waiting for it..."; waited=1; }
  sleep 5
done
echo $$ >"$lock/pid"
trap 'rm -rf "$lock"' EXIT
trap 'exit 130' INT TERM HUP
SECONDS=0

# 1. The VM: cloned once, 8 cores / 8 GB, headless, the repo shared read-only.
step "start the VM"
if ! tart list --quiet | grep -qx "$VM"; then
  tart clone "$IMAGE" "$VM"
  tart set "$VM" --cpu 8 --memory 8192
fi
if ! tart list | awk -v vm="$VM" '$2 == vm && $NF == "running"' | grep -q .; then
  nohup tart run "$VM" --no-graphics --dir="hermesapp:$repo:ro" >"${TMPDIR:-/tmp}/hermesapp-vm.log" 2>&1 &
fi
for _ in $(seq 1 90); do tart exec "$VM" true >/dev/null 2>&1 && break; sleep 2; done
vexec() { tart exec "$VM" /bin/zsh -lc "export PATH=\$HOME/.local/bin:\$PATH; $1"; }
trap '((keep)) || tart stop "$VM" >/dev/null 2>&1 || true; report_times; rm -rf "$lock"' EXIT

# 2. The VM's own Hermes: installed once, a hermesapp-test profile on the test model
#    (memory off, as on the Mac), and the model key from $KEY_FILE.
step "Hermes and its test profile"
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
step "the VM's dashboard"
token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
url=http://127.0.0.1:$PORT
vexec "launchctl remove hermesapp.dashboard 2>/dev/null; pkill -f 'hermes dashboard' 2>/dev/null; sleep 1
  launchctl submit -l hermesapp.dashboard -o /tmp/hermesapp-dashboard.log -e /tmp/hermesapp-dashboard.log -- \
    /usr/bin/env PATH=\$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin HERMES_DASHBOARD_SESSION_TOKEN=$token \
    \$(command -v hermes) dashboard --host 127.0.0.1 --port $PORT --no-open --isolated
  for _ in \$(seq 1 90); do curl -fsS -m 2 $url/api/status >/dev/null 2>&1 && exit 0; sleep 2; done
  echo 'The VM dashboard did not start:'; tail -20 /tmp/hermesapp-dashboard.log; exit 1" || exit 1

# 4. A writable copy of the repo in the VM (git data, secrets and build output left
#    out), with an .env.live-local pointing at the VM's dashboard for the live tests.
#    Times are kept (-t), so unchanged files are skipped by size and time instead of
#    being read on both sides, and the VM's incremental builds see the real changes.
step "copy the repo into the VM"
vexec "rsync -rlpt --delete --exclude .git --exclude .build --exclude DerivedData --exclude '.env*' --exclude Hermes.xcodeproj --exclude Config/Local.xcconfig \
  '/Volumes/My Shared Files/hermesapp/' ~/hermesapp/
  printf 'HERMES_LIVE_URL=%s\nHERMES_LIVE_TOKEN=%s\n' '$url' '$token' >~/hermesapp/.env.live-local"

# 5. Package live tests, then the macOS tests (and with --ios the iOS one). Automation
#    mode is the VM's own setting, not this Mac's.
if runs live; then
  step "package live tests"
  vexec "cd ~/hermesapp && HERMES_LIVE=1 swift test --package-path Packages/HermesKit --filter LiveGatewayTests -q" || status=1
fi
if runs window || runs ui || ((ios)); then
step "build and run the app tests ($only$( ((ios)) && echo ,ios))"
vexec "sudo automationmodetool enable-automationmode-without-authentication >/dev/null 2>&1 || true
  command -v xcodegen >/dev/null || brew install xcodegen >/dev/null
  cd ~/hermesapp && xcodegen generate --quiet --use-cache
  export TEST_RUNNER_HERMES_UITEST_URL='$url' TEST_RUNNER_HERMES_UITEST_TOKEN='$token' TEST_RUNNER_HERMES_UITEST_PROFILE=$PROFILE
  rm -rf ~/results && mkdir -p ~/results
  s=0
  if $(runs window && echo true || echo false); then
    xcodebuild test -project Hermes.xcodeproj -scheme HermesMacTests -destination 'platform=macOS' \
      -resultBundlePath ~/results/mac-window.xcresult -quiet$(only_testing HermesMacTests) || s=1
  fi
  if $(runs ui && echo true || echo false); then
    xcodebuild test -project Hermes.xcodeproj -scheme HermesMacUITests -destination 'platform=macOS' \
      -resultBundlePath ~/results/mac-ui.xcresult -quiet$(only_testing HermesMacUITests) || s=1
  fi
  if (( $ios )); then
    sim=\$(xcrun simctl list devices available | sed -n 's/^ *\\(iPhone [^(]*\\) (.*/\\1/p' | head -1 | sed 's/ *\$//')
    xcodebuild test -project Hermes.xcodeproj -scheme HermesiOSUITests -destination \"platform=iOS Simulator,name=\$sim\" \\
      -resultBundlePath ~/results/ios-ui.xcresult -quiet$(only_testing HermesiOSUITests) || s=1
  fi
  for r in ~/results/*.xcresult; do
    printf '%s: ' \"\$(basename \$r .xcresult)\"
    xcrun xcresulttool get test-results summary --path \"\$r\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"result\"], d[\"passedTests\"], \"passed,\", d[\"failedTests\"], \"failed\"); [print(\"  \", f[\"testName\"], \"|\", f[\"failureText\"][:300]) for f in d.get(\"testFailures\", [])]'
  done
  exit \$s" || status=1
fi

# 6. Remove the chats the tests left in the VM's test profile (only the live and UI
#    tests make any).
if runs live || runs ui || ((ios)); then
step "remove the tests' chats"
vexec "cd ~/hermesapp && HERMES_LIVE=1 HERMES_LIVE_SWEEP=1 swift test --package-path Packages/HermesKit --filter LiveSweepTests -q" || status=1
fi
exit $status
