# hermesapp

Native **macOS** and **iOS** clients (SwiftUI, platform look) for a self-hosted
[Hermes Agent](https://github.com/NousResearch/hermes-agent).

The apps don't add anything to Hermes. They connect to the dashboard's existing TUI-gateway
JSON-RPC WebSocket (`/api/ws`), the same interface the official Electron desktop app uses for a
remote gateway. See [`docs/protocol.md`](docs/protocol.md).

Status: foundation only.
- The shared package is real and tested on Linux.
- The app UIs are minimal shells: connection settings, a bot sidebar (every Hermes profile as a
  bot with its one permanent "Bot Chat", shared with Hermes Desktop's Bot Mode, plus a History
  area for side chats), and a chat with approval/clarify cards.
- Opening a chat loads only its newest 120 messages; older ones load page by page as you scroll
  up, as in Hermes Desktop.
- Assistant replies (and reasoning) render as Markdown: headings, lists, quotes, code blocks,
  GFM tables and LaTeX math (`$…$`, `\(…\)`, `$$…$$`, `\[…\]`), typeset natively with SwiftMath.
  User messages and tool rows stay plain text.
- The composer follows Hermes Desktop's: a text area that grows with its text, image attachments
  shown as cards (`+`, paste, drag and drop), and per-chat model and reasoning-effort pickers.
  On macOS, Return sends and Shift-Return inserts a newline. On iOS, Return inserts a newline and
  the Send button (or Command-Return) sends. While a reply runs, Send sits beside Stop as soon as
  there is something to send. A message with images is queued as the next turn. Text alone
  follows Hermes's busy-input setting, which by default redirects or stops the running reply.
  Voice input is not available yet
  (`docs/protocol.md` §10.4).
- Both apps build on the Mac with Xcode.

## Layout

```
Packages/HermesKit/        Swift package — all non-UI logic. Builds and tests on Linux and macOS.
  Sources/HermesProtocol/    Codable wire types: JSON-RPC envelope, JSONValue, gateway methods,
                             events, server→client requests.
  Sources/HermesKit/         Transport (URLSession WebSocket), GatewayClient (id correlation,
                             event/request dispatch, heartbeat, replay), dashboard auth
                             (ticket, password login, PKCE), REST transcript pages, Transcript
                             reducer (paging; stored rows are the source of truth), ChatSession and
                             GatewayConnection (@Observable, reconnect + resume), Markdown/LaTeX
                             parsing for chat rendering (Markdown/), composer state: attachments,
                             model and effort pickers (Composer/).
  Tests/                     Swift Testing suites driven by a fake transport and a fake HTTP client.
Apps/Shared/               SwiftUI code compiled into both apps (AppModel, views, Keychain,
                           Markdown and math views; math uses SwiftMath, see AGENTS.md; the
                           composer's text view, image loading and pickers in Composer/).
Apps/macOS/, Apps/iOS/     Per-platform @main entry points.
project.yml                XcodeGen spec: the source of truth for the Xcode project.
Config/                    xcconfigs (signing placeholders); Generated/ is written by XcodeGen.
backend/                   Reserved for NUC-side helpers (e.g. a push relay). Empty on purpose.
docs/protocol.md           Source-cited protocol notes for native clients.
scripts/check-project-spec.py  Linux sanity check of project.yml.
.github/workflows/         Linux-only CI: `swift test` for the package.
```

## Workflows

### On the NUC (Linux, no Xcode)

You can build and test only the package. UI code can be edited here, but it is compiled and run
on the Mac.

```sh
swift build --package-path Packages/HermesKit
swift test  --package-path Packages/HermesKit
python3 scripts/check-project-spec.py        # after editing project.yml or adding app files
```

Toolchain: Swift 6.x via swiftly (`source ~/.local/share/swiftly/env.sh`). The manifest pins
`swift-tools-version: 6.2`, the version in Xcode 26, so it resolves on both hosts.

### On the Mac (Xcode 26)

```sh
brew install xcodegen          # once
xcodegen generate              # creates Hermes.xcodeproj (git-ignored); re-run after pulling
open Hermes.xcodeproj
```

- Build and run the **HermesMac** and **HermesiOS** schemes.
- `swift test --package-path Packages/HermesKit` works on the Mac too, or open
  `Packages/HermesKit/Package.swift` in Xcode to run the tests there.
- If you add, remove or move an app source file, re-run `xcodegen generate`. Folder contents are
  picked up automatically; only `project.yml` changes need a regenerate.

### Why XcodeGen

A hand-maintained `.xcodeproj` can't be edited sensibly on Linux and causes merge conflicts
between the NUC and the Mac.

- **XcodeGen** keeps the whole project in one short YAML file (`project.yml`):
  - The generated project and Info.plists are ignored by git.
  - Any host, or an agent, can edit the YAML.
  - It's a single Homebrew binary with no Swift manifest to compile.
  - It's mature and handles local Swift packages, multi-platform targets, entitlements and xcconfigs.
- **Tuist** needs its own CLI and a Swift-DSL manifest that also only evaluates on macOS, which
  is more machinery for two targets.
- **Xcode 16+ synchronized folders** reduce `project.pbxproj` churn, but the pbxproj is still a
  committed, hand-merged artefact.

XcodeGen can't be run on the NUC. Linux support is not something this repo relies on, and this
environment has no network to fetch it. So `scripts/check-project-spec.py` checks the spec
statically (YAML parses, paths exist, local package products exist, remote packages use https and
pin a version, every app Swift file belongs to a target). The real check is `xcodegen generate`
on the Mac.

## Signing

- Bundle ids are `$(HERMES_BUNDLE_ID_PREFIX).mac` and `.ios`. The committed prefix is the
  placeholder `com.example.hermesapp` (in `Config/Shared.xcconfig`).
- For your own builds, run `cp Config/Local.xcconfig.example Config/Local.xcconfig` (git-ignored)
  and set:
  - `DEVELOPMENT_TEAM`: your personal team id
  - `HERMES_BUNDLE_ID_PREFIX`: e.g. `com.<you>.hermesapp`
- Then run `xcodegen generate`. Automatic signing works with a free personal team. Personal-team
  iOS builds expire after 7 days.
- The macOS app is sandboxed with `com.apple.security.network.client`.

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
- **Secrets:**
  - The password or token is stored in the Keychain, as this-device-only. If saving fails, the app
    says so.
  - Unsigned macOS builds fall back from the data-protection keychain to the login keychain.
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

- The package refreshes native token pairs through `/auth/native/refresh`
  (`GatewayCredential.native`), but the apps don't use it yet. The "Access token (ticket)" mode
  takes an access token only, which can't be refreshed. `basic` access tokens last 12 h, so
  re-enter the token after that.
- Clarify `multi_select` is shown as a single choice.
- Requests for sessions other than the open one show only as a badge (and on the bot's row when
  this app opened that session).
- The app only lists bots and opens or creates their Bot Chats. It does not create, rename or
  delete profiles, and it does not run Desktop's sweep that re-hides Bot Chats.
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
