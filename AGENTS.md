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
   file.
5. **Don't patch Hermes or add a Hermes gateway platform.**
   - The apps are clients of Hermes's public interfaces.
   - NUC-side helpers go in `backend/` (see its README).
   - Hermes source (`~/.hermes/hermes-agent`) is read-only reference material.
6. **The Xcode project is generated.**
   - Edit `project.yml`, never a `.xcodeproj`, and never commit one.
   - After changing `project.yml` or adding app files, run `python3 scripts/check-project-spec.py`.
7. **No secrets or personal hosts in the repo.**
   - Use `hermes.example.ts.net`-style names only in docs and examples.
   - Signing team ids go in the git-ignored `Config/Local.xcconfig`.
8. **Swift 6 language mode, strict concurrency.**
   - UI state is `@MainActor @Observable`.
   - Connection state lives in actors.
   - No `@unchecked Sendable` without a comment explaining why it is safe.
9. **Tools versions.** Keep `swift-tools-version` at or below what the Mac's Xcode ships (6.2
   for Xcode 26). CI tests both 6.2 and the NUC toolchain.

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
- When you finish a task, report: changed paths, the commands you ran and their results, and
  what remains unverified (especially anything that needs the Mac).
