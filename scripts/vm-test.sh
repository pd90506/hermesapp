#!/usr/bin/env bash
# Runs every test without touching this Mac's displays, mouse or keyboard:
# - here: the package live tests and the iOS-simulator UI test (xcodebuild runs the
#   simulator headless; in the VM it was too slow to be usable);
# - in a headless macOS VM (Tart): the macOS window tests and the macOS UI test,
#   which open windows and drive the pointer.
#
#   scripts/vm-test.sh          # everything
#   scripts/vm-test.sh --keep   # leave the VM running afterwards (faster next run)
#
# The VM is a clone of Cirrus Labs' macOS + Xcode image (user admin/admin). It
# reaches this Mac's loopback test dashboard (scripts/live-test.sh) through an
# SSH reverse tunnel, so the dashboard stays bound to 127.0.0.1.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD

IMAGE=${HERMES_VM_IMAGE:-ghcr.io/cirruslabs/macos-golden-gate-xcode:27}
VM=${HERMES_VM_NAME:-hermesapp-test-vm}
keep=0
[[ ${1:-} == --keep ]] && keep=1

# 1. Package live tests and the iOS UI test on this Mac (no windows); this also starts
#    the local test dashboard.
status=0
scripts/live-test.sh --ui || status=1
url=$(sed -n 's/^HERMES_LIVE_URL=//p' .env.live-local)
token=$(sed -n 's/^HERMES_LIVE_TOKEN=//p' .env.live-local)
port=${url##*:}

# 2. The VM: cloned once, 8 cores / 16 GB, headless, the repo shared read-only.
if ! tart list --quiet | grep -qx "$VM"; then
  tart clone "$IMAGE" "$VM"
  tart set "$VM" --cpu 8 --memory 16384
fi
if ! tart list | awk -v vm="$VM" '$2 == vm && $NF == "running"' | grep -q .; then
  nohup tart run "$VM" --no-graphics --dir="hermesapp:$repo:ro" >"${TMPDIR:-/tmp}/hermesapp-vm.log" 2>&1 &
fi
for _ in $(seq 1 90); do tart exec "$VM" true >/dev/null 2>&1 && break; sleep 2; done
vexec() { tart exec "$VM" /bin/zsh -lc "$1"; }

# 3. Let this Mac's SSH key in, then tunnel the VM's 127.0.0.1:$port to ours.
pubkey=$(cat ~/.ssh/id_ed25519.pub)
vexec "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$pubkey' ~/.ssh/authorized_keys 2>/dev/null || echo '$pubkey' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"
ip=$(tart ip --wait 120 "$VM")
for _ in $(seq 1 60); do nc -z -w 2 "$ip" 22 2>/dev/null && break; sleep 2; done  # sshd starts after the agent
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ExitOnForwardFailure=yes -o BatchMode=yes \
  -N -R "$port:127.0.0.1:$port" "admin@$ip" &
tunnel=$!
trap 'kill $tunnel 2>/dev/null || true; ((keep)) || tart stop "$VM" >/dev/null 2>&1 || true' EXIT
sleep 2
vexec "curl -fsS -m 5 http://127.0.0.1:$port/api/status >/dev/null" || { echo "VM cannot reach the dashboard"; exit 1; }

# 4. A writable copy of the repo in the VM (secrets and build output left out).
vexec "rsync -rlpc --delete --exclude .build --exclude DerivedData --exclude '.env*' --exclude Hermes.xcodeproj \
  '/Volumes/My Shared Files/hermesapp/' ~/hermesapp/"

# 5. macOS tests in the VM. Automation mode is the VM's own setting, not this Mac's.
vexec "sudo automationmodetool enable-automationmode-without-authentication >/dev/null 2>&1 || true
  command -v xcodegen >/dev/null || brew install xcodegen >/dev/null
  cd ~/hermesapp && xcodegen generate --quiet
  export TEST_RUNNER_HERMES_UITEST_URL='$url' TEST_RUNNER_HERMES_UITEST_TOKEN='$token' TEST_RUNNER_HERMES_UITEST_PROFILE=hermesapp-test
  rm -rf ~/results && mkdir -p ~/results
  s=0
  xcodebuild test -project Hermes.xcodeproj -scheme HermesMacTests -destination 'platform=macOS' \
    -resultBundlePath ~/results/mac-window.xcresult -quiet || s=1
  xcodebuild test -project Hermes.xcodeproj -scheme HermesMacUITests -destination 'platform=macOS' \
    -resultBundlePath ~/results/mac-ui.xcresult -quiet || s=1
  for r in ~/results/*.xcresult; do
    printf '%s: ' \"\$(basename \$r .xcresult)\"
    xcrun xcresulttool get test-results summary --path \"\$r\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"result\"], d[\"passedTests\"], \"passed,\", d[\"failedTests\"], \"failed\"); [print(\"  \", f[\"testName\"], \"|\", f[\"failureText\"][:300]) for f in d.get(\"testFailures\", [])]'
  done
  exit \$s" || status=1

# 6. Remove the chats the UI tests left in the test profile.
HERMES_LIVE=1 HERMES_LIVE_SWEEP=1 swift test --package-path Packages/HermesKit --filter LiveSweepTests || status=1
exit $status
