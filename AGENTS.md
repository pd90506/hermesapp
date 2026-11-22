# AGENTS.md — development rules for hermesapp

These rules apply to every agent and human working in this repo, whether on the NUC (Linux) or
on the Mac.

## What this is

Clients for a self-hosted Hermes Agent that connect through its **existing** dashboard
WebSocket JSON-RPC (`/api/ws`): Talaria Desktop, one Electron + React app for Windows and
macOS (see [Electron desktop app](#electron-desktop-app)), and SwiftUI apps for iOS 26 and
macOS 26 (the SwiftUI Mac app gets bug fixes only; new desktop work goes to Electron). See `README.md` for the
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
   - **Each host checks only its own platform** (decided by the user, 2026-11-16). On the
     Windows PC, the package must build and pass its tests on Windows; see
     [Windows host](#windows-host). The Mac and the NUC don't need to check Windows, and the
     Windows PC doesn't check macOS or iOS.
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
    and lay out (`Apps/Shared/Views/Markdown/`). The apps also register the symbol commands
    SwiftMath lacks (`LaTeXNormalizer.addedSymbols`, from KaTeX's table). A command SwiftMath
    still rejects is shown as source inside the rendered formula; any other parse error makes
    the app show the whole formula's LaTeX source.
  - SwiftMath silently drops non-ASCII characters in math mode, so the normalizer must emit
    commands, never Unicode symbols.
  - Before bumping the pin: re-probe the parser (`MTMathListBuilder.build(fromString:error:)`)
    against the normalizer's outputs. The rewrite tables assume 1.7.3's command set.

- **Sparkle** (https://github.com/sparkle-project/Sparkle), MIT, pinned to **exactly 2.10.1**
  in `project.yml`.
  - Used by: **HermesMac only**, for in-app updates from the GitHub releases that
    `scripts/release-mac.sh` publishes (`Apps/macOS/Updater.swift`). iOS has no equivalent.
  - Decided by the user (2026-10), over a hand-written GitHub updater: replacing and relaunching a
    running app safely is what Sparkle already does well.
  - Updates are verified twice: the EdDSA signature in the appcast (the private key lives in the
    release Mac's login keychain) and the app's code signature (the same team as the running app).
  - Off in Debug builds and when `HERMES_UPDATE_FEED_URL` or `HERMES_UPDATE_PUBLIC_KEY` is unset.

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
  - While iterating on a change, run only the tests it needs (decided by the user, 2026-10-21;
    a full run with `--ios` takes about 45 minutes on the Mac, nearly all of it in the
    UI tests):
    - `scripts/vm-test.sh --changed` picks them from the files the branch changed
      (`scripts/vm-test-pick.py`, which prints its reasons; run it alone to see the pick).
      It maps window test files and the app files the window tests compile to their
      suites, and app files to the UI tests that share a string with them (identifiers,
      labels), or else to one quick smoke test per platform. A change to the test scripts,
      `project.yml`, `Config/` or the package manifest runs every step once (live, window,
      a smoke UI test each), not every test; one to comments only runs nothing (decided by
      the user, 2026-10-27).
    - The pick is a starting point: add or narrow by hand with `--only window` or
      `--test HermesMacTests/HoverTests` when you know better.
  - Run the whole set (no `--only`/`--test`/`--changed`, and `--ios` when the change can
    affect iOS) only when the user asks for it, not as a step before every merge (decided
    by the user, 2026-10-27, replacing the rule of 2026-10-16 and 2026-10-21). When a
    change is tightly coupled to other parts of the app, suggest a full run to the user
    and let them decide.
  - The slow window tests (`SLOW_WINDOW_TESTS` in `scripts/vm-test-pick.py`: speed and
    layout-churn checks, about a minute each) are skipped unless a `--test` names their
    suite, `--changed` picks them, or `--slow` is given; the whole set skips them too
    (decided by the user, 2026-10-27).
  - Each run ends with its step times and its slowest tests; every test's time is kept in
    `build/vm-test/durations/<result>.tsv`.
  - Run `scripts/vm-test.sh` from the PR's own worktree. It builds the apps and their tests on
    the host (decided by the user, 2026-10-18), streams the built products into the VM, which
    only runs them, and then deletes them from the host. Only one run uses the VM at a time (a
    kernel lock in `/tmp` that goes with its run however the run ends), so a second run, from
    any worktree, waits its turn, naming the run it waits for and that run's step; it builds
    while it waits.
  - Runs queue by priority (decided by the user, 2026-10-21: runs from different worktrees
    taking turns blocked each other): a worktree whose last run had `--keep` keeps the VM
    for its next run (while it builds, or for 3 minutes, and for at most 30 minutes in
    all while others wait); then whole-set runs; then the others, in the order they
    started (`scripts/vm-test-lock.py`). So pass `--keep` when another run of the same
    batch follows, and leave it off the last one.
  - A run from another worktree than the last restarts the VM first (decided by the user,
    2026-10-18): leftovers of another thread's run, such as a hung `xcodebuild`, slowed or
    broke the next one.
- **Tests in the VM use a Hermes installed in the VM** (decided by the user, 2026-10).
  - The test VM (`hermesapp-test-vm`, `scripts/vm-test.sh`) is cloned once and keeps its disk
    across runs, so Hermes is installed there once and reused. Window and UI tests in the VM
    connect to that Hermes, in the `hermesapp-test` profile, instead of tunnelling to a
    dashboard on the Mac.
  - The test model is served by the user's CLIProxyAPI endpoint, the same one the Windows
    test VM uses. The git-ignored `.env` at the repo root on the Mac names it (the user
    writes it): `CLIPROXYAPI_BASE_URL` (e.g. `https://hermes.example.ts.net:8317/v1`),
    `CLIPROXYAPI_KEY` and, optionally, `CLIPROXYAPI_MODEL` (default `claude-haiku-5-5`).
    The script points the test profile at it as a named provider, `cliproxy`, and pipes the
    key into the VM's `~/.hermes/.env` and the profile's `.env`, nowhere else. Never put the
    key in a commit, a log, a chat message or the host's `~/.hermes`.
  - Without those settings, the VM's Hermes still serves profiles and session lists (enough
    for layout checks) but cannot answer messages; tests that need a reply skip.
- Fake server payloads must match what Hermes actually sends, not the contract's optional fields.
  For example, resume payloads have `session_key` and no `stored_session_id`. Cite the Hermes
  source line when adding a fixture shape.
- Async tests that wait on streams use `.timeLimit`. Keep fakes deterministic; poll with
  `eventually {}` only for main-actor UI state.
- Don't name a test target or suite after a type it doesn't exercise.

- **The Electron desktop app's npm packages** (`Apps/Desktop/electron`, `Packages/hermes-core`),
  pinned exactly in their `package.json` files and `pnpm-lock.yaml` (pnpm 10.28.0, Node 22.12
  or newer). Decided by the user (2026-11-19: "还是得用electron。能借鉴的比较多"), for Windows and
  macOS together.
  - Runtime, bundled into the app: **electron** 44.10.2 (MIT), **react** / **react-dom**
    19.3.0 (MIT), **ws** 8.22.1 (MIT). `ws` was not in the approved plan: the main process
    opens the gateway WebSocket with it because it sends no `Origin` (the dashboard checks a
    browser's) and reports a refused upgrade with its HTTP status, which the app shows. Its
    optional native add-ons stay out. **@tanstack/react-virtual** 3.14.26 (MIT), for the chat's
    transcript list (package A, in the approved plan): it builds only the rows near the screen
    and measures their heights, as the Mac's lazy transcript and Desktop's virtual list do.
  - Build and test only: **vite** 8.3.4, **@vitejs/plugin-react** 6.2.1, **typescript** 6.0.3,
    **vitest** 4.1.12, **jsdom** 29.1.1, **@testing-library/react** 16.3.3,
    **electron-builder** 26.18.0, and the `@types` packages (all MIT, Apache-2.0 for
    TypeScript).
  - Markdown in messages (work package B, `features/markdown`), bundled into the renderer:
    **streamdown** 2.7.0 (Apache-2.0) with **@streamdown/math** 1.0.3 (Apache-2.0),
    **shiki** 4.5.0 (MIT) and **katex** 0.19.0 (MIT). The same renderer and pins as the
    official Hermes Desktop (`apps/desktop/package.json`), named in the approved plan.
    Streamdown re-renders only the block that changed while a reply streams; Shiki runs on
    its JavaScript regex engine (the page's CSP allows no WebAssembly) and loads itself and
    each language on first use. Streamdown's Tailwind-styled defaults are all replaced by
    our own components and CSS Modules; its controls, link-safety dialog and URL hardening
    are off (links open only through `talaria.links`, checked in the main process).
  - `Packages/hermes-core` has no runtime dependency: no DOM, no Node, so it runs in the
    renderer, in the main process and in vitest alike.
  - pnpm runs install scripts only for `electron` (its binary download); see `pnpm` in the root
    `package.json`.

## Electron desktop app

The desktop app for Windows and macOS is Electron (decided by the user, 2026-11-19;
the plan is in `docs/desktop-electron.md`). One renderer serves both; the SwiftUI Mac app
gets bug fixes only. The Flutter Windows app was removed (the user, 2026-11-19:
"Flutter版不需要了，归档删除"); its last state is on the `archive/flutter-desktop` branch.

- **Layout.** `Packages/hermes-core` is the protocol and connection logic in TypeScript (a port
  of `HermesKit`'s, behaviour for behaviour). `Apps/Desktop/electron` is the app: `src/main`
  (window, HTTP, WebSockets, settings, secrets), `src/preload` (the `window.talaria` bridge),
  `src/renderer` (React views only).
- **Shared fixtures.** `Packages/fixtures/*.json` are read by both `SharedFixtureTests.swift`
  and `hermes-core`'s vitest suite: a behaviour both ports implement gets a fixture there.
- **Platform differences live in the main process and in CSS.** The preload sets
  `<html data-platform>` and the frame's `--frame-*` variables; the renderer never checks the
  platform in code (`tests/stylesheet-scan.test.ts` fails if it does).
- **Styles use tokens only.** Raw colours and pixel sizes live in `src/renderer/theme/*.css`;
  a `*.module.css` that writes one fails the stylesheet scan.
- **Positions and behaviour follow the Mac app** on both platforms; each platform keeps its
  own system font, sizes and selection look (`theme/platform.css`).
- **Network in the main process.** The renderer never fetches: HTTP (Node's fetch, with a
  cookie jar) and WebSockets (`ws`) go through IPC, so there is no `Origin` and no CORS.
- **Check a change** with `pnpm install`, `pnpm typecheck`, `pnpm test` at the repo root, then
  `pnpm desktop:build`. Run it with `pnpm desktop:dev`. On Windows, build the app with
  `scripts/windows/Build-Electron.ps1`.
- Settings are kept in the app's own data folder, `Talaria Desktop`, each server's secret encrypted with Electron's `safeStorage` (DPAPI on Windows,
  the keychain on macOS) in `secrets/<server id>.bin`.
- **Servers.** `hermes-core`'s `ServerRegistry` holds one `GatewayConnection` per server, as the Mac's
  `ServerConnection`. `model.connection` is the current server's (the server of the profile picked in
  the rail); views read it with `useConnection()` / `useConnectionSnapshot()`, which follow a change of
  server. Something tied to one server (a chat) keeps that server's id and uses `model.serverConnection(id)`.
- **One UI on macOS and Windows.** The Electron app looks and behaves the same on both, in an
  Electron/web style after official Hermes Desktop, not the Mac SwiftUI app's layout (user, 2026-11-19).
- **Settings** (`features/settings`) is an overlay over the main window, as Hermes Desktop's: panes listed
  on the left, the one picked beside them, Esc / the close button / a click outside closes it. ⌘, (Mac app
  menu) or Ctrl+, opens it (`src/main/ipc/settings-window.ts`). A pane registers itself in
  `features/settings/registered.ts` (`registerSettingsPane`) and is built from `features/settings/ui/Rows.tsx`
  (PageHeading, ListRow, ToggleRow, Switch, TextField, Select, Button, Pill).

## Why XcodeGen

A hand-maintained `.xcodeproj` can't be edited sensibly on Linux and causes merge conflicts.

- **XcodeGen** keeps the whole project in one short YAML file (`project.yml`):
  - The generated project and Info.plists are ignored by git.
  - Any host, or an agent, can edit the YAML.
  - It's a single Homebrew binary with no Swift manifest to compile.
  - It's mature and handles local Swift packages, multi-platform targets, entitlements and xcconfigs.
- **Tuist** needs its own CLI and a Swift-DSL manifest that also only evaluates on macOS, which
  is more machinery for two targets.
- **Xcode 16+ synchronized folders** reduce `project.pbxproj` churn, but the pbxproj is still a
  committed, hand-merged artefact.

Linux can't run XcodeGen or Xcode, so `scripts/check-project-spec.py` checks
the spec statically (YAML parses, paths exist, local package products exist, remote packages use
HTTPS and pin a version, every app Swift file belongs to a target). The real check is
`xcodegen generate` and an Xcode build on the Mac.

## Known limitations of the Apple apps: implementation notes

The README lists these for users; the details for whoever works on them:

- **Voice input** is not available yet (`docs/protocol.md` §10.4).
- The "Access token (ticket)" mode takes an access token only, which can't be refreshed.
  `basic` access tokens last 12 h, so re-enter the token after that, or use "Sign in with
  browser", whose pair renews itself.
- **Clarify multi-select.** The UI still presents `multi_select` as a single-choice Picker,
  although the package models it (`ClarifySelection`).
- **Slash-command UI.** The composer calls `ChatComposer.submitSlash()` for drafts starting with
  `/`, and the package handles server-side commands and supported client actions. `/new`,
  `/reset` and `/clear` create a chat outside a Bot Chat (inside it, they compress instead);
  `/help` lists commands; `/model` and `/reasoning` change the chat's choices. `/resume` opens a
  matching session only when its ID is already in History. Other Desktop client-side actions
  such as `/branch` and `/skin` have no slash UI here yet; the app shows a local note instead of
  sending them as prompts. Forking a session is available from its row or message action menu.
  `/profile` cannot switch the profile of a new chat from the composer.
- **Local rows.** Slash-command output, notices and `/btw` / `/bg` answers exist on this device
  only (Hermes never stores them; Desktop loses them on reload too). They keep their place while
  the stored transcript is re-read, but a cold resume (reconnect to a restarted backend, a
  reclaimed chat) drops them, and a row added mid-turn moves below that turn.
- **Reasoning.** Only `reasoning.delta` and `reasoning.available` fill a reply's reasoning, as in
  Desktop; `thinking.delta` frames are spinner text (an explained provider wait shows as
  `Transcript.providerWait`). A prompt, steer, note or `/btw` row added while a reply streams
  splits the reply into two bubbles around it (Desktop's `appendAfterActiveReply`).
- **Rename.** Only a chat open in the app (on screen or recently shown) can be renamed: the
  package uses `session.title`, which needs a live session. Desktop renames other rows over the
  dashboard REST API, which the package doesn't use.
- **Archive.** Archived chats can't be listed (`session.list` has no archived filter), so unarchive
  is only an undo for a row the app still holds.
- **Deleting a chat open elsewhere.** A chat open in another client (e.g. a Desktop window) can't
  be deleted: the gateway answers 4023 until that client closes it.
- **Stored tool rows** show no output, except for `write_file`, `patch` and `skill_manage`, as in
  the gateway's own history projection; live tool rows carry their output.
- **Files.** A file is uploaded when it is attached; removing its card does not delete it from the
  gateway (there is no call for that). Files travel inside one WebSocket frame as base64, about a
  third larger than the file, and the app refuses files over 50 MB (Hermes' PDF cap). The gateway
  itself takes frames up to 384 MiB (16 MiB on gateways older than desktop contract v5), and
  Desktop allows 256 MiB per file; see `docs/protocol.md` §10.5.
- **Reclaimed chats.** When the backend reclaims an idle chat, the chat stays on screen and is
  resumed by its next action or when it is shown again; until then nothing streams into it.
- **Live updates.** `sessions.changed` refreshes the lists at most every 10 s, and the roster also
  keeps its 15 s poll: Hermes has no roster-change event.
- Requests for sessions other than the open one show only as a badge (and on the bot's row when
  this app opened that session).
- **Profiles.** The app only lists bots and opens or creates their Bot Chats. It does not create,
  rename or delete profiles, and it does not run Desktop's sweep that re-hides Bot Chats. Bot
  Chats can't be renamed, archived or deleted from the app; the server itself only refuses the
  rename.
- Math the SwiftMath parser can't handle, even after rewriting (e.g. `\cancel`, `\&`,
  `\mathop`), shows as LaTeX source. Some rewrites are approximations: `\boxed` drops the box,
  `\underbrace`/`\overbrace` become under/overlines, `\overset` becomes a superscript. `\color`
  is ignored because math takes the text color.
- Prose selection works within one paragraph, list item or cell, not across blocks. Math images
  aren't selectable; use "Copy LaTeX" from the context menu.
- Markdown edge cases, by design: a display-math opener with no closer is plain text once the
  reply finishes (while streaming it shows as source); quotes and lists nest at most 16 deep and
  emphasis 32 deep, deeper markers stay text; a `$…$` span in a table cell keeps its pipes, so
  `| $a | b$ |` is one cell; `$` + capitals + `/` or `:` (`$HOME/`) is read as a shell variable.
- Rendering: every streamed delta re-parses the reply and re-evaluates its block views; the math
  image cache is bounded by count (500), not bytes; math in the reasoning pane is sized for body
  text although reasoning uses the callout font.
- A `-32601` from this app can beat a Desktop window's answer to `vault.*` prompts when both are
  attached to the same session (see `docs/protocol.md` §6).

## Windows host

The Windows PC develops the Windows side of the Electron desktop app and checks `HermesKit`. These
rules apply only there (decided by the user, 2026-11-16); the Mac and the NUC don't check
Windows, and CI doesn't run on Windows.

- **Verification** on Windows is the package build and tests, as on Linux:
  ```sh
  swift build --package-path Packages/HermesKit --build-tests
  swift test  --package-path Packages/HermesKit
  ```
  - Toolchain: Swift from swift.org (`winget install Swift.Toolchain`) and Visual Studio Build
    Tools with the C++ workload and a Windows SDK. A shell that predates the install needs
    `vcvars64.bat` run and `SDKROOT` set to the toolchain's `Windows.sdk` before `swift` works.
  - Platform code in the package or its tests uses `#if os(Windows)` / `canImport(WinSDK)`
    beside the Glibc and Darwin branches, never in place of them.
  - Keep build output out of long paths: some Windows tools still fail on paths over 260
    characters.
- **UI tests run in a headless Hyper-V VM** (decided by the user, 2026-11-16), never on
  the host's screen. The VM is `TalariaTest`, in `C:\VMs\TalariaTest`: Windows 11 Pro, not
  activated, auto-logon as a local test account. Its name and account are in the
  git-ignored `.env` (`TALARIA_TEST_VM_*`).
  - `scripts/windows-test-vm/New-TestVM.ps1` builds it from a Windows 11 ISO with an
    unattended install. Your account must be in "Hyper-V Administrators".
  - Drive it with PowerShell Direct (`Invoke-Command -VMName TalariaTest -Credential ...`).
  - Every PR that changes the Windows UI carries screenshots taken in the VM: the app's
    window with `Invoke-AppInVM.ps1` (true colour, from the user's session in the VM), the
    whole screen with `Get-VMScreenshot.ps1` (Hyper-V's thumbnail, RGB565, no window opened).
  - Checkpoint `clean-install` is the freshly installed system; restore it
    (`Restore-VMSnapshot`) when a run leaves the VM in a bad state.
- **Tests that need a Hermes run in WSL**, not on Windows itself: Hermes is installed in an
  Ubuntu WSL distro, uses the `hermesapp-test` profile there, and serves the dashboard on
  loopback, which Windows reaches as `127.0.0.1`. Keep everything for it inside the WSL distro.
  - The UI-test VM can't reach that loopback, so it has a Hermes of its own, as the Mac's test
    VM does: the official Windows install, the same profile, and a dashboard on the VM's
    loopback started at logon (`scripts/windows-test-vm/Install-TestHermes.ps1`).
  - The model key lives in the git-ignored `.env` at the repo root (the user writes it). It is
    copied into the test profile's `.env` in WSL (mode 600) and in the UI-test VM, and nowhere
    else (decided by the user, 2026-11-16: every test VM gets it). Never put it in a commit, a
    log or a chat message.
- **WebSockets on Windows use WinHTTP** (decided by the user, 2026-11-16). There,
  swift-corelibs-foundation's `URLSessionWebSocketTask` delivers a message longer than about
  4 KB as several separate messages (Swift 6.4.2: a 5000-byte frame arrives as 4084 + 916), and
  Hermes frames are often longer. So `platformWebSocket` (the `DashboardConnector` default)
  picks `WinHTTPWebSocketTransport` on Windows and `URLSessionWebSocketTransport` elsewhere.
  WinHTTP comes from the `CWinHTTP` system-library target, a header module of the Windows
  SDK used only on Windows; it is not a third-party dependency.
- **The desktop app** is the Electron app (see "Electron desktop app" above).
  - Build it with `scripts/windows/Build-Electron.ps1`.
  - **After every merge, reinstall it on the Windows PC** (decided by the user, 2026-11-17):
    pull `main` in the main checkout, build, and replace the copy in
    `%LOCALAPPDATA%\Programs\Talaria Desktop` (Start menu: Talaria Desktop), keeping the
    user's settings and sign-in; delete the build outputs (`dist`, `out`). Don't start the app.
  - Run it and take its screenshots in the VM with `scripts/windows-test-vm/Invoke-AppInVM.ps1`
    (`-Fresh` for the first-run page). The VM has no GPU, so Mica shows as its solid fallback
    there; say so when sending screenshots.

## Workflow

- `main` is shared between the NUC and the Mac through the public GitHub remote. Keep commits
  small and the package green.
- CI (`.github/workflows/package-tests.yml`) runs only on Linux, so app builds are checked by
  hand on the Mac.
- The repo is public (MIT, see `LICENSE`). Never commit secrets, real hostnames or addresses,
  team ids, or personal paths and emails; this covers PR descriptions, comments and release notes.
- **The Mac's main checkout and app builds** (decided by the user, 2026-10-16; PR test builds
  moved to the VM on 2026-10-17, and back to the host, as builds only, on 2026-10-18):
  - The main checkout on the Mac stays on local `main`, kept up to date with `origin/main`.
    Don't leave it on a feature branch, don't switch it to a PR branch to test it, and don't
    start new work on a merged branch.
  - Write code on a new branch from the latest `origin/main`, in a separate `git worktree`
    beside the main checkout, not in the main checkout itself.
  - **PR test builds** happen on the host, through `scripts/vm-test.sh` run from the PR's
    worktree (see [Testing conventions](#testing-conventions)): it builds into that worktree's
    git-ignored `build/vm-test`, ships the products to the VM to run, then unregisters
    (`lsregister -u`) and deletes the built apps, keeping only the intermediates for the next
    incremental build. Don't build a PR on the host any other way, and never run or open it
    there.
  - **The host build** happens only in the main checkout, after a merge: pull `main`, build
    with Xcode's default DerivedData (no custom `-derivedDataPath`), and relaunch our Talaria
    app (never the official Hermes Desktop). It never waits on a VM run.
  - Each host build overwrites the last: the host keeps exactly one Talaria.app (bundle id
    `com.example.hermesapp.mac`), the one in that DerivedData. Remove any stray copy (and
    `lsregister -u` it) rather than leaving extra builds around (decided by the user,
    2026-10-16).
  - Only if the user asks to try a PR on the Mac before it merges: check `git status` first
    (never discard uncommitted work), switch the main checkout to the branch, build, and switch
    back to `main` once they have tried it.
- When you finish a task, report: changed paths, the commands you ran and their results, and
  what remains unverified (especially anything that needs the Mac).
