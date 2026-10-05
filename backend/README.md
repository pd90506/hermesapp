# backend/

Reserved for NUC-side code that the native apps may need later and that
**cannot** live inside Hermes itself, for example:

- an APNs push relay (Hermes event → Apple Push Notification service) so the
  iOS app can be notified of approvals or finished turns while backgrounded.

There is intentionally no code here yet. The apps talk directly to the
existing Hermes dashboard WebSocket (`/api/ws`); see `docs/protocol.md`.

Rules when adding something here:

- It is a *client* of Hermes's public interfaces (dashboard HTTP/WS, the
  HTTP API server). Do not patch Hermes or add a Hermes gateway platform.
- Each service gets its own subdirectory with its own README, run
  instructions, and tests. Pick the language that fits; nothing in the Swift
  package or the apps may depend on it.
- No secrets in the repo. Read credentials from the environment or a local,
  git-ignored file.
