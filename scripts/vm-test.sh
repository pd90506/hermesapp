#!/usr/bin/env bash
# Runs the tests in a headless macOS VM (Tart), so no test runs on this Mac: the
# package live tests, the macOS window tests and the macOS UI test.
#
# Run it from the checkout or worktree whose code you want tested (a PR's own worktree,
# not the main checkout). The apps and their tests are built here, on this Mac (decided
# by the user, 2026-10-18: the VM's builds were the slow part), before waiting for the
# VM, into build/vm-test in that worktree (git-ignored; its intermediates stay, so the
# next build is incremental). The built products are streamed into the VM, which only
# runs them (test-without-building), and are then deleted here, the Mac app first
# unregistered from Launch Services: the Mac keeps only the main checkout's Hermes.app.
# The worktree's files (tracked and untracked, minus what .gitignore lists) go in too,
# for the package's live tests, which the VM still builds itself (small, and swift test
# can't run a build made elsewhere).
# The tests' screenshots come back to build/vm-test/screenshots, named by test.
#
#   scripts/vm-test.sh          # all of the above
#   scripts/vm-test.sh --ios    # also the iOS-simulator UI test, run in the VM
#   scripts/vm-test.sh --keep   # leave the VM running afterwards (faster next run)
#
# While iterating, run only what the change touches; run the whole set once before merge:
#   scripts/vm-test.sh --only window                           # just the window tests
#   scripts/vm-test.sh --only live,ui                          # suites: live, window, ui
#   scripts/vm-test.sh --test HermesMacTests/HoverTests        # one suite (repeatable;
#   scripts/vm-test.sh --test HermesMacUITests/LiveChatUITests/testEachProfileReturnsToItsLastChat
#                                                              #  runs only its scheme)
#
# Only one run uses the VM at a time, from any worktree: a second run waits for the
# first (it would otherwise overwrite the VM's copy of the repo and restart its
# dashboard mid-run), saying whose run it waits for and which step that run is on. The
# lock goes with its run however the run ends, even kill -9, so a run never waits on
# one that has finished or been killed.
# Each step's time is printed at the end.
#
# scripts/live-test.sh stays for running the live tests on this Mac by hand.
#
# The VM is a clone of Cirrus Labs' macOS + Xcode image (user admin/admin). Its disk
# persists, so it keeps its own Hermes, installed here on the first run: the macOS
# tests run against a dashboard on the VM's own 127.0.0.1, in the hermesapp-test
# profile. The model key comes from the git-ignored .env.vm-hermes
# (OPENCODE_GO_API_KEY=..., written by the user) in this worktree or, failing that, the
# main checkout, and is copied into the VM only.
# Without it the VM's Hermes still lists profiles and sessions, but can't reply.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
# The main checkout (the one holding .git), for the git-ignored key file.
main=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)

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
  note_holder
}
# While this run holds the VM, who it is and what it is doing, for the runs waiting.
note_holder() {
  [[ -n ${vm_since:-} ]] || return 0
  printf '%s\t%s\t%s\t%s\n' $$ "$repo" "$vm_since" "$step_name" >"$holder_file.$$" \
    && mv -f "$holder_file.$$" "$holder_file"
}
report_times() { step ""; [[ -n $timings ]] && printf 'vm-test.sh step times (total %ss):%s\n' "$SECONDS" "$timings"; }

SECONDS=0

# 0. Build the apps and their tests here, before taking the VM: a run waiting for the VM
#    builds meanwhile. One scheme per step, so the step times show them apart.
dd=$repo/build/vm-test
products=$dd/Build/Products
schemes=()
if runs window; then schemes+=(HermesMacTests); fi
if runs ui; then schemes+=(HermesMacUITests); fi
if ((ios)); then schemes+=(HermesiOSUITests); fi
# The built apps leave this Mac with the run, whatever the outcome: unregistered from
# Launch Services, then deleted (the intermediates stay, for the next build).
remove_products() {
  [[ -d $products ]] || return 0
  find "$products" -maxdepth 2 -name '*.app' -type d -exec \
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u {} \; 2>/dev/null || true
  rm -rf "$products"
}
if ((${#schemes[@]})); then
  step "generate the Xcode project (here)"
  xcodegen generate --quiet --use-cache || exit 1
  remove_products
  for scheme in "${schemes[@]}"; do
    step "build $scheme (here)"
    case $scheme in
      HermesiOSUITests) dest="generic/platform=iOS Simulator" arch=(ARCHS=arm64) ;;
      *) dest="platform=macOS,arch=arm64" arch=() ;;
    esac
    xcodebuild build-for-testing -project Hermes.xcodeproj -scheme "$scheme" -destination "$dest" \
      -derivedDataPath "$dd" -quiet ${arch[@]+"${arch[@]}"} || { remove_products; exit 1; }
  done
fi

# One run at a time. The lock is the kernel's (flock) on $lockfile, held by a small
# python3 watcher for as long as this script lives: the kernel drops it the moment the
# watcher ends, and the watcher ends as soon as this script does, however it ends
# (done, failed, Ctrl-C, kill -9). So a run waits only while another live run holds the
# VM. The pid-in-a-directory lock this replaces could be left behind: by a run killed
# before it wrote its pid (never taken over), or with a pid the system had since given
# to another process (pids here come round again within hours), and a waiter then
# waited on an idle VM; two waiters taking over the same stale lock could also delete
# each other's.
step "wait for the VM"
# Fixed paths, so runs from any worktree or shell (whatever its TMPDIR) share them.
lockfile=/tmp/hermesapp-vm-test.flock
holder_file=/tmp/hermesapp-vm-test.holder
legacy=/tmp/hermesapp-vm-test.lock
lock_token=$$-$RANDOM$RANDOM
# It ignores the signals that stop this script, so the lock outlasts the EXIT trap's
# stopping of the VM; the trap then ends it.
python3 -c '
import fcntl, os, signal, sys, time
path, token = sys.argv[1:]
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, signal.SIG_IGN)
script = os.getppid()
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
while True:
    if os.getppid() != script:
        sys.exit()
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        time.sleep(1)
os.ftruncate(fd, 0)
os.write(fd, token.encode())
while os.getppid() == script:
    time.sleep(1)
' "$lockfile" "$lock_token" &
watcher=$!
release_vm() {
  [[ $(cat "$legacy/pid" 2>/dev/null) != "$$" ]] || rm -rf "$legacy"
  [[ -z ${vm_since:-} ]] || rm -f "$holder_file"
  kill -KILL "$watcher" 2>/dev/null || true
}
trap 'remove_products; release_vm' EXIT
trap 'exit 130' INT TERM HUP
shown="" polls=0
until [[ $(cat "$lockfile" 2>/dev/null) == "$lock_token" ]]; do
  kill -0 "$watcher" 2>/dev/null || { echo "The VM lock's watcher (python3) quit." >&2; exit 1; }
  # A free lock takes the watcher a moment to take: say nothing until then.
  ((++polls > 2)) || { sleep 0.5; continue; }
  hpid="" hrepo="" hsince="" hstep=""
  IFS=$'\t' read -r hpid hrepo hsince hstep 2>/dev/null <"$holder_file" || true
  if [[ -n $hpid && $hsince =~ ^[0-9]+$ ]] && kill -0 "$hpid" 2>/dev/null; then
    seen="$hpid $hstep"
    msg="The VM is in use by the vm-test.sh run from ${hrepo##*/} (pid $hpid, on the VM for"
    msg+=" $((($(date +%s) - hsince) / 60)) min, now at: $hstep); waiting for it..."
  else
    seen="?" msg="Another vm-test.sh run is using the VM; waiting for it..."
  fi
  [[ $seen == "$shown" ]] || { echo "$msg"; shown=$seen; }
  sleep 2
done
# Runs from worktrees made before this lock take only the old one, a directory holding
# their pid: wait for such a run, then hold that one too, so they wait for this one.
# Taken over when its pid is no vm-test.sh run (gone, or since given to another
# process), or when it has had no pid for a while. (Drop once no such worktree is left.)
until mkdir "$legacy" 2>/dev/null; do
  holder=$(cat "$legacy/pid" 2>/dev/null || true)
  if [[ -n $holder ]]; then
    ps -o command= -p "$holder" 2>/dev/null | grep -q 'vm-test\.sh' || { rm -rf "$legacy"; continue; }
  elif (($(date +%s) - $(stat -f %m "$legacy" 2>/dev/null || echo 0) > 10)); then
    rm -rf "$legacy"; continue
  fi
  [[ -n ${waited:-} ]] || { echo "An older vm-test.sh run (pid ${holder:-?}) is using the VM; waiting for it..."; waited=1; }
  sleep 5
done
echo $$ >"$legacy/pid"
vm_since=$(date +%s)
note_holder

# 1. The VM: cloned once, headless. No folder is shared: the code is streamed in (step 4).
step "start the VM"
if ! tart list --quiet | grep -qx "$VM"; then
  tart clone "$IMAGE" "$VM"
  tart set "$VM" --cpu 8 --memory 8192
fi
# A fresh VM for each worktree (decided by the user, 2026-10-18): a run from another
# worktree than the last one restarts it, so nothing that run left behind (a hung
# xcodebuild, a stuck simulator) slows or upsets this one. --keep only saves the boot
# between runs from the same worktree.
last=/tmp/hermesapp-vm-test.last
if [[ $(cat "$last" 2>/dev/null) != "$repo" ]] \
    && tart list | awk -v vm="$VM" '$2 == vm && $NF == "running"' | grep -q .; then
  echo "The last run came from another worktree: restarting the VM."
  tart stop "$VM" >/dev/null 2>&1 || true
fi
echo "$repo" >"$last"
if ! tart list | awk -v vm="$VM" '$2 == vm && $NF == "running"' | grep -q .; then
  nohup tart run "$VM" --no-graphics >/tmp/hermesapp-vm.log 2>&1 &
fi
for _ in $(seq 1 90); do tart exec "$VM" true >/dev/null 2>&1 && break; sleep 2; done
vexec() { tart exec "$VM" /bin/zsh -lc "export PATH=\$HOME/.local/bin:\$PATH; $1"; }
trap 'remove_products; ((keep)) || tart stop "$VM" >/dev/null 2>&1 || true; report_times; release_vm' EXIT

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
key_file=$repo/$KEY_FILE
[[ -f $key_file ]] || key_file=$main/$KEY_FILE
if [[ -f $key_file ]] && grep -q '^OPENCODE_GO_API_KEY=.' "$key_file"; then
  # The key goes through a pipe into the profile's .env (and the default one); it is
  # never echoed, logged or passed on a command line.
  grep '^OPENCODE_GO_API_KEY=' "$key_file" | head -1 | tart exec -i "$VM" /bin/zsh -lc '
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

# 4. A writable copy of this worktree in the VM, with an .env.live-local pointing at
#    the VM's dashboard for the live tests. The files git would see (tracked and
#    untracked, minus .gitignore: no .git, build output or .env secrets) go through a
#    tar pipe into a scratch folder in the VM, then into ~/hermesapp by content (-c):
#    tar -m and rsync without -t give a changed file the copy time and leave an
#    unchanged one untouched, so Xcode recompiles exactly what changed, also when the
#    last run came from another branch. The excludes keep what the VM generates itself.
#    COPYFILE_DISABLE stops macOS tar adding ._ files.
step "copy the worktree into the VM"
git ls-files -z --cached --others --exclude-standard \
  | while IFS= read -r -d '' f; do [[ -e $f || -L $f ]] && printf '%s\0' "$f"; done \
  | COPYFILE_DISABLE=1 tar -c -f - --null -T - \
  | tart exec -i "$VM" /bin/zsh -lc "rm -rf ~/hermesapp-incoming && mkdir ~/hermesapp-incoming
    tar -x -m -f - -C ~/hermesapp-incoming || exit 1
    mkdir -p ~/hermesapp
    rsync -rlpc --delete --exclude .git --exclude .build --exclude .swiftpm --exclude DerivedData --exclude '.env*' \
      --exclude Hermes.xcodeproj --exclude Config/Local.xcconfig --exclude Config/Generated \
      ~/hermesapp-incoming/ ~/hermesapp/ || exit 1
    rm -rf ~/hermesapp-incoming
    printf 'HERMES_LIVE_URL=%s\nHERMES_LIVE_TOKEN=%s\n' '$url' '$token' >~/hermesapp/.env.live-local"

# 5. Package live tests, then the macOS tests (and with --ios the iOS one). Automation
#    mode is the VM's own setting, not this Mac's.
if runs live; then
  step "package live tests"
  vexec "cd ~/hermesapp && HERMES_LIVE=1 swift test --package-path Packages/HermesKit --filter LiveGatewayTests -q" || status=1
fi
if ((${#schemes[@]})); then
step "copy the built tests into the VM"
COPYFILE_DISABLE=1 tar -c -f - -C "$products" . \
  | tart exec -i "$VM" /bin/zsh -lc "rm -rf ~/products && mkdir ~/products && tar -x -f - -C ~/products || exit 1
    sudo automationmodetool enable-automationmode-without-authentication >/dev/null 2>&1 || true
    rm -rf ~/results && mkdir -p ~/results" || status=1
remove_products
# Runs a scheme's tests from what was built here (its .xctestrun). No diagnostics on a
# failure: collecting the simulator's took ten minutes and then timed out.
xctest() {  # step name, scheme, result name, destination
  step "$1"
  vexec "cd ~/products
    export TEST_RUNNER_HERMES_UITEST_URL='$url' TEST_RUNNER_HERMES_UITEST_TOKEN='$token' TEST_RUNNER_HERMES_UITEST_PROFILE=$PROFILE
    xcodebuild test-without-building -xctestrun \$(ls ~/products/$2_*.xctestrun | head -1) -destination \"$4\" \
      -resultBundlePath ~/results/$3.xcresult -collect-test-diagnostics never -quiet$(only_testing "$2")" || status=1
}
if runs window; then xctest "window tests (run)" HermesMacTests mac-window platform=macOS; fi
if runs ui; then xctest "macOS UI tests (run)" HermesMacUITests mac-ui platform=macOS; fi
if ((ios)); then
  sim=$(vexec "xcrun simctl list devices available" | sed -n 's/^ *\(iPhone [^(]*\) (.*/\1/p' | head -1 | sed 's/ *$//')
  xctest "iOS UI tests (run)" HermesiOSUITests ios-ui "platform=iOS Simulator,name=$sim"
fi
vexec "for r in ~/results/*.xcresult; do
    [[ -f \$r/Info.plist ]] || { echo \"\$(basename \$r .xcresult): no results (the run did not finish)\"; continue; }
    printf '%s: ' \"\$(basename \$r .xcresult)\"
    xcrun xcresulttool get test-results summary --path \"\$r\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"result\"], d[\"passedTests\"], \"passed,\", d[\"failedTests\"], \"failed\"); [print(\"  \", f[\"testName\"], \"|\", f[\"failureText\"][:300]) for f in d.get(\"testFailures\", [])]'
  done" || true
# The tests' screenshots, out of the VM before the next run clears its results: into
# build/vm-test/screenshots/<result>/, named by the test's attachment names.
step "copy the screenshots out"
shots=$dd/screenshots
rm -rf "$shots" && mkdir -p "$shots"
vexec "rm -rf ~/att && mkdir ~/att && cd ~/results && for r in *.xcresult; do
    xcrun xcresulttool export attachments --path \$r --output-path ~/att/\${r%.xcresult} >/dev/null 2>&1 || true
  done" || true
tart exec "$VM" /bin/zsh -lc 'cd ~/att && tar -cf - .' | tar -C "$shots" -xf - || true
python3 - "$shots" <<'PY' || true
import json, os, re, sys
root = sys.argv[1]
for result in os.listdir(root):
    folder = os.path.join(root, result)
    manifest = os.path.join(folder, "manifest.json")
    if not os.path.isfile(manifest):
        continue
    kept = set()
    for n, test in enumerate(json.load(open(manifest))):
        for a in test.get("attachments", []):
            src = a.get("exportedFileName", "")
            if not src.endswith(".png"):
                continue
            name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", "", a.get("suggestedHumanReadableName", src))
            test_name = test.get("testIdentifier", "").split("/")[-1].removesuffix("()")
            dst = re.sub(r"[/:]", "-", f"{test_name} - {name}.png")
            os.rename(os.path.join(folder, src), os.path.join(folder, dst))
            kept.add(dst)
    for f in os.listdir(folder):
        if f not in kept:
            os.remove(os.path.join(folder, f))
PY
echo "Screenshots: $shots"
fi

# 6. Remove the chats the tests left in the VM's test profile (only the live and UI
#    tests make any).
if runs live || runs ui || ((ios)); then
step "remove the tests' chats"
vexec "cd ~/hermesapp && HERMES_LIVE=1 HERMES_LIVE_SWEEP=1 swift test --package-path Packages/HermesKit --filter LiveSweepTests -q" || status=1
fi
exit $status
