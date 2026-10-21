#!/usr/bin/env python3
"""Takes the test VM for one scripts/vm-test.sh run, in its turn, and holds it.

vm-test.sh starts this in the background when it starts, and it stays until the run
ends. It files the run's ticket in the queue folder at once, so the run keeps its
place in line while it builds. Once the run has built (vm-test.sh then creates
<ticket>.ready), it takes the VM when it is that run's turn:

1. A worktree whose last run ended with --keep (more runs to come) keeps the VM for
   its next run (decided by the user, 2026-10-21: runs from different worktrees
   taking turns block each other, and each switch restarts the VM). It keeps it while
   that run is on its way (building or waiting) or for LEASE seconds after the last
   one ended, but no longer than BATCH seconds from when it took the VM, while other
   runs wait. vm-test.sh writes that lease when a --keep run ends.
2. Then whole-set runs, the ones right before a merge.
3. Then the others, in the order they started.

The lock itself is the kernel's (flock on the lock file), held for as long as this
process lives: the kernel drops it the moment it ends, and it ends as soon as the
run does, however it ends (done, failed, Ctrl-C, kill -9), so a run waits only while
another live run holds the VM. It ignores the signals that stop the run, so the lock
outlasts the EXIT trap's stopping of the VM; the trap then ends it.

Runs whose vm-test.sh predates the queue take the flock when it is free; the queue
only orders the runs that file tickets.

    vm-test-lock.py LOCKFILE TOKEN QUEUE_DIR LEASE_FILE REPO FULL(0|1)
"""
import fcntl
import json
import os
import signal
import subprocess
import sys
import time

LEASE = int(os.environ.get("HERMES_VM_LEASE", 180))
BATCH = int(os.environ.get("HERMES_VM_BATCH", 30 * 60))


def run_is_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    # pids come round again within hours here: it must still be a vm-test.sh run.
    command = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                             capture_output=True, text=True).stdout
    return "vm-test" in command


def tickets(folder):
    out = []
    for name in os.listdir(folder):
        if not name.endswith(".json"):
            continue
        path = os.path.join(folder, name)
        try:
            with open(path) as f:
                t = json.load(f)
        except (OSError, ValueError):
            continue
        if not run_is_alive(t["pid"]):
            for leftover in (path, path[:-5] + ".ready"):
                try:
                    os.remove(leftover)
                except OSError:
                    pass
            continue
        t["ready"] = os.path.exists(path[:-5] + ".ready")
        out.append(t)
    return out


def read_lease(path):
    try:
        with open(path) as f:
            repo, until, since = f.read().rstrip("\n").split("\t")
        return {"repo": repo, "until": float(until), "since": float(since)}
    except (OSError, ValueError):
        return None


def turn(me, folder, lease_path):
    """(may take the VM now, why not)."""
    now = time.time()
    queue = tickets(folder)
    lease = read_lease(lease_path)
    if lease and now - lease["since"] >= BATCH:
        lease = None
    if lease:
        # Its next run counts if it started before the lease ran out.
        coming = any(t["repo"] == lease["repo"] and t["since"] < lease["until"] for t in queue)
        if not coming and now >= lease["until"]:
            lease = None
    if lease and lease["repo"] != me["repo"]:
        return False, (f"Keeping the VM for the next run from {os.path.basename(lease['repo'])}, "
                       "which just had it; waiting...")
    ready = [t for t in queue if t["ready"]]
    if not any(t["pid"] == me["pid"] for t in ready):
        ready.append(dict(me, ready=True))

    def order(t):
        return (0 if lease and t["repo"] == lease["repo"] else 1, 0 if t["full"] else 1, t["since"], t["pid"])
    ahead = sorted(ready, key=order)
    place = next(i for i, t in enumerate(ahead) if t["pid"] == me["pid"])
    if place == 0:
        return True, ""
    first = ahead[0]
    return False, (f"{place} run(s) go first (whole-set runs before others, then by start); "
                   f"next: {os.path.basename(first['repo'])} (pid {first['pid']}); waiting...")


def main():
    lockfile, token, folder, lease_path, repo, full = sys.argv[1:]
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, signal.SIG_IGN)
    script = os.getppid()
    os.makedirs(folder, mode=0o777, exist_ok=True)
    me = {"pid": script, "repo": repo, "full": full == "1", "since": time.time()}
    ticket = os.path.join(folder, f"{script}.json")
    with open(ticket + ".new", "w") as f:
        json.dump(me, f)
    os.replace(ticket + ".new", ticket)

    fd = os.open(lockfile, os.O_RDWR | os.O_CREAT, 0o666)
    said = ""
    while True:
        if os.getppid() != script:
            sys.exit()
        if os.path.exists(os.path.join(folder, f"{script}.ready")):
            mine, why = turn(me, folder, lease_path)
            if mine:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    pass
            elif why != said:
                print(why, flush=True)
                said = why
        time.sleep(1)
    os.ftruncate(fd, 0)
    os.write(fd, token.encode())
    while os.getppid() == script:
        time.sleep(1)


if __name__ == "__main__":
    main()
