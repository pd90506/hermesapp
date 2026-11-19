# Shared client fixtures

Cases both client cores must agree on: HermesKit (Swift, the iOS and Mac SwiftUI apps)
and `Packages/hermes-core` (TypeScript, the Electron desktop app). Each file is read by
a Swift test (`Packages/HermesKit/Tests/HermesKitTests/SharedFixtureTests.swift`) and a
vitest suite (`Packages/hermes-core/tests/shared-fixtures.test.ts`). When one core's
behaviour changes on purpose, change the fixture and both cores in the same PR.

Payloads match what Hermes sends (AGENTS.md, "Testing conventions"); cite the Hermes
source when adding a shape.

| File | What it pins |
| --- | --- |
| `endpoint.json` | Address normalisation, the WebSocket URL with a ticket, the default server name |
| `bots.json` | `profiles.list` rows: roster order, display names, Bot Chat ids, activity |
| `session-list.json` | Which `session.list` rows the session list shows |
| `server-requests.json` | Which server requests are declined, and with which code |
| `servers-auth.json` | The browser sign-in's PKCE challenge, the local backend's ready-port line |
