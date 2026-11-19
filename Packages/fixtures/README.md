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
| `session-projection.json` | Stored transcript rows as chat rows: hidden rows, tool calls, attachments, skill turns |
| `servers-auth.json` | The browser sign-in's PKCE challenge, the local backend's ready-port line |
| `cron-jobs.json` (Swift: `CronFixtureTests.swift`) | Cron job rows: fields read, titles, states, delivery targets and toggles, schedule presets, run session ids |
| `appearance-themes.json` | Every colour theme's accent, window surfaces and Markdown colours (light and dark), the System theme tinted with a system accent, and how the Appearance settings load and clamp text sizes. Generated from HermesKit (`HERMES_EXPORT_FIXTURES=1 swift test --filter AppearanceFixtureTests`); the desktop app's theme stylesheet is generated from it (`Apps/Desktop/electron/scripts/export-themes.mjs`) |
