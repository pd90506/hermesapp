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
#   scripts/vm-test.sh --keep   # leave the VM running afterwards, and keep it for this
#                               #  worktree's next run for 3 minutes (a batch of runs)
#
# While iterating, run only what the change touches; run the whole set once before merge:
#   scripts/vm-test.sh --changed                               # what scripts/vm-test-pick.py
#                                                              #  picks for this branch's changes
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
# Each step's time is printed at the end, with the slowest tests; every test's time goes
# to build/vm-test/durations/<result>.tsv.
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
keep=0 ios=0 only="" tests=() changed=0
usage() { echo "usage: $0 [--keep] [--ios] [--changed | [--only live,window,ui] [--test Scheme/Suite[/test]]...]" >&2; exit 2; }
while (($#)); do
  case $1 in
    --keep) keep=1 ;;
    --ios) ios=1 ;;
    --only) only=${2:?--only needs live, window and/or ui}; shift ;;
    --only=*) only=${1#*=} ;;
    --test) tests+=("${2:?--test needs Scheme/Suite[/test]}"); shift ;;
    --test=*) tests+=("${1#*=}") ;;
    --changed) changed=1 ;;
    *) usage ;;
  esac
  shift
done
# --changed: the tests scripts/vm-test-pick.py picks for what this branch changed.
if ((${changed:-0})); then
  [[ -z $only && ${#tests[@]} -eq 0 ]] || { echo "--changed picks the tests itself: drop --only and --test" >&2; exit 2; }
  scripts/vm-test-pick.py | sed 's/^/  /' >&2
  picked=()
  while IFS= read -r arg; do picked+=("$arg"); done < <(scripts/vm-test-pick.py --args)
  set -- ${picked[@]+"${picked[@]}"}
  while (($#)); do
    case $1 in
      --ios) ios=1 ;;
      --only) only=$2; shift ;;
      --test) tests+=("$2"); shift ;;
    esac
    shift
  done
  if [[ $only == none && ${#tests[@]} -eq 0 ]] && ! ((ios)); then
    echo "Nothing to run in the VM for this change."; exit 0
  fi
fi
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
# The whole set (no --only or --test) is the run right before a merge: it goes first.
full=0
[[ -n $only ]] || { only=live,window,ui; full=1; }
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

dd=$repo/build/vm-test
products=$dd/Build/Products

# One run at a time, in turn. scripts/vm-test-lock.py files this run in the queue now,
# so it keeps its place while it builds, then takes the VM in its turn: first the
# worktree whose last run had --keep (for its next run), then whole-set runs, then the
# others in the order they started (see that script). It holds the kernel's lock
# (flock) on $lockfile until this script ends, however it ends (done, failed, Ctrl-C,
# kill -9), so a run waits only while another live run holds the VM. The
# pid-in-a-directory lock this replaced could be left behind, and a waiter then waited
# on an idle VM.
# Fixed paths, so runs from any worktree or shell (whatever its TMPDIR) share them.
lockfile=/tmp/hermesapp-vm-test.flock
holder_file=/tmp/hermesapp-vm-test.holder
queue=/tmp/hermesapp-vm-test.queue
lease_file=/tmp/hermesapp-vm-test.lease
legacy=/tmp/hermesapp-vm-test.lock
lock_token=$$-$RANDOM$RANDOM
python3 scripts/vm-test-lock.py "$lockfile" "$lock_token" "$queue" "$lease_file" "$repo" "$full" &
watcher=$!
release_vm() {
  [[ $(cat "$legacy/pid" 2>/dev/null) != "$$" ]] || rm -rf "$legacy"
  if [[ -n ${vm_since:-} ]]; then
    rm -f "$holder_file"
    # With --keep (another run follows), this worktree keeps the VM for that run a
    # little while (vm-test-lock.py); without it, the next run in line takes it at once.
    if ((keep)); then
      printf '%s\t%s\t%s\n' "$repo" $(($(date +%s) + ${HERMES_VM_LEASE:-180})) "$batch_since" >"$lease_file.$$" \
        && mv -f "$lease_file.$$" "$lease_file"
    else
      rm -f "$lease_file"
    fi
  fi
  rm -f "$queue/$$.json" "$queue/$$.ready"
  kill -KILL "$watcher" 2>/dev/null || true
}
trap 'remove_products; release_vm' EXIT
trap 'exit 130' INT TERM HUP

# 0. Build the apps and their tests here, before taking the VM: a run waiting for the VM
#    builds meanwhile. One scheme per step, so the step times show them apart.
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

step "wait for the VM"
mkdir -p "$queue" && touch "$queue/$$.ready"
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
    seen="" msg=""  # the VM is free: vm-test-lock.py says whose turn it is
  fi
  [[ $seen == "$shown" ]] || { [[ -z $msg ]] || echo "$msg"; shown=$seen; }
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
# The batch this run belongs to: the same as the last run's, if that came from this
# worktree and left it the VM; vm-test-lock.py caps how long a batch keeps the VM.
batch_since=$vm_since
IFS=$'\t' read -r lrepo luntil lsince 2>/dev/null <"$lease_file" || true
if [[ ${lrepo:-} == "$repo" && ${lsince:-} =~ ^[0-9]+$ ]] && ((vm_since - lsince < ${HERMES_VM_BATCH:-1800})); then
  batch_since=$lsince
fi
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
# The simulator's keyboard preferences, set for the iOS UI tests before it boots
# (`forget`, or `seed` for a run with SendStateUITests) and put back after them (`restore`).
# A typeKey in an iOS UI test is a hardware keyboard to the simulator. It remembers one
# (AutomaticMinimizationEnabled, HardwareKeyboardLastSeen, KeyboardHardwareKeyboardsSeen)
# and from then on keeps its software keyboard below the screen, through reboots, in
# every later run, whichever branch ran the typeKey (VM, 2026-10-20): `forget` and `seed`
# forget it.
# On iOS 26 a globe tap goes to the keyboard used before the current one
# (KeyboardsCurrentAndNext), not along the keyboard list, so SendStateUITests reaches
# Pinyin (in the list) only if it is that one (VM, 2026-10-20). `seed` sets that for the
# run, after a backup (a backup left by a stopped run is kept); `restore` puts the backup
# back, all of it, and checks it is still there 10 s later.
# They shut the simulator down (`forget` only when there is something to forget) and wait
# until it is: `simctl shutdown` can return while
# the simulator still writes its preferences, which overwrote a restore made right after
# it (VM, 2026-10-20).
sim_keyboard() {  # forget | seed | restore
  tart exec -i "$VM" /bin/zsh -s -- "$1" "$sim" <<'ZSH'
mode=$1 u=$2 backup=~/keyboard-preferences.plist
f=~/Library/Developer/CoreSimulator/Devices/$u/data/Library/Preferences/com.apple.keyboard.preferences.plist
[[ -n $u && -f $f ]] || { echo "keyboard preferences ($mode): no simulator $u or no preferences file"; exit 0; }
[[ $mode == restore && ! -f $backup ]] && exit 0
remembered() { plutil -p $f | grep -qE '"(AutomaticMinimizationEnabled|HardwareKeyboardLastSeen|KeyboardHardwareKeyboardsSeen)"'; }
[[ $mode == forget ]] && ! remembered && exit 0
xcrun simctl shutdown $u >/dev/null 2>&1
waited=0
until xcrun simctl list devices | grep -qF "($u) (Shutdown)" && ! pgrep -f "Devices/$u/" >/dev/null; do
  (( waited++ < 60 )) || { echo "keyboard preferences ($mode): $u not shut down after 60 s"; exit 1; }
  sleep 1
done
sleep 2
if [[ $mode != restore ]]; then
  if remembered; then
    for k in AutomaticMinimizationEnabled HardwareKeyboardLastSeen KeyboardHardwareKeyboardsSeen; do plutil -remove $k $f >/dev/null 2>&1; done
    echo 'The simulator remembered a hardware keyboard: forgotten, so its own keyboard shows.'
  fi
  [[ $mode == forget ]] && exit
  if [[ -f $backup ]]; then echo "keyboard preferences: keeping the backup a stopped run left"
  else cp -p $f $backup || { echo "keyboard preferences (seed): no backup, so not seeded"; exit 1; }; fi
  plutil -replace KeyboardsCurrentAndNext -json '["en_US@sw=QWERTY;hw=Automatic", "en_US@sw=QWERTY;hw=Automatic", "zh_Hans-Pinyin@sw=Pinyin-Simplified;hw=Automatic"]' $f
  exit
fi
python3 - $backup $f <<'PY' && rm $backup
import plistlib, sys, time
backup, f = sys.argv[1:]
want = plistlib.load(open(backup, "rb"))
with open(f, "wb") as out:
    plistlib.dump(want, out, fmt=plistlib.FMT_BINARY)
time.sleep(10)
got = plistlib.load(open(f, "rb"))
keys = sorted(k for k in set(want) | set(got) if want.get(k) != got.get(k))
print("keyboard preferences (restore): " + ("back as before the run, still 10 s later" if not keys
      else "NOT restored, changed again: %s (the backup stays in %s)" % (", ".join(keys), backup)))
sys.exit(1 if keys else 0)
PY
ZSH
}
# The iOS simulator boots while other steps run, not in the iOS step: its boot took
# about a minute of every iOS run. `simctl boot` returns once the boot has started;
# the iOS step's xcodebuild waits for the rest. It starts after the window tests, so
# the boot doesn't slow their timing checks, or here, when there are none.
sim=""
boot_sim() {
  ((ios)) && [[ -z $sim ]] || return 0
  sim=$(vexec "xcrun simctl list devices available -j" | python3 -c '
import json, sys
for runtime, devices in sorted(json.load(sys.stdin)["devices"].items(), reverse=True):
    for d in devices:
        if "iOS" in runtime and d["name"].startswith("iPhone"):
            print(d["udid"]); sys.exit()')
  [[ -n $sim ]] || { echo "No iPhone simulator in the VM." >&2; return 1; }
  # Pinyin as the other keyboard only for a run with SendStateUITests or ComposerUITests
  # (both type Pinyin): `seed` and its `restore` each cost the simulator a reboot.
  local filter=$(only_testing HermesiOSUITests)
  if [[ -z $filter || $filter == *SendStateUITests* || $filter == *ComposerUITests* ]]; then sim_keyboard seed || true
  else sim_keyboard forget || true; fi
  vexec "xcrun simctl boot $sim 2>&1 | grep -v 'current state: Booted' || true"
}
runs window || boot_sim || status=1
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
if runs window; then xctest "window tests (run)" HermesMacTests mac-window platform=macOS; boot_sim || status=1; fi
if runs ui; then xctest "macOS UI tests (run)" HermesMacUITests mac-ui platform=macOS; fi
if ((ios)); then
  xctest "iOS UI tests (run)" HermesiOSUITests ios-ui "platform=iOS Simulator,id=$sim"
  sim_keyboard restore || status=1
fi
vexec "for r in ~/results/*.xcresult; do
    [[ -f \$r/Info.plist ]] || { echo \"\$(basename \$r .xcresult): no results (the run did not finish)\"; continue; }
    printf '%s: ' \"\$(basename \$r .xcresult)\"
    xcrun xcresulttool get test-results summary --path \"\$r\" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[\"result\"], d[\"passedTests\"], \"passed,\", d[\"failedTests\"], \"failed\"); [print(\"  \", f[\"testName\"], \"|\", f[\"failureText\"][:300]) for f in d.get(\"testFailures\", [])]'
  done" || true
# Each test's time, from the result bundles: the slowest are printed, and every one goes
# to build/vm-test/durations/<result>.tsv (seconds, result, Suite/test), to see where a
# run's time went.
durations=$dd/durations
rm -rf "$durations" && mkdir -p "$durations"
vexec "cd ~/results && for r in *.xcresult; do
    [[ -f \$r/Info.plist ]] || continue
    print -r -- \"### \${r%.xcresult}\"
    xcrun xcresulttool get test-results tests --path \$r
  done" 2>/dev/null | python3 -c '
import json, os, sys
out, name, chunk = sys.argv[1], None, []
def flush():
    if not name or not chunk:
        return
    rows = []
    def walk(node, suite):
        if node.get("nodeType") == "Test Case":
            rows.append((node.get("durationInSeconds", 0), node.get("result", "?"), suite + "/" + node["name"]))
        for child in node.get("children", []):
            walk(child, node["name"] if node.get("nodeType") == "Test Suite" else suite)
    for node in json.loads("".join(chunk)).get("testNodes", []):
        walk(node, "")
    rows.sort(reverse=True)
    with open(os.path.join(out, name + ".tsv"), "w") as f:
        f.writelines(f"{d:.1f}\t{r}\t{t}\n" for d, r, t in rows)
    print(f"{name}: {len(rows)} tests, {sum(r[0] for r in rows):.0f}s in tests; the slowest:")
    for d, r, t in rows[:8]:
        print(f"  {d:6.1f}s  {t}" + ("" if r == "Passed" else f"  ({r})"))
for line in sys.stdin:
    if line.startswith("### "):
        flush(); name, chunk = line[4:].strip(), []
    else:
        chunk.append(line)
flush()
' "$durations" || true
# Where a slow test's time goes: the steps (activities) of each test over a minute, with
# the second each began, in build/vm-test/durations/<result>.steps.txt.
for tsv in "$durations"/*.tsv; do
  [[ -f $tsv ]] || continue
  result=$(basename "$tsv" .tsv)
  awk -F'\t' '$1 >= 60 { print $3 }' "$tsv" | while IFS= read -r id; do
    printf '### %s\n' "$id"
    vexec "xcrun xcresulttool get test-results activities --path ~/results/$result.xcresult --test-id '$id'" </dev/null 2>/dev/null
  done | python3 -c '
import json, sys
def walk(acts, depth, t0, out):
    for a in acts:
        start = a.get("startTime")
        if start is not None:
            out.append("%7.1fs %s%s" % (start - t0, "  " * depth, a.get("title", "")[:110]))
        if depth < 1:  # deeper are the steps XCUITest takes itself
            walk(a.get("childActivities", []), depth + 1, t0, out)
name, chunk = None, []
def flush():
    if not name or not chunk:
        return
    try:
        runs = json.loads("".join(chunk)).get("testRuns", [])
    except ValueError:
        return
    for run in runs[:1]:
        acts = run.get("activities", [])
        starts = [a["startTime"] for a in acts if "startTime" in a]
        out = []
        walk(acts, 0, min(starts) if starts else 0, out)
        print("### " + name)
        print("\n".join(out))
for line in sys.stdin:
    if line.startswith("### "):
        flush(); name, chunk = line[4:].strip(), []
    else:
        chunk.append(line)
flush()
' >"$durations/$result.steps.txt" || true
done
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
