# hermesapp

**Talaria**: native **macOS** and **iOS** clients (SwiftUI, platform look) for a self-hosted
[Hermes Agent](https://github.com/NousResearch/hermes-agent).

The apps don't add anything to Hermes. They connect to the dashboard's existing TUI-gateway
JSON-RPC WebSocket (`/api/ws`), the same interface the official Electron desktop app uses for a
remote gateway. See [`docs/protocol.md`](docs/protocol.md).

## Download

Signed Mac builds are on the [Releases](https://github.com/pd90506/hermesapp/releases) page and
update themselves in the app (Sparkle). There is no App Store or TestFlight build of the iOS app;
build it yourself (see [Signing](#signing)).

## Current features

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
  code blocks and message copying are supported. The chat can jump to the latest prompt or
  scroll to the bottom without losing its place while older pages load.
- **Composer.** Send images and files (including PDFs) using `+`, paste or drag-and-drop; files
  sent by Hermes appear in the transcript and can be saved. Pick the model and reasoning effort
  per chat. Slash suggestions and command dispatch work, including skills, `/compress`, `/btw`,
  `/bg` and `/stop`; some client-side commands still have no UI (see limitations). A Send button
  is available during a running turn; text follows Hermes's busy-input mode, while messages with
  images queue as the next turn. On macOS Return sends and Shift-Return inserts a newline; on iOS
  Return inserts a newline and Send (or Command-Return) submits.
- **Themes.** Light/dark/system appearance, colour themes and adjustable UI/content/code sizes;
  Markdown colours have their own settings. The Mac uses pointer hover feedback and the iPhone
  uses a floating composer and profile drawer.

The shared Swift package also builds and tests on Linux; the SwiftUI apps need a Mac with Xcode.
The Linux CI does **not** verify Apple UI builds. Voice input and
native token-refresh wiring are not in the apps yet. See [Known limitations](#known-limitations)
and [`docs/protocol.md`](docs/protocol.md) for details.

## Layout

```
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
docs/protocol.md           Source-cited protocol notes for native clients.
scripts/check-project-spec.py  Static check of project.yml on Linux.
scripts/vm-test.sh         Mac-hosted build, VM-only automated test runner.
.github/workflows/         Linux-only Swift package CI.
```

## Building

### The package (Linux or Mac)

The package builds and tests anywhere Swift 6.2 or later runs, without Xcode:

```sh
swift build --package-path Packages/HermesKit
swift test  --package-path Packages/HermesKit
python3 scripts/check-project-spec.py        # after editing project.yml or adding app files
```

The manifest pins `swift-tools-version: 6.2`, the version in Xcode 26.

### The apps (Mac, Xcode 26)

```sh
brew install xcodegen                              # once
xcodegen generate                                  # after pulling or changing app sources/project.yml
python3 scripts/check-project-spec.py
xcodebuild -project Hermes.xcodeproj -scheme HermesMac -configuration Debug build
```

For iOS, build `HermesiOS` in Xcode or with `xcodebuild` after signing is configured (see
[Signing](#signing)); installing on a paired phone requires it to be unlocked.
`Apps/Shared/AppIcon.icon` is adapted from Hermes Desktop's Icon Composer asset (MIT; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)).

### Automated tests: Mac-hosted Tart VM only

**Never run automated tests, a test dashboard or `scripts/live-test.sh` on the Mac host.** The
host compiles test products; a single [Tart](https://tart.run) VM, `hermesapp-test-vm`, runs all
package live, macOS window and macOS UI tests. Run this from the feature's own worktree:

```sh
scripts/vm-test.sh                          # full live + window + macOS UI suite
scripts/vm-test.sh --ios                    # full suite plus iOS simulator UI tests
scripts/vm-test.sh --only window            # focused iteration; live,window,ui can be combined
scripts/vm-test.sh --test HermesMacTests/HoverTests  # one suite or test
```

`--keep` leaves the VM running only for an immediate follow-up run. Runs queue on a single VM
lock; build intermediates stay in that worktree's ignored `build/vm-test`, screenshots return to
`build/vm-test/screenshots/`, and test app bundles are removed from the host afterwards. The VM
uses only its own `hermesapp-test` Hermes profile. The ignored `.env.vm-hermes` supplies the
model key to the VM; never commit it or put it in logs. Without it, tests requiring model
responses skip or fail. **Before reporting a PR ready to merge, run the full suite without
`--only` or `--test`** (and add `--ios` if iOS changed). Show VM screenshots for visible UI
changes. See [`AGENTS.md`](AGENTS.md) for the complete host/VM rules and the git workflow.

### Why XcodeGen

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

## Signing

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

- In the app, enter the dashboard URL, e.g. `https://hermes.example.ts.net` (a Tailscale HTTPS
  name), and pick a sign-in method:
  - **Username & password**: for dashboards using the `basic` provider. The app logs in via
    `/auth/password-login` and mints a single-use WebSocket ticket for each connection.
  - **Access token (ticket)**: a dashboard access token, e.g. from the native PKCE flow, which is
    not yet built into the UI. The app exchanges it for a single-use ticket on every connect.
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

## Known limitations

- **Voice input** is not available yet (`docs/protocol.md` §10.4).
- The package refreshes native token pairs through `/auth/native/refresh`
  (`GatewayCredential.native`), but the apps don't use it yet. The "Access token (ticket)" mode
  takes an access token only, which can't be refreshed. `basic` access tokens last 12 h, so
  re-enter the token after that.
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

## Rules for contributors and agents

See [`AGENTS.md`](AGENTS.md).

## License

[MIT](LICENSE). Third-party material is listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
