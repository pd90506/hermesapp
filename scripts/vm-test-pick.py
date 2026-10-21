#!/usr/bin/env python3
"""Picks the VM tests a change needs, for `scripts/vm-test.sh --changed`.

Reads the files changed since the branch left main (committed, staged, unstaged and
untracked; `--base REF` for another starting point) and maps them to tests:

- vm-test.sh, its helpers, project.yml, Config/ or the package manifest: everything,
  with the iOS tests.
- The package's live tests, or its sources: the package live tests. The app files
  that use a changed package type count as changed too.
- A window test file (Apps/Tests/macOS): its suites. An app file the window tests
  compile (project.yml, HermesMacTests sources): the suites that name a type it
  declares, or else every window suite.
- A UI test file (Apps/UITests): its classes, on the platforms they have tests for.
  An app file (Apps/Shared, Apps/macOS, Apps/iOS): the UI test classes whose string
  literals (accessibility identifiers, labels, launch variables) it also uses, on the
  platforms it is compiled for (`#if os(...)` included).
- Anything else (docs, backend/, the package's unit tests, which CI runs): nothing.

It is a starting point for iterating, not a guarantee: a change that alters what a
UI test sees without sharing a string with it is not picked. The whole set still runs
once before merge.

    scripts/vm-test-pick.py              # explains the pick, ends with the command
    scripts/vm-test-pick.py --args       # one line per vm-test.sh argument (for --changed)
    scripts/vm-test-pick.py --files Apps/Shared/Views/Hover.swift ...   # for these files
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EVERYTHING = ("scripts/vm-test.sh", "scripts/vm-test-pick.py", "scripts/vm-test-lock.py", "project.yml",
              "Packages/HermesKit/Package.swift")
PLATFORMS = ("macOS", "iOS")
# The smoke test per platform: quick, and it launches, connects, sends and gets a reply
# (about 40s on macOS and 30s on iOS in the VM, 2026-10-21).
SMOKE = {"macOS": "MessageActionsUITests/testTheReplysMenuBranchesIntoANewChat",
         "iOS": "LiveChatUITests/testNewChatSendsAndShowsTheReply"}


def git(*args):
    return subprocess.run(["git", "-C", ROOT, *args], check=True, capture_output=True,
                          text=True).stdout


def changed_files(base):
    if base is None:
        try:
            base = git("merge-base", "HEAD", "origin/main").strip()
        except subprocess.CalledProcessError:
            base = git("merge-base", "HEAD", "main").strip()
    files = set(git("diff", "--name-only", base).split("\n"))
    files |= set(git("ls-files", "--others", "--exclude-standard").split("\n"))
    return sorted(f for f in files if f)


def read(path):
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return ""


def swift_files(folder):
    out = []
    for dirpath, _, names in os.walk(os.path.join(ROOT, folder)):
        out += [os.path.relpath(os.path.join(dirpath, n), ROOT) for n in names if n.endswith(".swift")]
    return sorted(out)


def platform_lines(text):
    """For each line, the platforms it is compiled for, from `#if os(...)` blocks."""
    everywhere = set(PLATFORMS)
    stack, out = [], []  # per open #if: [its own condition's platforms, those active now]
    for line in text.split("\n"):
        s = line.strip()
        m = re.match(r"#if\s+(!?)os\((macOS|iOS)\)\s*$", s)
        if m:
            own = {m.group(2)} if not m.group(1) else everywhere - {m.group(2)}
            stack.append([own, own])
        elif s.startswith("#if"):
            stack.append([everywhere, everywhere])
        elif s.startswith("#else") and stack:
            own = stack[-1][0]
            stack[-1][1] = everywhere - own if own != everywhere else everywhere
        elif s.startswith("#endif") and stack:
            stack.pop()
            out.append(active(stack))
            continue
        out.append(active(stack))
    return out


def active(stack):
    platforms = set(PLATFORMS)
    for _, now in stack:
        platforms &= now
    return platforms


def declared_types(text):
    return set(re.findall(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|"
                          r"final|nonisolated)\s+)*(?:struct|class|enum|actor|protocol)\s+(\w+)",
                          text, re.M))


def literals(text, lines=None):
    """String literal pieces (around interpolations), 4+ characters, by platform."""
    out = {p: set() for p in PLATFORMS}
    platforms = platform_lines(text) if lines is None else lines
    for i, line in enumerate(text.split("\n")):
        if line.strip().startswith("//"):
            continue
        for lit in re.findall(r'"((?:[^"\\\n]|\\.)*)"', line):
            for piece in re.split(r"\\\([^)]*\)", lit):
                if len(piece) >= 4:
                    for p in platforms[i]:
                        out[p].add(piece)
    return out


def window_sources():
    """The app files HermesMacTests compiles, from project.yml."""
    spec = read("project.yml")
    block = re.search(r"^  HermesMacTests:\n(.*?)^  \S", spec, re.S | re.M)
    paths = re.findall(r"- path: (\S+)", block.group(1)) if block else []
    return [p for p in paths if not p.startswith("Apps/Tests")]


def window_suites():
    """Window test suites by file: {file: [suite]}."""
    out = {}
    for f in swift_files("Apps/Tests/macOS"):
        out[f] = re.findall(r"^(?:@\w+(?:\([^\n]*\))?\s*)*(?:final\s+)?(?:struct|class)\s+(\w+Tests)\b",
                            read(f), re.M)
    return out


def ui_tests():
    """Every UI test method: class, name, platforms, and the string literals it uses
    (its own, and its class's helpers'), by platform."""
    tests = []
    for f in swift_files("Apps/UITests"):
        text = read(f)
        lines = text.split("\n")
        platforms = platform_lines(text)
        cls, chunks, starts = None, [], []
        for i, line in enumerate(lines):
            m = re.match(r"\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", line)
            if m:
                cls = m.group(1)
            if cls and re.match(r"\s*(?:@\w+\s+)*(?:(?:private|fileprivate|static|override)\s+)*func\s", line):
                starts.append((i, cls, re.match(r"\s*(?:@\w+\s+)*(?:\w+\s+)*func\s+(\w+)", line).group(1)))
        for n, (i, c, name) in enumerate(starts):
            end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
            body = "\n".join(lines[i:end])
            chunks.append((c, name, literals(body, platforms[i:end]), platforms[i]))
        helpers = {}
        for c, name, by_platform, _ in chunks:
            if not name.startswith("test"):
                h = helpers.setdefault(c, {p: set() for p in PLATFORMS})
                for p in PLATFORMS:
                    h[p] |= by_platform[p]
        for c, name, by_platform, where in chunks:
            if name.startswith("test"):
                h = helpers.get(c, {p: set() for p in PLATFORMS})
                size = sum(len(lits) for lits in by_platform.values())
                tests.append({"class": c, "name": name, "file": f, "platforms": set(where), "size": size,
                              "literals": {p: by_platform[p] | h[p] for p in PLATFORMS}})
    return tests


def last_durations():
    """Each UI test's time in the last run, from build/vm-test/durations, if any."""
    out = {}
    for platform, result in (("macOS", "mac-ui"), ("iOS", "ios-ui")):
        try:
            with open(os.path.join(ROOT, "build/vm-test/durations", result + ".tsv")) as f:
                for line in f:
                    seconds, _, test = line.rstrip("\n").split("\t")
                    out[(platform, test.split("(")[0])] = float(seconds)
        except (OSError, ValueError):
            pass
    return out


def app_platforms(path):
    """The platforms a file has code for: its folder's, less any its #if os(...) leaves out."""
    if path.startswith("Apps/macOS/"):
        return {"macOS"}
    if path.startswith("Apps/iOS/"):
        return {"iOS"}
    text = read(path)
    found = set()
    for line, platforms in zip(text.split("\n"), platform_lines(text)):
        s = line.strip()
        if s and not s.startswith(("//", "#", "import ", "@testable import ")):
            found |= platforms
    return found


def pick(files):
    why = []           # (what, because)
    live = False
    window = set()     # suites; "*" for all
    ui = {p: set() for p in PLATFORMS}
    uncovered = []

    if any(f in EVERYTHING or f.startswith("Config/") for f in files):
        hits = [f for f in files if f in EVERYTHING or f.startswith("Config/")]
        return None, [("everything, with --ios", ", ".join(hits))], []

    app_files = [f for f in files if re.match(r"Apps/(Shared|macOS|iOS)/.*\.swift$", f)]
    for f in files:
        if f.startswith("Packages/HermesKit/Tests/HermesLiveTests/"):
            live = True
            why.append(("package live tests", f))
        elif f.startswith("Packages/HermesKit/Sources/") and f.endswith(".swift"):
            live = True
            why.append(("package live tests", f))
            types = declared_types(read(f))
            users = [a for a in swift_files("Apps/Shared") + swift_files("Apps/macOS") + swift_files("Apps/iOS")
                     if types and re.search(r"\b(%s)\b" % "|".join(map(re.escape, types)), read(a))]
            for a in users:
                if a not in app_files:
                    app_files.append(a)
            if users:
                why.append((f"{len(users)} app files that use its types", f))

    suites_by_file = window_suites()
    compiled = window_sources()
    test_texts = {t: read(t) for t in suites_by_file}
    for f in files:
        if f in suites_by_file:
            if suites_by_file[f]:
                window |= set(suites_by_file[f])
                why.append(("window " + ", ".join(suites_by_file[f]), f))
            elif f.endswith(".swift"):
                window.add("*")
                why.append(("every window suite (shared test helper)", f))
    for f in app_files:
        if not any(f == c or f.startswith(c.rstrip("/") + "/") for c in compiled):
            continue
        names = declared_types(read(f))
        found = [s for t, text in test_texts.items() if names and
                 re.search(r"\b(%s)\b" % "|".join(map(re.escape, names)), text)
                 for s in suites_by_file[t]]
        if found:
            window |= set(found)
            why.append(("window " + ", ".join(sorted(set(found))), f + " (its types)"))
        else:
            window.add("*")
            why.append(("every window suite", f + " (compiled into them, named by none)"))

    tests = ui_tests()
    times = last_durations()
    # Literals most UI tests use (the composer, New chat, the launch variables) only say
    # that the app as a whole is involved: they pick a smoke test, not every test.
    common = {}
    for p in PLATFORMS:
        on_p = [t for t in tests if p in t["platforms"]]
        counts = {}
        for t in on_p:
            for lit in t["literals"][p]:
                counts[lit] = counts.get(lit, 0) + 1
        common[p] = {lit for lit, n in counts.items() if n >= 0.4 * len(on_p)}

    def smoke(p):
        on_p = [t for t in tests if p in t["platforms"]]
        named = [t for t in on_p if f"{t['class']}/{t['name']}" == SMOKE[p]]
        if named:
            return named[0]
        # The quickest in the last run, or else the one that does least.
        return min(on_p, key=lambda t: (times.get((p, f"{t['class']}/{t['name']}"), 1e9), t["size"]))

    for f in files:
        if f.startswith("Apps/UITests/") and f.endswith(".swift"):
            for t in tests:
                if t["file"] == f:
                    for p in t["platforms"]:
                        ui[p].add(f"{t['class']}/{t['name']}")
            names = sorted({t["class"] for t in tests if t["file"] == f})
            why.append(("UI " + ", ".join(names), f))
    for f in app_files:
        lits = literals(read(f))
        windowed = any(f == c or f.startswith(c.rstrip("/") + "/") for c in compiled)
        for p in sorted(app_platforms(f)):
            picked, shared_all = [], set()
            for t in tests:
                if p not in t["platforms"]:
                    continue
                specific = (lits[p] & t["literals"][p]) - common[p]
                if specific:
                    picked.append(f"{t['class']}/{t['name']}")
                    shared_all |= specific
            if picked:
                ui[p] |= set(picked)
                why.append((f"UI {p}: {len(picked)} tests", f"{f}: " + ", ".join(sorted(shared_all)[:4])))
            elif not windowed or lits[p] & common[p]:
                t = smoke(p)
                ui[p].add(f"{t['class']}/{t['name']}")
                why.append((f"UI {p}: {t['name']} (smoke)", f"{f} (no UI test names its strings)"))

    reasons = " ".join(because for _, because in why)
    uncovered = [f for f in files if f not in reasons]
    return (live, window, ui), why, uncovered


def arguments(selection):
    if selection is None:
        return ["--ios"]
    live, window, ui = selection
    parts, tests = [], []
    if live:
        parts.append("live")
    if window:
        parts.append("window")
        tests += ["HermesMacTests"] if "*" in window else [f"HermesMacTests/{s}" for s in sorted(window)]
    if ui["macOS"]:
        parts.append("ui")
        tests += [f"HermesMacUITests/{t}" for t in sorted(ui["macOS"])]
    args = []
    if ui["iOS"]:
        args.append("--ios")
        tests += [f"HermesiOSUITests/{t}" for t in sorted(ui["iOS"])]
    args += ["--only", ",".join(parts) or "none"]
    for t in tests:
        args += ["--test", t]
    return args


def main():
    argv = sys.argv[1:]
    base = None
    if "--base" in argv:
        base = argv[argv.index("--base") + 1]
    files = argv[argv.index("--files") + 1:] if "--files" in argv else changed_files(base)
    selection, why, uncovered = pick(files)
    args = arguments(selection)
    if "--args" in argv:
        print("\n".join(args))
        return
    print(f"{len(files)} files changed since the branch left main.")
    for what, because in why:
        print(f"  {what:<44} <- {because}")
    if uncovered:
        print("No VM test picked for: " + ", ".join(uncovered))
    print("\nscripts/vm-test.sh " + " ".join(args))


if __name__ == "__main__":
    main()
