# hermesapp

**Talaria**: clients for a self-hosted [Hermes Agent](https://github.com/NousResearch/hermes-agent).

| App | Platforms | Built with | Where | Status |
| --- | --- | --- | --- | --- |
| **Talaria Desktop** | Windows and macOS | Electron + React (TypeScript) | `Apps/Desktop/electron` | The desktop app; new work happens here |
| **Talaria for iOS** | iPhone | SwiftUI | `Apps/iOS`, `Apps/Shared` | Active |
| **Talaria for Mac** (SwiftUI) | macOS | SwiftUI | `Apps/macOS`, `Apps/Shared` | Bug fixes only |

The apps don't add anything to Hermes. They connect to the dashboard's existing TUI-gateway
JSON-RPC WebSocket (`/api/ws`), the same interface the official Hermes Desktop app uses for a
remote gateway. See [`docs/protocol.md`](docs/protocol.md).

The desktop app moved to Electron in November 2026, so Windows and macOS share one app with
one look. The earlier Flutter Windows app was removed; its last state is on the
[`archive/flutter-desktop`](https://github.com/pd90506/hermesapp/tree/archive/flutter-desktop)
branch.

## Download

There are no published builds of Talaria Desktop yet; build it yourself (see
[Talaria Desktop](#talaria-desktop-electron)). Signed builds of the SwiftUI Mac app are on the
[Releases](https://github.com/pd90506/hermesapp/releases) page and update themselves in the app
(Sparkle). There is no App Store or TestFlight build of the iOS app; build it yourself (see
[Signing](#signing-apple-apps)).

## Talaria Desktop (Electron)

One app for Windows 11 and macOS. Both platforms get the same layout, in the style of the
official Hermes Desktop; only the window frame differs (Mica and Windows' own caption buttons
on Windows, inset traffic lights and vibrancy on macOS) and each uses its system font.

- **Servers and sign-in.** Several dashboards connected at once, with password, access token,
  session token or browser sign-in. The app can also run its own local `hermes serve`. Each
  server's secret is encrypted with Electron's `safeStorage` (DPAPI on Windows, the Keychain on
  macOS).
- **Sidebar.** The profile rail, each profile's pinned Bot Chat over its sessions, date groups,
  pinned and unread chats, search, and the session menu (pin, rename, archive, delete).
- **Chat.** Streaming replies with Markdown (code highlighting and math), a turn's work as
  folded tool rows, reasoning and notices, approval, clarify, sudo and secret cards, held
  messages and compression cards over the composer, message actions (copy, Branch in New Chat)
  and a prompt rail. Attachments (images and files), remote Markdown images and `::preview`
  HTML widgets in replies. Pills for tasks, background jobs and subagents, and system
  notifications.
- **Composer.** Model and reasoning-effort pickers, slash commands, a context gauge.
- **Cron Jobs** tab, **Providers** and **Capabilities** panes, and a **Settings** overlay
  (servers, appearance with the colour themes, light/dark and text sizes, notifications,
  session sources).

Not there yet: installers and auto-update (the app is packed as an unpacked folder), and voice
input.

How the code is laid out and the rules for working on it are in
[`docs/desktop-electron.md`](docs/desktop-electron.md) and
[`Apps/Desktop/electron/AGENTS.md`](Apps/Desktop/electron/AGENTS.md).

## iOS and the SwiftUI Mac app

The SwiftUI Mac app was the first desktop client. It still works and gets bug fixes, but new
desktop features go to Talaria Desktop. The iOS app stays in SwiftUI. Both share
`Apps/Shared` and the `HermesKit` package.

### Features

- **Native macOS and iOS chat.** The Mac has a collapsible profile rail, session list and chat;
  iPhone shows profiles in a drawer, then sessions or chat. Profiles are scoped to their server.
  Each profile has a permanent Bot Chat shared with Hermes Desktop, plus side chats and other
  sessions. Pin, rename, fork, archive and delete are available from session rows; the Bot Chat
  remains protected. A second tab lists the profile's Cron Jobs, recent runs and actions to run,
  pause/resume, change delivery or delete a job. Creating a job is not a form in the app.
- **Connections.** The app can keep several dashboards connected simultaneously. The Mac app can
  also start its own local `hermes serve --isolated` backend ("This Mac"). Server credentials
  live in Keychain. Settings have native Mac panes and an iOS settings page for servers,
  appearance, Markdown colours and session sources.
- **Conversation.** Chats show recent messages first and page older history on demand. They
  reopen immediately while catching up in the background. Streaming replies, reasoning,
  tool-call summaries and details, interim/waiting rows, notices and approval/clarify cards are
  displayed. Assistant Markdown includes GFM tables and native SwiftMath rendering of LaTeX;
  code blocks and message copying are supported. Replies can show remote Markdown images and
  `::preview` HTML widgets. The chat can jump to the latest prompt or
  scroll to the bottom without losing its place while older pages load.
- **Composer.** Send images and files (including PDFs) using `+`, paste or drag-and-drop; files
  sent by Hermes appear in the transcript and can be saved. Pick the model and reasoning effort
  per chat. Slash suggestions and command dispatch work, including skills, `/compress`, `/btw`,
  `/bg` and `/stop`; some client-side commands still have no UI (see limitations). A Send button
  is available during a running turn; text follows Hermes's busy-input mode, while messages with
  images queue as the next turn. On macOS Return sends and Shift-Return inserts a newline; on iOS
  Return inserts a newline and Send (or Command-Return) submits.
- **Search, subagents, context.** The session list searches the profile's chats by what was
  said in them, their titles or ids (`/api/sessions/search`): from the sidebar's field (⌘F) on
  the Mac, from the Search tab on iOS. While a turn's subagents run, a pill above the composer
  lists them, with each one's goal, newest activity and time, and Steer and Stop. A ring in the
  composer shows how full the context is; it opens what fills it and the session's tokens,
  model calls, cache hits and speed.
- **Themes.** Light/dark/system appearance, colour themes and adjustable UI/content/code sizes;
  Markdown colours have their own settings. The Mac uses pointer hover feedback and the iPhone
  uses a floating composer and profile drawer.

The Swift package also builds and tests on Linux; the SwiftUI apps need a Mac with Xcode.
The Linux CI does **not** verify Apple UI builds. Voice input and
native token-refresh wiring are not in the apps yet. See [Known limitations](#known-limitations-apple-apps)
and [`docs/protocol.md`](docs/protocol.md) for details.

## Layout

```
Apps/Desktop/electron/     Talaria Desktop (Electron + React): src/main (window, HTTP, WebSockets,
                           settings, secrets), src/preload (the window.talaria bridge),
                           src/renderer (React views, CSS Modules, design tokens).
Packages/hermes-core/      The desktop app's client core in TypeScript, a port of HermesKit
                           (protocol, connection, sessions, chat, composer), with no DOM.
Packages/fixtures/         JSON cases that HermesKit and hermes-core must both pass.
package.json, pnpm-workspace.yaml   The pnpm workspace for the two packages above.
Packages/HermesKit/        Linux-compatible Swift package for protocol, networking, auth,
                           multi-server/session state, transcript, composer, slash commands,
                           Markdown, appearance, files and Cron Jobs.
  Sources/HermesProtocol/    Codable JSON-RPC methods, events and server requests.
  Sources/HermesKit/         Shared client and presentation logic (no SwiftUI).
  Tests/HermesKitTests/     Fake-transport and fake-HTTP Swift Testing suites.
  Tests/HermesLiveTests/    Opt-in real-dashboard tests; run only inside the test VM.
Apps/Shared/               SwiftUI views, AppModel, composer, Markdown/SwiftMath and Keychain.
Apps/macOS/, Apps/iOS/     Platform entry points and native settings/window support.
Apps/Tests/macOS/          AppKit window and component tests, run inside the test VM.
Apps/UITests/              macOS and iOS UI tests, run inside the test VM.
project.yml                XcodeGen source of truth; never commit the generated .xcodeproj.
Config/                    Shared settings and ignored local signing configuration.
backend/                   Reserved for server-side helpers (e.g. a push relay).
docs/                      Protocol notes, the Electron app, flaky tests, performance tracing.
scripts/check-project-spec.py  Static check of project.yml on Linux.
scripts/vm-test.sh         Mac-hosted build, VM-only automated test runner.
scripts/windows/           Build-Electron.ps1: install, test and pack the desktop app on Windows.
scripts/windows-test-vm/   The headless Hyper-V VM for Windows UI screenshots.
.github/workflows/         Linux CI: the Swift package, and the Electron workspace.
```

## Building

### Talaria Desktop (Windows, macOS or Linux)

Needs Node 22.12 or later and pnpm 10.28.0 (from corepack, or `npx pnpm@10.28.0`):

```sh
pnpm install          # at the repo root
pnpm typecheck
pnpm test
pnpm desktop:dev      # Vite dev server + Electron
pnpm desktop:pack     # an unpacked app in Apps/Desktop/electron/dist
```

On Windows, `scripts/windows/Build-Electron.ps1` installs, tests and packs in one go. Linux CI
type-checks, tests and builds the workspace; packing and screenshots happen on Windows and the
Mac.

### The Swift package (Linux, Windows or Mac)

The package builds and tests anywhere Swift 6.2 or later runs, without Xcode:

```sh
swift build --package-path Packages/HermesKit
swift test  --package-path Packages/HermesKit
python3 scripts/check-project-spec.py        # after editing project.yml or adding app files
```

The manifest pins `swift-tools-version: 6.2`, the version in Xcode 26.

### The SwiftUI apps (Mac, Xcode 26)

```sh
brew install xcodegen                              # once
xcodegen generate                                  # after pulling or changing app sources/project.yml
python3 scripts/check-project-spec.py
xcodebuild -project Hermes.xcodeproj -scheme HermesMac -configuration Debug build
```

For iOS, build `HermesiOS` in Xcode or with `xcodebuild` after signing is configured (see
[Signing](#signing-apple-apps)); installing on a paired phone requires it to be unlocked.
`Apps/Shared/AppIcon.icon` is adapted from Hermes Desktop's Icon Composer asset (MIT; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).

### Tests

- **Talaria Desktop:** `pnpm test` at the repo root (also run by CI on Linux). Windows UI
  screenshots are taken in a headless Hyper-V VM (`scripts/windows-test-vm/`).
- **Swift package:** `swift test --package-path Packages/HermesKit` anywhere (also run by CI).
- **Apple apps:** live, window and UI tests run only inside a macOS [Tart](https://tart.run) VM,
  never on the Mac itself: `scripts/vm-test.sh` builds on the Mac and runs the tests in the VM
  against a Hermes installed there. For example:

  ```sh
  scripts/vm-test.sh --changed     # the tests the branch's changes need
  scripts/vm-test.sh --ios         # everything, plus the iOS simulator UI tests
  ```

  Tests that need a model reply use an endpoint and key from the git-ignored `.env`.

The full rules for agents and contributors (which host checks what, the test VMs, the git
workflow) are in [`AGENTS.md`](AGENTS.md).

The Xcode project is generated from `project.yml` by XcodeGen and never committed.

## Signing (Apple apps)

- Bundle ids are `$(HERMES_BUNDLE_ID_PREFIX).mac` and `.ios`. The committed prefix is the
  placeholder `com.example.hermesapp` (in `Config/Shared.xcconfig`).
- For your own builds, run `cp Config/Local.xcconfig.example Config/Local.xcconfig` (git-ignored)
  and set:
  - `DEVELOPMENT_TEAM`: your personal team id
  - `HERMES_BUNDLE_ID_PREFIX`: e.g. `com.<you>.hermesapp`
- Then run `xcodegen generate`. Automatic signing works with a free personal team. Personal-team
  iOS builds expire after 7 days.
- The macOS app is **not** sandboxed (decided 2026-10): it runs `hermes serve` itself (see
  "This Mac" below), which needs to read `~/.hermes`, and a sandboxed app's child process
  inherits the sandbox. Hermes Desktop isn't sandboxed either. A Mac App Store build would need
  the sandbox back, and "This Mac" with it gone.

## Connecting to Hermes

This section describes the Apple apps; Talaria Desktop offers the same sign-in methods.

- In the app, enter the dashboard URL, e.g. `https://hermes.example.ts.net` (a Tailscale HTTPS
  name), and pick a sign-in method:
  - **Username & password**: for dashboards using the `basic` provider. The app logs in via
    `/auth/password-login` and mints a single-use WebSocket ticket for each connection.
  - **Sign in with browser**: the dashboard's own sign-in page opens in the browser (on iOS the
    system's sign-in sheet), as Hermes Desktop signs in to a remote gateway (RFC 8252: a loopback
    redirect and PKCE). The token pair it gives renews itself, so it doesn't run out after 12 h.
  - **Access token (ticket)**: a dashboard access token. The app exchanges it for a single-use
    ticket on every connect. It can't be renewed.
  - **Token in URL (`?token=`)**: sends the token directly in the WebSocket URL.
    - It works with an access token on a gated dashboard, or with the session token of an
      un-gated dashboard.
    - Un-gated only exists on a **loopback** bind, which refuses other devices except through a
      tunnel. `--insecure` no longer disables the gate.
    - Prefer the other modes: this token is long-lived and travels in the URL.
- **Several servers.** Add Server in the settings adds another dashboard (say a home server and
  a local one), each with its own name, URL and sign-in. The app stays connected to all of them
  at once, one connection each.
  - With more than one, the profile rail groups profiles under each server's name and status
    dot, and the session list names the server of the profile it lists.
  - The single-server setting of earlier versions becomes the first server on launch, its
    Keychain secret moved to that server's own item.
- **This Mac (macOS).** Like Hermes Desktop, the app starts its own Hermes backend when it
  launches and stops it when it quits: `hermes serve --isolated` on 127.0.0.1, on a port the OS
  picks, with a new `HERMES_DASHBOARD_SESSION_TOKEN` each time. It is the first server in the
  list.
  - `hermes` is looked up in `~/.local/bin`, `~/.hermes/hermes-agent/.hermes/bin`,
    `/opt/homebrew/bin`, `/usr/local/bin`, then PATH.
  - The backend gets `HERMES_PARENT_PID`, so it also exits shortly after the app crashes. If it
    dies while the app runs, the app starts a new one and reconnects.
  - It shares `~/.hermes` with Desktop's own backend: the same chats and bots; a chat open in one
    refuses messages from the other.
  - Turn it off with "Run Hermes on this Mac" in the settings.
- **Secrets:**
  - Each server's password or token is stored in the Keychain, as this-device-only. If saving
    fails, the app says so. Removing a server deletes its item.
  - Unsigned macOS builds fall back from the data-protection keychain to the login keychain.
  - The login keychain gives a build without a team id its saved passwords only by that
    build's code hash, so every rebuild asks for the Keychain password again. Signing with a
    team, even a free personal one, avoids that; a self-signed certificate does not (see
    `Config/Local.xcconfig.example`).
  - Non-secret settings go in UserDefaults. Nothing is hard-coded.
- **Cookies.** Dashboard session cookies live in a per-connection in-memory cookie jar, not the
  app-wide one. They are never written to disk or shared between servers, so the app logs in
  again (with the stored password) after a relaunch.
- **Prefer HTTPS** (e.g. `tailscale serve`).
  - App Transport Security allows plain HTTP only for local-network hosts
    (`NSAllowsLocalNetworking`: `.local` names, unqualified names, IP addresses).
  - That does **not** cover `http://*.ts.net`. Plain-HTTP tailnet names will be blocked, so use the
    Tailscale HTTPS name.

## Known limitations (Apple apps)

- **Voice input** is not available yet.
- **Access tokens** can't be renewed: re-enter one after it expires (12 h on `basic`
  dashboards), or use "Sign in with browser", which renews itself.
- **Clarify questions** that allow several answers still offer only one choice.
- **Slash commands.** Server-side commands, skills, `/new`, `/reset`, `/clear`, `/help`,
  `/model`, `/reasoning`, `/compress`, `/btw`, `/bg` and `/stop` work. `/resume` opens only a
  session already in History. Others from Hermes Desktop, such as `/branch`, `/skin` and
  `/profile`, aren't there yet; the app shows a note instead of sending them. Fork a session
  from its row or message menu.
- **Device-only rows.** Slash-command output, notices and `/btw` / `/bg` answers stay on this
  device (Hermes doesn't store them) and can disappear after a reconnect to a restarted backend.
- **Rename** works only for a chat the app has opened recently.
- **Archive** can be undone only for a row still on screen: archived chats can't be listed.
- **A chat open in another client** (say a Hermes Desktop window) can't be deleted until that
  client closes it.
- **Stored tool rows** show no output (except file writes, patches and skill edits); live ones
  do.
- **Files** over 50 MB are refused. Removing an attached file's card doesn't delete the upload.
- **Idle chats** the backend reclaims stay on screen and resume on their next action.
- **Lists** refresh at most every 10 s after a change, and the profile list every 15 s.
- Requests for a session other than the open one show only as a badge.
- **Profiles** can't be created, renamed or deleted in the app, and Bot Chats can't be renamed,
  archived or deleted.
- **Math** the renderer can't handle shows as LaTeX source, and a few commands are approximated
  (`\boxed` drops its box, `\color` is ignored).
- **Selecting text** works within one paragraph, list item or table cell, not across them.
  Formulas aren't selectable; use "Copy LaTeX".

Implementation notes behind these are in [`AGENTS.md`](AGENTS.md) and
[`docs/protocol.md`](docs/protocol.md).

## Contributing

Development rules, for people and coding agents alike, are in [`AGENTS.md`](AGENTS.md).

## Credits

Talaria Desktop adapts MIT-licensed code from the official
[Hermes Desktop](https://github.com/NousResearch/hermes-agent) (Nous Research): the app icon,
Shiki themes, system notifications and the `::preview` widget frame and directives. Its
structure (platform differences in the shell, frame geometry as CSS variables, design tokens
with a stylesheet scan) follows patterns from
[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) (MIT). Other bundled
libraries include Electron, React, streamdown, Shiki, KaTeX, Lucide icons and, in the Apple
apps, SwiftMath and Sparkle. Licenses and details are in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE). Third-party material is listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
