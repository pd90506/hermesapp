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
| `send` | `text` (may be empty when the composer has cards) | Sends a prompt in the open chat; with attachment cards, through the composer (`ChatComposer.submit`), which sends them with it |
| `interrupt` | — | Stops the running turn |
| `closeChat` | — | Stops showing the chat |
| `deleteChat` | — | Deletes the open chat |
| `reloadModels` | — | Reloads the model catalog (`ChatComposer.loadOptions`; also done when a chat opens) |
| `selectModel` | `provider`, `model` | Switches the chat's model; a switch Hermes wants confirmed shows as `pendingModelSwitch` |
| `confirmModelSwitch` / `cancelModelSwitch` | — | Answers `pendingModelSwitch` |
| `selectEffort` | `effort` (a value from `efforts`) | Sets the chat's reasoning effort |
| `attachFile` | `path` | Attaches a file from disk (a folder, or a file over the size limit, is refused before it is read); result `{"id": card id}` |
| `attachData` | `data` (base64), `filename` | Attaches bytes, e.g. a pasted image; result `{"id": card id}` |
| `removeAttachment` | `id` | Removes a card (an uploaded image is taken back off the session's queue) |
| `dismissComposerError` | — | Clears the composer's `error` |
| `decidePaste` | `types` (uniform type identifiers on the clipboard), `string`, `files` (paths) | What a paste does (`ClipboardPolicy`): result `{"decision": "text"}`, `{"decision": "files", "files": [...]}`, `{"decision": "imageData", "type": uti}` or `{"decision": "fileItems"}` |
| `setPins` | `server` (a UUID the app keeps per server), `pins` (as `pinSession` last answered, or none) | Hands the bridge the app's saved pins (`SessionPins`); the app sends it before `connect` |
| `pinSession` | `id`, `pinned` (default true) | Pins or unpins a listed session; result `{"pins": ...}`, for the app to save |
| `imageData` | `path`, `profile` | A sent image's bytes from the gateway, for its thumbnail: result `{"data": base64}` |
| `renameSession` | `id`, `title` | Renames a listed session (`GatewayConnection.rename`); one not open here is opened first, as on the Mac |
| `forkSession` | `id` | Copies a listed session into a new one (`fork`), which opens |
| `archiveSession` / `deleteSession` | `id` | Archives, or deletes for good, a listed session; it leaves the pins: result `{"pins": ...}`, for the app to save. Deleting the open chat closes it |
| `avatar` | `profile` | The profile's avatar image, once loaded: result `{"data": base64}`, or `{"data": null}` |
| `setAvatar` | `profile`, `data` (base64 PNG, JPEG or WebP; the app sends a 256 px square PNG) | Stores it as the profile's avatar (`setAvatar`) |
| `removeAvatar` | `profile` | Removes the profile's avatar |
| `branch` | `item` (an item id of the open chat) | Branch in New Chat from that message (`GatewayConnection.branch`); the branch opens as the chat |
| `messageSource` | `item` | What Copy Message copies (`ConversationMarkdown.messageSource`): result `{"text": ...}` |
| `conversationSource` | — | What Copy Conversation copies, the chat as Markdown (`ConversationMarkdown.export`): result `{"text": ...}` |
| `searchSessions` | `query` | Searches the list profile's sessions (`GatewayConnection.searchSessions`); the results follow as the `search` snapshot. An empty query clears them |
| `setDraft` | `text` | Keeps the composer's draft in step with the app's text field, and refreshes the slash list for it (`updateSlashSuggestions`; a lookup the gateway must answer waits 60 ms for the next keystroke, as Desktop's `use-live-completion-adapter.ts:43`) |
| `slashKey` | `key` (`up`, `down`, `tab`, `accept`, `escape`) | A key the slash list takes (`handleSlashKey`); result `true` when the list used it, `false` when the text field should have it |
| `acceptSlashRow` | `id` (a `slashRows` id) | Puts the row into the draft (`acceptSlashRow`) |
| `dismissSlashSuggestions` | — | Closes the list for this draft (`dismissSlashSuggestions`) |
| `setModelPickerRequested` | `shown` | Clears (or sets) `/model`'s request for the picker, once the app's own picker is open |
| `answerApproval` | `id`, `choice` (`once`, `session`, `always`, `deny`), `all`? | Answers an approval request (`ChatSession.answer`); the card leaves the chat snapshot |
| `answerClarify` | `id`, `selections`: `{qid: {choices: [...], other: "…"}}` | Answers a clarify request from the app's staged form, one selection per question; questions without one go as skipped. Without `selections` the request is cancelled (every question skipped) |
| `answerValue` | `id`, `value` | Answers a sudo or secret request; an empty value means "skip" |
| `refreshSubagents` | — | Re-reads the gateway's subagent roster for the chat (`subagent.list`) |
| `steerSubagent` | `id`, `text` | Queues guidance for a running subagent (`subagent.steer`) |
| `stopSubagent` | `id` | Stops a running subagent (`subagent.interrupt`) |
| `refreshUsage` | — | Reads the session's usage and context breakdown again (`ChatSession.refreshUsage`); the `usage` snapshot follows |
| `refreshCronJobs` | — | Re-reads the list profile's cron jobs; the `cron` snapshot follows |
| `refreshCronRuns` | `id` | Re-reads a job's most recent runs |
| `loadCronDeliveryTargets` | — | Reads where the profile's jobs can deliver, once per profile |
| `loadCronBlueprints` | — | Reads the profile's ready-made jobs, once per profile |
| `pauseCronJob` / `resumeCronJob` | `id` | Pauses or resumes a listed job |
| `setCronDelivery` | `id`, `deliver` | Sets where a job delivers, as a comma list (`CronJob.deliver(toggling:on:)`) |
| `triggerCronJob` | `id` | Runs a job now; answers when the run is recorded, then re-reads its runs |
| `deleteCronJob` | `id` | Removes a job for good |
| `openCronRun` | `id` (a `runs` id) | Opens a run with a session as a chat of the profile (`CronRun.historyEntry`) |
| `cronModelCatalog` | — | The models a job can pin (`GatewayConnection.cronModelCatalog`): result `{providers: [{slug, name, models}]}` |
| `createCronJob` | `draft` | Creates a job in the list profile from the editor's dialog, then re-reads the list |
| `saveCronJob` | `id`, `draft` | Saves the editor's changes to a listed job |
| `instantiateCronBlueprint` | `key`, `values` | Fills a blueprint's blanks in, which creates its job |

A job `draft`: `{name, prompt, schedule: {frequency, hour, minute, weekday, dayOfMonth,
custom}, deliver, provider, model}` (`CronJobDraft`; absent keys keep what the job already
has, `provider`/`model` together pin a model and `null` for either unpins it). `frequency`
is `daily`, `weekdays`, `weekly`, `monthly`, `hourly`, `every15Minutes` or `custom`.


## Events

Whole snapshots, sent when an observed property changes. A snapshot is not re-sent if it
didn't change.

`connection`: `state` (`disconnected`, `connecting`, `connected`, `reconnecting`, `failed`),
`detail` (the attempt number or the failure), `bots` (`name`, `displayName`, `preview`,
`isDefault`, `hasAvatar`, `avatarColor` (0xRRGGBB, the colour picked in Hermes Desktop),
`avatarID` (set once the avatar image is loaded, changing with it; `avatar` reads it) and
`activity` (`idle`, `recent`, `working`, `waitingForYou`)), `listProfile`, `sessions` (`id`, `profile`, `storedID`, `title`, `preview`,
`startedAt` in Unix seconds, `messageCount`, `isUnread`, `isPinned`, `group`, `groupTitle`),
`sessionListLoading`, `sessionListError`. Sessions come in the Mac list's order: the pinned
ones first (`group` `pinned`), then the rest in Desktop's date groups
(`GatewayConnection.sessionDateGroups`): the unlabelled head (`group` `recent`, shown under
"Sessions"), then one group per range, `group` its `SessionDateBucket.id` and `groupTitle` its
title ("Yesterday", "Last week", "September", ...). A row moves to its range once its date
(its newest message) has been read.

`chat`: `sessionID`, `storedSessionID`, `profile`, `title`, `isRunning`, `lastError`,
`pendingRequests` (the blocking server→client requests, as the transcript's cards: each
`id`, `kind` (`approval`, `clarify`, `sudo`, `secret`, `unsupported`), `method`, `headline`,
and for an approval `description`, `command`, `choices` (`value` of `once`, `session`,
`always`, `deny` with its label), for a clarify `questions` (`qid`, `question`, `choices`
as offered, `multiSelect`, `isLocked`), for a secret `envVar`, `prompt`); `items`
(`id`, `role` (`user`, `assistant`, `tool` or `system`), `text`, `reasoning`, `toolName`,
`detail`, `isActive`, `outgoingStatus`, `timestamp`, for an assistant item `markdown` and
`reasoningMarkdown` (below), and for a user item `images` (`name`, `path`, and `localID`: the
composer card it was sent from) and `attachments` (the names of its files)), and, as the
Mac lays the transcript out (below): `blocks`, `newestMessageID` (its action bar shows without
hover), `waiting` (`label`, `hint`, `since` in Unix seconds, while a reply is awaited),
`status` (the running turn's status line) and `canBranch` (false in a Bot Chat). Items also
carry, when they apply: `tool` (a tool item's call), `outcome` (`interrupted`), `isBlank` (a
reply with nothing to show yet), `hasActionBar`, `notice` and `review` (`headline`, `detail`:
a background notice written as a user turn, what the review saved) and `isCompressionNote`.

`composer`: the open chat's composer (`ChatComposer`), sent as it changes. `sessionID`,
`draft` (kept in step by `setDraft`; read it back rather than clearing the field after a
slash send, which may put a prefill or a refused command back), `model`, `provider`,
`modelLabel` (`ModelLabel.displayName`), `providers` (null until the catalog loads; each
`slug`, `name`, `models` with `model`, `label`, `isCurrent`), `efforts` (`value`, `label`;
empty when the model has no reasoning control, which hides the picker), `effort`,
`effortLabel`, `pendingModelSwitch` (`provider`, `model`, `label`, `message`), `error`,
`attachments` (`id`, `kind` (`image` or `file`), `name`, `detail`, `isUploading`,
`failure`), `uploadingFiles` (names), `isSubmitting`, `canSubmit`, `slashIsOpen`,
`slashRows` (each `id`, `header` (its category's first row), `text` (what accepting puts
in the draft), `display`, `meta`, `kind` (`command` or `skill`), `isSelected`), `slashNotice`
(Desktop's "No matches." or why the catalog failed to load), `isModelPickerRequested`
(`/model` with no argument asked for the picker; the app opens its own and clears it).

`search`: the session list's search (`GatewayConnection.search`), sent as it changes.
`profile` (the list profile, null when the connection lists none), `query` (the query the
results answer, trimmed), `results` (each `id` (`profile/storedID`, what `openSession`
takes), `profile`, `storedID`, `title` (the Bot Chat's own title for its hit, else the
row's), `preview`, `segments` (the matched text in order, matched runs `isMatch`), `role`
(whose message matched; null for id and title matches), `date` (Unix seconds),
`messageCount`, `isBotChat` (the hit's row is the profile's Bot Chat, which the app opens
with `openBotChat`)), `isSearching`, `error`, `isAvailable` (false when the connection has
no REST access).

`subagents`: the open chat's running subagents (`ChatSession.subagents.live`), separate
from the chat's own snapshot so a subagent event doesn't re-send its large JSON.
`sessionID`, `runs` (each `id`, `goal`, `model`, `status` (`queued` or `running`),
`taskIndex`, `taskCount`, `startedAt`/`updatedAt` (Unix seconds), `currentTool`, `activity`
(each `kind` (`tool`, `progress`, `thinking`, `summary`), `text`, `isError`), `summary`,
`childSessionID`).

`usage`: the open chat's context gauge and session counters, for the composer's ring.
`sessionID`, `gauge` (`used`, `max`, `percent`, `isEstimated`; null until the gateway
reports any use), `usage` (`input`, `output`, `total`, `calls`, `reasoning`, `compressions`,
`cacheHitPercent`, `tokensPerSecond`, `costUSD`, `model`), `breakdown` (`contextUsed`,
`contextMax`, `contextPercent`, `isEstimated`, `categories` each `id`, `label`, `tokens`).

`cron`: the list profile's scheduled jobs, as the sidebar's Cron tab shows them
(`GatewayConnection.cron`). `profile` (whose jobs they are, null until the first read),
`isLoading`, `error`, `isAvailable`, `jobs` (each `id`, `title`, `name`, `prompt`, `script`,
`isScriptOnly`, `state` (`effectiveState`), `nextRunAt`/`lastRunAt` (Unix seconds; null
when not waiting to fire), `lastStatus`, `lastError`, `lastDeliveryError`, `pausedReason`,
`scheduleDisplay`, `scheduleExpression`, `model`, `provider`, `deliver` (the target ids,
`local` when it names none), `overdueSince` (Unix seconds; a scheduler that stopped
ticking), `needsAttention` (the last run failed or wasn't delivered)), `runs` (by job id,
newest first: each `id`, `title`, `preview`, `startedAt`, `lastActive`, `endedAt`,
`messageCount`, `isOutputDocument`, `entryID` (what `openCronRun` takes, for a run that is
a session)), `runErrors` (by job id), `targets` (each `id`, `name`, `homeTargetSet`),
`triggering` (jobs being run now), `blueprints` (each `key`, `title`, `description`,
`fields` with `kind` (`text`, `time`, `weekdays`, `enum`), `name`, `label`, `defaultValue`,
`options`, `isOptional`, `help`, `isDeliver`).

### Transcript

`blocks` is HermesKit's grouping (`Transcript.blocks`), in order; the app only lays it out.
Each block has an `id` and a `kind`: `item` (its `item` is an id in `items`) or `work`, a
turn's work before its answer (`TurnWork`), whose `work` has `isLive`, `startedAt` (Unix
seconds), `duration` (seconds, when known), `interrupted`, `title` (the settled line,
"Completed in 45s") and `entries`. An entry has an `id` and a `kind`: `commentary` or `card`
(an `item` id), or `group` (`StepGroup`): `isLive`, `title`, `summary`, `iconTool`, and
`steps`, each `id`, `kind` (`think` or `tool`), `item`, `isLive`, `label` ("Bash"),
`summary`, `toolName`, `failed`, `workdir` and `copyText`.

A tool item's `tool` is `ToolCallView`: `toolName`, `title`, `status` (`running`, `success`,
`error`, `notice`, `warning`), `isPending`, `isFileEdit`, `isExpandable`, `opensByDefault`,
`isHidden`, `hasBody`, `showsDetail`, `rendersDetailAsCode`, `detail`, `detailLabel`,
`errorSummary`, `detailBody`, `countLabel`, `durationLabel`, `inlineDiff` (in its display
form) with its `added` and `removed` line counts, `searchQuery`, `searchHits` (`title`, `url`,
`snippet`), `stdout`, `stderr`, `terminalCommand` and `terminalExitCode`. Texts come clamped
for display (`ToolCallView.clampForDisplay`) and output without ANSI codes.

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
