# AGENTS.md — development rules for hermesapp

These rules apply to every agent and human working in this repo, whether on the NUC (Linux) or
on the Mac.

## What this is

Native SwiftUI clients for macOS 26 and iOS 26 that connect to a self-hosted Hermes Agent
through its **existing** dashboard WebSocket JSON-RPC (`/api/ws`). See `README.md` for the
overview and `docs/protocol.md` for the protocol.

## Hard rules

1. **Linux can build and test only the package.** On the NUC, the only valid verification is:
   ```sh
   swift build --package-path Packages/HermesKit
   swift test  --package-path Packages/HermesKit
   ```
   - UI code (`Apps/`) can be written on Linux, but compiling, running and UI testing happen on
     the Mac.
   - Never report UI code as "working" or "tested" from Linux. Say "unbuilt, needs a Mac check".
2. **Keep logic out of the apps.** Anything that isn't a View goes in `Packages/HermesKit`, with
   tests: protocol types, networking, auth, reconnect, transcript or session state, parsing. App
   code should be a thin SwiftUI layer over `GatewayConnection` / `ChatSession`.
3. **The package must stay Linux-clean:**
   - Foundation only, with `#if canImport(FoundationNetworking) import FoundationNetworking` for
     URLSession types.
   - No SwiftUI, Combine, CryptoKit, Security or Network.framework.
   - Apple-only helpers (Keychain, loopback listener for PKCE) go in `Apps/Shared/`.
4. **No third-party dependencies in the package** without an explicit decision recorded in this
   file. App-target dependencies also need a recorded decision; see [Dependencies](#dependencies).
5. **Don't patch Hermes or add a Hermes gateway platform.**
   - The apps are clients of Hermes's public interfaces.
   - NUC-side helpers go in `backend/` (see its README).
   - Hermes source (`~/.hermes/hermes-agent`) is read-only reference material.
6. **The Xcode project is generated.**
   - Edit `project.yml`, never a `.xcodeproj`, and never commit one.
   - After changing `project.yml` or adding app files, run `python3 scripts/check-project-spec.py`.
     It needs PyYAML (`python3 -m pip install --user pyyaml`, or `apt install python3-yaml`);
     without it the script exits non-zero with that hint.
7. **No secrets or personal hosts in the repo.**
   - Use `hermes.example.ts.net`-style names only in docs and examples.
   - Signing team ids go in the git-ignored `Config/Local.xcconfig`.
8. **Swift 6 language mode, strict concurrency.**
   - UI state is `@MainActor @Observable`.
   - Connection state lives in actors.
   - No `@unchecked Sendable` without a comment explaining why it is safe.
9. **Tools versions.** Keep `swift-tools-version` at or below what the Mac's Xcode ships (6.2
   for Xcode 26). CI tests both 6.2 and the NUC toolchain.

## Dependencies

Every third-party dependency, its license, pin and reason. Add a row here before adding one.

- **SwiftMath** (https://github.com/mgriebling/SwiftMath), MIT, pinned to **exactly 1.7.3**
  in `project.yml`.
  - Used by: the **app targets only** (HermesMac, HermesiOS), to typeset LaTeX in assistant
    messages natively. `Packages/HermesKit` stays dependency-free and Linux-clean.
  - Decided by the user (2026-10). The alternative, WKWebView + KaTeX, was rejected: a web view
    per message is too heavy in a long, streaming, lazily scrolled transcript.
  - Division of work: HermesKit parses Markdown and rewrites LaTeX into the subset SwiftMath
    1.7.3 accepts (`Sources/HermesKit/Markdown/`, see `LaTeXNormalizer`). The apps only typeset
    and lay out (`Apps/Shared/Views/Markdown/`). If SwiftMath still rejects a formula, the app
    shows the LaTeX source.
  - Before bumping the pin: re-probe the parser (`MTMathListBuilder.build(fromString:error:)`)
    against the normalizer's outputs. The rewrite tables assume 1.7.3's command set.

## Protocol work

- `docs/protocol.md` is the contract this repo relies on. Every claim cites a Hermes source path;
  anything inferred is marked `[unverified]`.
- When Hermes updates:
  - Diff `apps/shared/src/gateway-contract.openrpc.json` in the Hermes checkout.
  - Update the types in `Sources/HermesProtocol` and the doc together.
- Decoding must tolerate change:
  - Optional fields by default.
  - Unknown events map to `.unknown`.
  - Unsupported server requests are declined right away:
    - with **`4404`** for the window-owned bridges (`terminal.read`, `preview.read`,
      `preview.act`, `window.read`, `tour`), so a Desktop window sharing the session still
      answers;
    - with `-32601` for everything else.
    - Never use another error code for the bridges: any error other than 4404 is a final answer.
- **Reconnect must re-bind.**
  - Only `session.activate` / `session.resume` / `prompt.submit` re-attach a socket to a session.
  - `session.events.since` only reads the replay ring, and answers an unknown sid with an empty
    success.
  - See `docs/protocol.md` §7 before touching `GatewayConnection` / `GatewayClient.reattach`.
- **Stored keys.** Resume and activate payloads carry the stored key as `session_key`, not
  `stored_session_id`.
  - Use explicit `CodingKeys` rather than a snake-case key strategy, which would mangle
    free-form dictionary keys.
- You may probe the live dashboard read-only, e.g. `GET /api/status`, which is public. Don't
  change Hermes config or restart anything.

## Testing conventions

- Use Swift Testing (`import Testing`, `@Test`, `#expect`).
- Network-facing code is tested through `MessageTransport` / `HTTPClient` fakes
  (`Tests/HermesKitTests/Support/`). Tests never open real sockets.
- **Live tests are the one exception** (decided by the user, 2026-10):
  `Tests/HermesLiveTests` runs against real dashboards, only when `HERMES_LIVE=1`, which
  `scripts/live-test.sh` sets on the Mac. A plain `swift test` and CI skip them.
  - Servers come from git-ignored `.env.live-local` (token, made by the script, which also
    starts a loopback `hermes dashboard` on port 9139 by environment only) and
    `.env.live-remote` (URL, username, password; the user writes it).
  - Everything runs in the `hermesapp-test` profile (`test` is reserved by Hermes), never in a
    real profile. A test that creates a chat deletes it, also when it fails.
- **Automated tests on the Mac run only in the VM** (decided by the user, 2026-10-15). The
  user tries the app on the Mac by hand; agents don't run package live tests, UI tests or
  window tests on the host, start a test dashboard there, or open a build on its screens.
  Building on the host is fine.
  - While iterating on a change, run only the parts it touches (`scripts/vm-test.sh --keep
    --only window`, or `--test HermesMacTests/HoverTests`). Run the whole set once, with no
    `--only`/`--test`, before reporting a PR as ready to merge (decided by the user, 2026-10-16).
  - Run `scripts/vm-test.sh` from the PR's own worktree. It builds the apps and their tests on
    the host (decided by the user, 2026-10-18), streams the built products into the VM, which
    only runs them, and then deletes them from the host. Only one run uses the VM at a time (a
    kernel lock in `/tmp` that goes with its run however the run ends), so a second run, from
    any worktree, waits its turn, naming the run it waits for and that run's step; it builds
    while it waits.
  - A run from another worktree than the last restarts the VM first (decided by the user,
    2026-10-18): leftovers of another thread's run, such as a hung `xcodebuild`, slowed or
    broke the next one.
- **Tests in the VM use a Hermes installed in the VM** (decided by the user, 2026-10).
  - The test VM (`hermesapp-test-vm`, `scripts/vm-test.sh`) is cloned once and keeps its disk
    across runs, so Hermes is installed there once and reused. Window and UI tests in the VM
    connect to that Hermes, in the `hermesapp-test` profile, instead of tunnelling to a
    dashboard on the Mac.
  - The model key is the user's dedicated OpenCode Go test key, in the git-ignored
    `.env.vm-hermes` at the repo root on the Mac (`OPENCODE_GO_API_KEY=…`, mode 600; the
    user writes it). It is copied into the VM's `~/.hermes/.env` and nowhere else. Never put
    it in a commit, a log, a chat message or the host's `~/.hermes`.
  - Without that file, the VM's Hermes still serves profiles and session lists (enough for
    layout checks) but cannot answer messages; tests that need a reply skip.
- Fake server payloads must match what Hermes actually sends, not the contract's optional fields.
  For example, resume payloads have `session_key` and no `stored_session_id`. Cite the Hermes
  source line when adding a fixture shape.
- Async tests that wait on streams use `.timeLimit`. Keep fakes deterministic; poll with
  `eventually {}` only for main-actor UI state.
- Don't name a test target or suite after a type it doesn't exercise.

## Workflow

- `main` is shared between the NUC and the Mac through the private GitHub remote. Keep commits
  small and the package green.
- CI (`.github/workflows/package-tests.yml`) runs only on Linux. macOS runners cost 10x on a
  private repo, so app builds are checked by hand on the Mac.
- **The Mac's main checkout and app builds** (decided by the user, 2026-10-16; PR test builds
  moved to the VM on 2026-10-17, and back to the host, as builds only, on 2026-10-18):
  - The main checkout on the Mac (`~/repo/fun/hermesapp`) stays on local `main`, kept up to
    date with `origin/main`. Don't leave it on a feature branch, don't switch it to a PR branch
    to test it, and don't start new work on a merged branch.
  - Write code on a new branch from the latest `origin/main`, in a separate `git worktree`
    beside the main checkout, not in the main checkout itself.
  - **PR test builds** happen on the host, through `scripts/vm-test.sh` run from the PR's
    worktree (see [Testing conventions](#testing-conventions)): it builds into that worktree's
    git-ignored `build/vm-test`, ships the products to the VM to run, then unregisters
    (`lsregister -u`) and deletes the built apps, keeping only the intermediates for the next
    incremental build. Don't build a PR on the host any other way, and never run or open it
    there.
  - **The host build** happens only in the main checkout, after a merge: pull `main`, build
    with Xcode's default DerivedData (no custom `-derivedDataPath`), and relaunch our Hermes
    app (never the official Hermes Desktop). It never waits on a VM run.
  - Each host build overwrites the last: the host keeps exactly one Hermes.app (bundle id
    `com.example.hermesapp.mac`), the one in that DerivedData. Remove any stray copy (and
    `lsregister -u` it) rather than leaving extra builds around (decided by the user,
    2026-10-16).
  - Only if the user asks to try a PR on the Mac before it merges: check `git status` first
    (never discard uncommitted work), switch the main checkout to the branch, build, and switch
    back to `main` once they have tried it.
- When you finish a task, report: changed paths, the commands you ran and their results, and
  what remains unverified (especially anything that needs the Mac).
