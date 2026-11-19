# The Electron desktop app

Talaria for Windows and macOS, one Electron app with one React renderer (decided by the
user, 2026-11-19). The full migration plan, its stages and the decisions behind it are in
the plan document linked from the PR that started it; this page is how the code is laid out
and how to work on it.

## Layout

| Path | What it is |
| --- | --- |
| `Packages/hermes-core` | The client core in TypeScript: endpoint, dashboard sign-in, JSON-RPC client, connection with reconnect, profiles and session lists. A port of `HermesKit`'s, with no DOM and no Node dependency. |
| `Packages/hermes-core/src/protocol/contract.generated.ts` | Types for every gateway method, event and server request, generated from Hermes's OpenRPC contract by `scripts/gen-contract.mjs`. |
| `Packages/fixtures` | JSON cases both cores must agree on (see its README). |
| `Apps/Desktop/electron/src/main` | The main process: the window and its frame, HTTP with a cookie jar, WebSockets (`ws`), settings, the encrypted secret, the system accent. |
| `Apps/Desktop/electron/src/preload` | `window.talaria`, the typed bridge (`src/shared/bridge.ts`), and the document's platform marks. |
| `Apps/Desktop/electron/src/renderer` | React views, CSS Modules and the design tokens. |

## Rules

- **The renderer has no platform branches.** The preload sets `<html data-platform>`
  (`windows`, `mac`, `linux`) and the frame's geometry as `--frame-title-band-height`,
  `--frame-caption-width` and `--frame-traffic-lights-width`. Styles key on those;
  `tests/stylesheet-scan.test.ts` fails on a `platform ===` in renderer code.
- **Components use tokens.** Colours and sizes are written only in `theme/tokens.css`
  (shared, light and dark) and `theme/platform.css` (per platform). The same test fails on a
  hex, `rgb()` or pixel size in a `*.module.css`.
- **Positions and behaviour follow the Mac app** on both platforms; fonts, type sizes and the
  list selection follow each system (Segoe UI Variable at 14 px with the accent pill on
  Windows, the system font at 13 pt with the accent fill on macOS).
- **The renderer never touches the network.** HTTP and WebSockets run in the main process,
  so no `Origin` or CORS applies; the renderer reaches them through `window.talaria`.
- **Behaviour comes from `HermesKit`.** When porting, cite the Swift it mirrors, and add a
  shared fixture when both cores must agree.

## The window

- Windows 11: no system title bar (`titleBarStyle: 'hidden'`); Windows draws the caption
  buttons (`titleBarOverlay`, clear, symbols in the page's text colour) and the Mica
  backdrop (`backgroundMaterial: 'mica'`, build 22621 and later). The page is clear where
  the material should show; the chat lies on a layer with a rounded top-left corner.
- macOS: `hiddenInset` with the traffic lights in the 52 pt band and sidebar vibrancy.
- The window drags by the title bands (`-webkit-app-region: drag`).

## Working on it

```sh
pnpm install          # at the repo root; Node 22.12+, pnpm 10.28.0
pnpm typecheck
pnpm test
pnpm desktop:dev      # Vite dev server + Electron
pnpm desktop:build    # out/{main,preload,renderer}
pnpm desktop:pack     # an unpacked app in Apps/Desktop/electron/dist
```

On Windows, `scripts/windows/Build-Electron.ps1` installs, tests and packs in one go.

To regenerate the contract types from a Hermes checkout:

```sh
node Packages/hermes-core/scripts/gen-contract.mjs <hermes-agent>/apps/shared/src/gateway-contract.openrpc.json --source "hermes-agent <commit>"
```

## What this version does

Sign in (password, access token or session token), the profile rail, the Bot Chat pinned
over each profile's sessions, and reconnecting. Chats, approvals, themes and the rest of
the Mac app follow in later changes. Every server request is declined at once until the
app can show it, so no agent waits on this window.
