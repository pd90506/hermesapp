# Desktop bridge

The desktop app (Windows and macOS) is a Flutter UI over the same `HermesKit` the SwiftUI
apps use. `HermesBridge` (`Packages/HermesKit/Sources/HermesBridge`) is a thin C interface
over `GatewayConnection`: JSON commands go in, JSON snapshots and replies come out. It has
no logic of its own. Anything that is not a view still belongs in `HermesKit`.

The Dart side is `Apps/Desktop/hermes_bridge`, which uses `dart:ffi` only.

## Library

`swift build --package-path Packages/HermesKit --product HermesBridge` builds
`HermesBridge.dll` on Windows and `libHermesBridge.dylib` on macOS. On Windows it needs the
Swift runtime DLLs next to it or on `PATH`.

| Function | What it does |
| --- | --- |
| `int32_t hb_version(void)` | Interface version, currently `1`. The Dart side refuses any other. |
| `void hb_start(void (*cb)(char *))` | Registers the event callback and creates the bridge. Call it once. |
| `void hb_command(const char *json)` | Queues one command. The reply comes later as an event. |
| `void hb_pump(void)` | Runs the work queued on Swift's main actor, then returns (see below). |
| `void *hb_alloc(intptr_t size)` | Memory for a string passed in, so the caller needs no allocator. |
| `void hb_free(void *)` | Frees an event string, or memory from `hb_alloc`. |

Strings are NUL-terminated UTF-8. The callback owns each event string and frees it with
`hb_free`. Events are delivered on the thread that runs Swift's main actor.

### Main actor

`GatewayConnection` and `ChatSession` are `@MainActor`. In a Flutter app on Windows nothing
drains Swift's main queue, so the Dart side calls `hb_pump` every 16 ms (one frame) from the
main isolate. With Flutter's merged threads, that isolate runs on the platform thread, which
is the process's main thread, so Swift's main actor and the UI share one thread (checked:
`Thread.isMainThread` is true there). On macOS the app's run loop already drains the queue,
and the pump is harmless. An event-driven pump that waits on the main queue's handle is
possible later; it would need libdispatch SPI, so it waits until the timer shows a cost.

## Commands

`{"id": "d1", "method": "...", "params": {...}}`. The reply is
`{"type": "reply", "id": "d1", "result": null}`, or `"error": "<message>"` in place of
`result`. A command that isn't valid JSON gets an error reply with `"id": ""`.

| Method | Params | Does |
| --- | --- | --- |
| `connect` | `url` plus one of: `token` (un-gated loopback dashboard), `accessToken` (bearer), `username` + `password` (+ `provider`, default `basic`) | Connects, replacing any connection, then loads the bots |
| `disconnect` | — | Disconnects and closes the chat |
| `refreshBots` | — | Reloads the profiles |
| `selectProfile` | `profile` (or none for all) | Shows that profile's sessions and reloads the list |
| `refreshSessions` | — | Reloads the session list |
| `openSession` | `id` from a `connection` snapshot's `sessions` | Opens it as the chat |
| `openBotChat` | `profile` | Opens the profile's Bot Chat |
| `newChat` | `profile` | Opens a new side chat |
| `send` | `text` | Sends a prompt in the open chat |
| `interrupt` | — | Stops the running turn |
| `closeChat` | — | Stops showing the chat |
| `deleteChat` | — | Deletes the open chat |

## Events

Whole snapshots, sent when an observed property changes. A snapshot is not re-sent if it
didn't change.

`connection`: `state` (`disconnected`, `connecting`, `connected`, `reconnecting`, `failed`),
`detail` (the attempt number or the failure), `bots` (`name`, `displayName`, `preview`,
`isDefault`), `listProfile`, `sessions` (`id`, `profile`, `storedID`, `title`, `preview`,
`startedAt` in Unix seconds, `messageCount`, `isUnread`), `sessionListLoading`,
`sessionListError`.

`chat`: `sessionID`, `storedSessionID`, `profile`, `title`, `isRunning`, `lastError`, `items`
(`id`, `role` (`user`, `assistant`, `tool` or `system`), `text`, `reasoning`, `toolName`,
`detail`, `isActive`, `outgoingStatus`, `timestamp`, and for an assistant item `markdown` and
`reasoningMarkdown`, below).

### Markdown

An assistant item's `text` (as `markdown`, when it has any) and `reasoning` (as
`reasoningMarkdown`) come parsed by HermesKit, in the parts the Mac app lays out
(`MarkdownPresentation`): the app only lays them out. A finished message is parsed once and
cached; the streaming one (`isActive`) is parsed again on each delta, in streaming mode (an
unclosed fence stays open instead of reflowing).

Each part has an `id` (the index of its first block, stable while the tail streams) and one of:

- `prose`: runs (`MarkdownSelection.Run`), in order. Runs up to a `separator` run form a
  paragraph; the paragraph's indents and gap are its first run's.
- `code`: `language`, `text`, `isClosed` (false while the closing fence is still coming), and
  `spans`: the code cut by HermesKit's `CodeHighlighter` into consecutive `text` runs, each with
  a `kind` (`keyword`, `string`, `comment`, `number`, `type`, `function`, `literal`, `plain`)
  for its colour. Their texts joined are `text`.
- `table`: `alignments` (`none`, `leading`, `center`, `trailing` per column), `header` (a
  list of cells) and `rows` (a list of rows of cells); a cell is a list of runs.

A run: `text`, `role` (`body`, `heading` with `level`, `listMarker`, `codeLanguage`, `code`,
`tableHeader`, `tableCell`, `math`, `separator`), and, only when set: `bold`, `italic`,
`strike`, `inlineCode`, `link` (its destination), `math` (the LaTeX source; `text` is the same
source, and `display` is true for display math), `indents` (outermost first: `list`,
`orderedList`, `quote`) and `gap` (space above the paragraph it starts: `block` or
`listItem`). A list marker's text is the shown marker between tabs (`"\t•\t"`, `"\t2.\t"`,
`"\t☐\t"`). A thematic break is one `body` run of `─` characters. A code block or table
inside a list or quote stays in the prose, as its runs (`codeLanguage` then `code`;
`tableHeader`/`tableCell` cells separated by tabs).

The contract grows with the desktop app. Add fields freely; renaming or removing one bumps
`hb_version`.

## Checking it

- `swift test --package-path Packages/HermesKit --filter HermesBridgeTests`: commands,
  replies and errors, without a server.
- On the Windows host, against the Hermes in WSL (AGENTS.md, "Windows host"):
  `dart run bin/live_probe.dart <HermesBridge.dll> <url> <token> hermesapp-test`, run from
  `Apps/Desktop/hermes_bridge`. It connects, sends a prompt in a new chat, waits for the
  reply and deletes the chat.
