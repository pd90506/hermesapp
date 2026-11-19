# Talaria Desktop (Electron): renderer rules

The repository's rules are in [/AGENTS.md](../../../AGENTS.md); this file adds the chat
renderer's extension points, so feature packages can be built side by side without
editing each other's files.

## Where the chat lives

- `Packages/hermes-core/src/session/`: the chat model, with no DOM. It covers
  `ChatManager` (`connection.chats`: open, revisit, reconnect, Bot Chat),
  `ChatSession` (one chat's transcript, send, stop, requests) and `ChatComposer` (its
  draft and send state). Views read them with `useSnapshot`.
- `src/renderer/features/chat/`: `ChatPane` (the chat on screen, opening or empty),
  `ChatView` (the transcript with the composer over its end), `TranscriptList` (the
  virtual list), `TranscriptFooter` (waiting row, request cards, status) and
  `RequestCard` (approval, sudo, secret).
- `src/renderer/features/composer/`: `Composer` (text, Send, Stop, Cancel Send) and
  `keys.ts` (Return sends; Shift- or Option/Alt-Return breaks the line; ⌘↩ / Ctrl+Enter
  send; Return never sends while an input method composes).

## Extension points

Each point is a registry that a package fills from its own module, at import time. To
add to one, write your module and add **one import line** to the matching
`registered-*.ts` file, under your package's letter (append-only; keep package order).
Don't edit `ChatView`, `TranscriptList` or `Composer` to place your feature.

| Point | Register with | Import line goes in | Used for |
| --- | --- | --- | --- |
| Transcript blocks | `registerBlockRenderer(kind, Component)` in `features/chat/blocks/registry.ts` | `features/chat/blocks/registered-blocks.ts` | How a block draws. `kind` is `blockKind(block)`: `user`, `assistant`, `system` or `tool` for one row, `work` for a group (C). The last registration of a kind wins, so a package can replace a renderer (C does `tool`). |
| Composer slots | `registerComposerSlot({ id, area, order, Slot })` in `features/composer/slots.ts` | `features/composer/registered-slots.ts` | `cards` over the composer (F), `attachments` in the card (E), `leading` toolbar start (E), `modelEffort` (D), `trailing` before Send (D). |
| Chat pills | `registerChatPill({ id, order, Pill })` in `features/chat/overlay.ts` | `features/chat/registered-pills.ts` | The row of the scroll-to-bottom button over the composer (J). The scroll button is at order 100. A pill returns `null` when it has nothing to show. |

Components get the `ChatSession` (and, for slots, its `ChatComposer`); read them with
`useSnapshot`. Which blocks the list shows at all is `isListed` in `TranscriptList.tsx`
(grouping into `work` blocks is `transcriptBlocks` in hermes-core, C's to change).

## Styles

Tokens live only in `src/renderer/theme/tokens.css`, one `/* <letter> */` section per
package. `tests/stylesheet-scan.test.ts` fails on a raw colour or pixel size in a
`*.module.css`, and on `platform ===` branching or `navigator.platform` / `userAgent`
in renderer code; style a platform with `:global([data-platform='windows'])`.
