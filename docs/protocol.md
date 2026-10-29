# Hermes gateway protocol — what a native client needs

This covers the part of the Hermes interfaces that the macOS and iOS apps use. The apps use the
**TUI-gateway JSON-RPC over WebSocket** exposed by the dashboard at `/api/ws`. The official Electron
desktop app uses the same interface to reach a remote gateway.

- **Sources:** paths are relative to the Hermes checkout (`~/.hermes/hermes-agent`), version
  0.21.5 (2026.9.24).
- **Contract:** the machine-readable contract is
  `apps/shared/src/gateway-contract.openrpc.json`, generated from `tui_gateway/contracts/*.py`.
  When Hermes updates, diff that file first.
- **Markers:** `[unverified]` means inferred and not confirmed in source. `[client choice]` is a
  decision made in this repo.

Swift implementation:
- `Packages/HermesKit/Sources/HermesProtocol` holds the wire types.
- `Packages/HermesKit/Sources/HermesKit` holds the client, auth and session state.

---

## 1. Discover and authenticate

### 1.1 Probe

`GET {base}/api/status` is public (`hermes_cli/dashboard_auth/public_paths.py:9-27`). It returns,
among other fields:

```json
{"version":"0.21.5","auth_required":true,"auth_providers":["basic"],"auth_flows":["cookie","native_pkce"], "gateway_running":true}
```

- `auth_flows` always contains `cookie` when the dashboard is gated.
- It adds `native_pkce` when at least one interactive provider exists; a password provider such
  as `basic` counts (`hermes_cli/web_routers/status.py:361-383`).

`{base}` is `http(s)://host[:port][/prefix]`. The desktop app normalises user input the same way
`GatewayEndpoint` does: it adds `http://` to a bare `host:port` and strips the query and fragment
(`apps/desktop/.../connection-config.ts:47-81`).

### 1.2 Credentials accepted by `/api/ws`

The checks live in `_ws_auth_reason` (`hermes_cli/web_server_chat.py:250-374`). All of them run
**before** the socket is accepted:

| Mode | How | Notes |
|---|---|---|
| Ticket (gated) | `?ticket=<t>`, or subprotocols `hermes-gateway-v1` + `hermes-gateway-ticket.<t>` (:207-222, :299-320) | Single-use, 30 s TTL, in-memory (`dashboard_auth/ws_tickets.py:21,49-61`). The server echoes only `hermes-gateway-v1`, and only on the subprotocol path. |
| Access token (gated) | `?token=<session access token>` (:332-365) | Same check as REST `Authorization: Bearer`. Long-lived and in the URL; prefer a ticket. |
| Legacy session token (un-gated) | `?token=<dashboard session token>` (:369-374) | Only on a **loopback** bind, which also refuses non-loopback peers (:139-159). From another device that means a tunnel. `--insecure` no longer turns the gate off; any non-loopback bind is gated (`hermes_cli/web_server.py:522-530`). |

- On failure the server closes with 4401 (auth), 4403 (host/origin) or 4403 (chat disabled)
  (`hermes_cli/web_routers/chat_ws.py:139-151`).
- **These closes happen before accept, so the client sees a plain HTTP 403 on the upgrade, not a
  close code.** A client cannot tell an expired ticket from a host/origin rejection.
  `GatewayConnection.describe` says so.
- Native clients send no `Origin` header, and the origin check allows that (`web_server_chat.py:167-194`).

`[client choice]` The app sends the ticket in `?ticket=`, as the desktop app does
(`connection-config.ts:91-97`). It mints a **new ticket for every connection attempt**
(`main.ts:8158-8187`).

### 1.3 Getting a ticket

`POST {base}/api/auth/ws-ticket` returns `{"ticket":"…","ttl_seconds":30}`. It takes no body,
and GET is rejected (`dashboard_auth/routes.py:486-494`). It requires an authenticated session in
one of two forms:

- **Cookie session (password providers such as `basic`)**
  - Request: `POST {base}/auth/password-login` with
    `{"provider":"basic","username":…,"password":…,"next":""}` (`routes.py:392-446`).
  - Success response: `{"ok":true,"next":"/"}`. The tokens arrive **only** as `Set-Cookie`
    (`hermes_session_at`/`_rt`/`_provider`, with a `__Host-`/`__Secure-` prefix over HTTPS;
    `dashboard_auth/cookies.py:27-51`).
  - When the access cookie expires, the server refreshes it from the refresh cookie on its own
    (`middleware.py:185-202`).
  - Errors: 401 for bad credentials, 429 after 10 attempts per IP per minute.
  - **App mode "Username & password"** uses this flow: it logs in only when a ticket mint returns 401.
- **Bearer (native PKCE, RFC 8252)**
  - `GET {base}/auth/native/authorize?code_challenge=<S256>&code_challenge_method=S256&redirect_uri=http://127.0.0.1:<port>/…&state=…[&provider=basic]`
    (`routes.py:269-314`). The `redirect_uri` must be a loopback HTTP address; custom URL schemes
    are rejected (`routes.py:222-256`).
  - The browser ends up at `redirect_uri?code=…&state=…`.
  - `POST /auth/native/token {"code","code_verifier"}` returns
    `{access_token, refresh_token, token_type:"Bearer", expires_at, provider, user_id}`
    (`routes.py:499-516`). The code is consumed even when the request fails.
  - `POST /auth/native/refresh {"refresh_token","provider"}` returns the same shape with a
    **new** refresh token (`routes.py:519-547`).
    - A rejected refresh token (expired, revoked, or the `basic` secret changed) is 401
      `{"error":"session_expired","detail":"Refresh token expired or invalid; start a new sign-in."}`
      (`routes.py:544-547`). An unreachable provider is 503 (`routes.py:537-538`).
    - Hermes coalesces refreshes of the same refresh token: one provider call, and its result is
      cached for 30 s (a rejection for 5 s) and handed to concurrent callers
      (`dashboard_auth/refresh_singleflight.py:1-11,24-29,53-83`). Providers with
      refresh-token reuse detection revoke the whole session when an already-rotated token is
      replayed after that window. `basic` tokens are stateless and have no reuse detection
      (`plugins/dashboard_auth/basic/__init__.py:157-167`).
  - Use the token as `Authorization: Bearer` for the ticket mint. An expired or invalid bearer
    gets 401 `{"error":"session_expired","reason":"invalid_or_expired_session",…}`
    (`middleware.py:65-79,163-175`).
  - `[client choice]` **Refresh.** `GatewayCredential.native(NativeTokenSession)` holds the pair.
    - Per connect it refreshes at most once: before the mint if `expires_at` is less than 60 s
      away, otherwise after the mint returns 401. Then it mints again with the new token. A
      second 401 is final (`DashboardError.unauthenticated`).
    - Refreshes are single-flight per `NativeTokenSession`. Callers holding the same rejected
      access token share one request, and a caller whose token was already replaced reuses the
      new one. This does not rely on the server's 30 s cache.
    - The new pair goes to the app's `onRotate` callback, to be saved, **before** any request
      uses it, so a relaunch never replays a rotated refresh token.
    - A rejected refresh token throws `DashboardError.refreshRejected`. `GatewayConnection` then
      stops reconnecting and the user has to sign in again.
  - `.bearer(accessToken:)` (access token only) is never refreshed.
  - **App mode "Access token (ticket)"** takes an access token only, as `.bearer`. The package
    has the PKCE helpers (`PKCE`, `DashboardClient.nativeAuthorizeURL/exchangeNativeCode`) and
    `NativeTokenSession`. The loopback-listener UI and token-pair storage are not built yet.
- `basic` access tokens last 12 h and refresh tokens 30 days. If no `dashboard.basic_auth`
  secret is configured, all tokens become invalid when the gateway restarts
  (`plugins/dashboard_auth/basic/__init__.py:32-33,191-202`).

## 2. Framing

- Each WebSocket text frame carries one JSON-RPC 2.0 object (`tui_gateway/ws.py:1-4,408-410`).
- **Client requests:** `{"jsonrpc":"2.0","id":"r7","method":…,"params":{…}}`. The server echoes
  whatever id it receives; `params` must be an object or omitted (`server.py:903-906`).
  `[client choice]` The app uses ids `r1`, `r2`, …, the shared TS channel's default
  (`json-rpc-channel.ts:265`). The Desktop app overrides that with numeric ids
  (`apps/desktop/src/api/client.ts:36`). Either works.
- **Responses:** `{"id":…,"result":…}` or `{"id":…,"error":{"code","message","data"?}}` (`server.py:873-879`).
- **Events** are notifications with method `event` (`server.py:693-696`):
  ```json
  {"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"<runtime sid>","payload":{"text":"Hel"},"seq":42}}
  ```
  - `seq` is a per-session counter. It is stamped only when `session_id` is non-empty
    (`event_replay.py:67-87`).
  - Global events use `session_id: ""` and carry no `seq`.
  - `payload` is omitted when empty.
- **Server→client requests** are real JSON-RPC requests with ids `srq-<12hex>` (§5).
- **Error codes.** This is a **subset**: the codes a chat client is likely to see. Handlers define
  many more 4xxx/5xxx codes; treat unknown codes as failures of that call.

  | Code | Meaning |
  |---|---|
  | -32700 | parse error |
  | -32600 | invalid request |
  | -32601 | unknown method |
  | -32602 | invalid params |
  | -32603 | internal error |
  | -32000 | handler crashed (pool-dispatched handler) |
  | 4000 | contract validation failed |
  | 4001 | session not found |
  | 4007 | session no longer live; retry resume (stale runtime id on resume/activate/submit) |
  | 4009 | session busy (truncating submit), or a disconnect interrupt is still settling |
  | 4064 | profile unavailable |
  | 4090 | slot limit |
  | 5032 | agent starting |
  | 5035 | backend retiring, reconnect |

  Sources: `rpc_dispatch.py:13-79`, `server.py:899-980`, `methods_prompt.py:724,767`,
  `session_lifecycle.py:815-823`.
- Deltas are batched for about 33 ms per frame, and order is preserved (`ws.py:82-83,128-151`).

## 3. Connection handshake

1. **Server → `gateway.ready`.** This is the first frame
   (`ws.py:365-370`, `contracts/events.py:51-61`): `{type:"gateway.ready", payload:{skin, change_events, heartbeat, replay_epoch}}`.
2. **Client → `client.capabilities {server_requests:true}`.** The reply is
   `{server_requests:[…methods], declines_not_shown}`.
   - **This step is required.** Without it the gateway never sends approval or clarify requests
     to this socket; it fails them immediately (`server_requests.py:30-34`).
3. **Heartbeat.** If `heartbeat` is true, send `gateway.ping`. The WS read loop answers it inline,
   even while handlers are busy (`ws.py:420-424`).
   - The desktop pings every 15 s and drops the socket after 45 s with no inbound frame
     (`json-rpc-channel.ts:154-155,526-567`). `GatewayClient` does the same.
4. **Back-pressure.** The server drops a client whose backlog overflows (close code 1011,
   `transport.py:143-155`), or whose send blocks for 30 s (`ws.py:69`). The client is expected to
   reconnect and replay.

## 4. MVP methods

All contracts are in `tui_gateway/contracts/` (`sessions.py`, `prompt_voice.py`). **Session ids:**
`session.list` returns *stored* ids, `resume`/`create` return a *runtime* `session_id`, and every
other call takes the runtime id.

| Method | Params (subset) | Result (subset) | Source |
|---|---|---|---|
| `session.list` | `{limit?, include_hidden?, title?, profile?}` | `{sessions:[{id, title, preview, started_at, message_count, source}]}`. With `title`: an exact-title lookup (§8.2). | sessions.py:221-246 |
| `session.create` | `{title?, cwd?, model?, provider?, source?, close_on_disconnect?=false, profile?, hidden?=false, follow_profile_config?=false}` | `{session_id, stored_session_id, message_count, messages, info}`. The DB row appears on the first prompt. | sessions.py:118-151 |
| `session.resume` | `{session_id:<stored id or exact title>, profile?, omit_messages?, defer_history?}`. The app always sends both flags as `true` (§4.1). | `LiveSessionSnapshot`: `{session_id, message_count, messages:[TranscriptMessage], info, session_key, resumed?, running?, status?, inflight?, open_requests?, pending_approval?, hydrating?, messages_omitted?, …}` (see the note on stored keys below) | sessions.py:73-98,182-202; methods_session.py:898-914; server.py:3172-3186 |
| `session.activate` | `{session_id:<runtime id>, omit_messages?}` | same snapshot. **Re-binds this socket to a live session and cancels its orphan reap**; 4001/4007 if it is gone. | methods_session.py:1160-1172 |
| `session.history` | `{session_id}` | `{count, messages}` | sessions.py:484-494 |
| `prompt.submit` | `{session_id, text, queued?}` | `{status:"streaming"\|"queued"\|"steered"\|"redirected", user_row_id?}`. For an idle session it returns immediately and the turn streams as events. A busy session queues, steers or redirects according to `display.busy_input_mode`; `queued:true` always queues ("the busy path must hold it, never redirect/steer", prompt_voice.py:35). The Desktop allows 1800 s for the ack (`apps/desktop/src/api/client.ts:27`), and so does `GatewayClient`. It also re-binds a detached session (methods_prompt.py:741-747). | prompt_voice.py:26-77; methods_prompt.py:681-831 |
| `session.interrupt` | `{session_id}` | `{status:"interrupted"\|"not_interrupted"}`. It also cancels the session's open server requests. | sessions.py:598-614 |
| `session.close` | `{session_id}` | `{closed}`. The stored row stays resumable. | sessions.py:385-394 |
| `session.title` | `{session_id, title}` | `{title, pending}`. Persists the row now if it has none yet; a title another row holds is 4022 (§8.2). | sessions.py:306-317; methods_session.py:1220-1250 |
| `profiles.list` | `{include_sessions?=true}` | `{profiles:[ProfileRow], bot_mode_protocol, install_id}` (§8.1) | profiles_vault_complete_foreign_subagents.py:116-186; methods_profiles.py:281-302 |
| `session.events.since` | `{session_id, last_seen}` | `{events:[event params], latest_seq, truncated, count, epoch, open_requests}` | sessions.py:717-731 |
| `approval.respond` / `request.answer` / `clarify.lock` | see contract | alternatives to answering the server-request frame (§5) | prompt_voice.py:251-330 |

- **Stored keys.**
  - `stored_session_id` is only in the `session.create` result.
  - Resume and activate payloads carry the stored key as **`session_key`**, with `resumed`
    echoing the request (`methods_session.py:908-911`, `server.py:3176`).
  - Lazy `info` lacks it too (`server.py:2831-2839`).
  - The `session.title` event's `session_id` is the stored key (`prompt_turn.py:795-797`).
  - Compression can rotate the key; a later `session.info` carries the new `stored_session_id`.
  - `ChatSession` seeds the key from the list row it opened, then follows `session_key` and
    `session.info`.
- `TranscriptMessage` is `{role, text?, content?, tool_call_id?, timestamp?, row_id?, name?,
  context?, args?, reasoning?, …}` (`contracts/common.py:158-176`).
- `inflight` is `{assistant, streaming, user, error?, status?, recoverable?, …}`
  (`sessions.py:29-43`).
  - Usually it holds the text streamed so far for a running turn.
  - With `error` set (and `streaming:false`) it is a **retained failed turn**, which is over and
    must render as failed (`session_auto_continue.py:524-552`).
- On a cold rebuild, `inflight` is null (`methods_session.py:898-914`).

### 4.1 Opening a chat: bounded resume, transcript in REST pages

A plain `session.resume` sends every message of the lineage in its reply, read before the reply
is sent. A permanent Bot Chat only grows, so the app opens every chat the way Hermes Desktop does
(`apps/desktop/src/app/session/hooks/use-session-actions/index.ts:2169-2194`): a bounded resume,
plus the newest page of the transcript over REST.

**Resume flags** (`SessionResumeParams`, `apps/shared/src/gateway-contract.openrpc.json`;
`tui_gateway/methods_session.py:624-641`):
- `omit_messages: true`: `messages` is `[]` and `message_count` is the stored size
  (`methods_session.py:689-691,898-909`). A live session's payload says `messages_omitted: true`
  (`server.py:3163-3175`).
- `defer_history: true`: a cold resume answers with a bounded ack (`_resume_deferred`,
  `methods_session.py:949-967`): `hydrating: true`, `status: "resuming"`, `inflight: null`,
  `running: false`. The model history loads on a background thread (`server.py:2968-3025`), and a
  turn waits for it (`_await_resume_history`, `server.py:1066-1074`).
  - When the session is already live, the ack is the live payload with `messages: []` and
    `hydrating` from the live record (`methods_session.py:880-895`). It keeps `running`,
    `inflight` and `open_requests`.
  - The resume size guard (`sessions.max_resume_messages`, error 4130) then counts the tip segment
    only (`methods_session.py:854-869`).
  - `[unverified]` A non-Desktop `source` makes the hydration read the display history as well
    (`model_history_only` is only set for `source == "desktop"`, `methods_session.py:961-963`).
    That cost stays on the server; nothing more goes over the wire.
- `source`: the runtime's source; without one it is the gateway's own platform, `tui` under the
  dashboard (`_new_runtime_ids`, `methods_session.py:65-67`; `_resolve_session_source`,
  `server.py:1570-1573`). A branch from the chat is stored under it (`_session_source`,
  `methods_session_branch.py:110`). Desktop resumes with `desktop`
  (`use-session-actions/index.ts:2084-2088`).
  - `[client choice]` The app always sends `desktop`, as Desktop does
    (`SessionSourceSettings.newSessionSource`, not a setting): on `session.create`, on resume and
    on Fork's `session.branch_stored`. Before, a branch was stored as `tui` and a list hiding `tui`
    left it out.

**Newest page:**
`GET {base}/api/sessions/{id}/messages?profile=<p>&order=latest&limit=120&offset=0&include_compacted=true&inline_images=false`
(`hermes_cli/web_routers/sessions.py:685-729`).
- `{id}` is any stored id of the lineage; the server follows it to the tip (`:697`) and includes
  compression ancestors (`:709-711`).
- `order=latest` pages back from the newest row but returns the page oldest first
  (`hermes_state_messages.py:1384-1431`, `rows[::-1][offset:][:limit][::-1]` at :1409).
- `limit` is capped at 500 (`:702`). 120 is Desktop's `LATEST_SESSION_MESSAGES_LIMIT`
  (`apps/desktop/src/api/sessions.ts:502`).
- `include_compacted=true` keeps the turns that in-place compaction archived.
- `inline_images=false` turns image parts into `[image]` (`sessions.py:636-646`); the apps show
  no images. `[client choice]` Desktop leaves the default (`true`).
- `profile` picks the profile's state.db. Omitted, it reads the dashboard's own profile.
- **Response:** `{session_id, profile, messages, pagination:{limit, offset, order, returned}}`.
  - The rows are raw state.db rows (`hermes_state_common.py:449-480`) as `_row_to_message_dict`
    returns them (`hermes_state_messages.py:1311-1333`): `id`, `role`, `content` (a string or
    parts), `tool_calls`, `tool_call_id`, `tool_name`, `reasoning`, `display_kind`, …
  - `_project_for_display` (`sessions.py:617-682`) keeps one output row per row. It marks
    scaffolding `display_kind: "hidden"` instead of dropping it, and adds `display_content` to
    compaction summaries and steers.
  - They are **not** the `TranscriptMessage` shape `session.resume` sends. The app projects them
    the way `_history_to_messages` does (`tui_gateway/session_history.py:285-362`); see
    `StoredMessageProjection`. That includes the user-text rewrites: Discord trigger notes are
    removed (`:13-15,307-308`), and a slash-skill turn shows `/skill args`
    (`:239-241,349-352`, `agent/skill_commands.py:101-171`).
  - `[client choice]` Like Desktop, the session's opening user row stays visible when compaction
    stamped it hidden (`apps/desktop/src/app/chat/transcript-backfill.ts:29-71`, #96875). That also
    holds when the beginning turns out to be an empty older page (a history of exactly a page):
    the hidden prompt already loaded is shown then. Desktop does this with an origin read
    (`transcript-backfill.ts:599-622`).
- **Errors:** an unknown session is 404 `{"detail":"Session not found"}` (`sessions.py:714-715`).
  A corrupt store is 503 (`:153-168`).
- **Auth** is the dashboard's, with the same credential as the socket:
  - On a gated dashboard: `Authorization: Bearer <access token>`
    (`dashboard_auth/middleware.py:153-175`), or the cookie session from `/auth/password-login`.
  - On an un-gated loopback dashboard: the session token as `Authorization: Bearer`
    (`hermes_cli/web_server.py:452-463,697-715`).
  - `[client choice]` Native token pairs refresh once, as for the ticket mint (§1.3): before the
    call when the token is known to have expired, otherwise after a 401. Password mode logs in
    again after a 401.

**Older pages:** the same call with `offset=<rows already received>`.
- The offset counts **display rows**, `hidden` ones included: one per `display_order` group of a
  segment, or per row of the deduped merged lineage (`hermes_state_messages.py:1336-1357,1402-1409`).
  The projection keeps them 1:1, so the app counts the rows it received, as Desktop does:
  `pagination.offset + messages.length` (`apps/desktop/src/store/transcript-tail.ts:132-153`).
- A page shorter than `limit` is the first page of the session.
- Rows stored after the newest page was read shift every offset toward the past, so the next page
  overlaps rows already held. The overlap is dropped by row id, which is also how Desktop merges
  (`app/chat/transcript-backfill.ts:10-16,89-192`).
  - Rows named by live acks are deliberately **not** added to the offset. A receipt can name
    model-only rows, or rows that fold into an existing display row (compaction during the turn),
    and counting them would skip rows. Overlap is harmless; a gap is not.
  - Rows that leave the display read shift offsets the other way. For example, a queued prompt's
    accept-time row is deactivated when the prompt runs (`session_auto_continue.py:387-390`), and
    the read counts only active or compacted rows (`hermes_state_messages.py:1340-1356`).
    `[client choice]` Each older page therefore starts 10 rows early
    (`Transcript.olderPageOverlap`), and the overlap is dropped like any other. More than 10 such
    rows inside one loaded window would still skip rows.
  - A rewind by another client shrinks the transcript too, possibly by more than 10 rows.
    `[unverified]` Not handled; the app has no rewind.
- At most one older page is in flight per chat.

**Old gateways:**
- A response without `pagination` is the whole history, as in Desktop
  (`transcript-tail.ts:132-153`).
- If `pagination.order` is not `latest`, the gateway pages but ignored `order`, and the page holds
  the oldest rows. A short page is still the whole history. Otherwise the app reads the rest
  oldest first, 500 rows per page, as Desktop's `completeTranscriptForOrderlessBackend` does
  (`api/sessions.ts:579-592,653-698`).
  - `[client choice]` The read is bounded. It fails (`HistoryReadError`) when a page brings no row
    it has not seen, i.e. the gateway ignores `offset` too, or when it passes 20,000 rows. Desktop
    bounds the same read by size (`maxJsonChars`). A retry would fail the same way, so the chat
    shows its history as unavailable, with no Retry.
- A resume ack that still carries `messages` (a gateway that ignores `omit_messages`) is used as
  the whole history, and no page is read.
- An ack that says it left the messages out (`hydrating` or `messages_omitted`) is always followed
  by one page read, even with `message_count: 0`. That count is the tip segment's row counter
  (`methods_session.py:956-957`). Acks that never omit anything are complete when empty:
  `session.create`, and the resume of a live session with no row yet (`methods_session.py:726-750`).
- With no REST access at all, the chat opens without its history and says so, with no retry.

**Live events and stored rows: the stored rows are the source of truth.** `[client choice]`
(`Transcript`, `ChatSession.rereadIfNeeded`)

- **Which first read to trust.** The page read alongside the resume can predate a turn that
  finished before this socket was attached; this socket never saw that turn's events. That read is
  kept only when the ack says `hydrating: true`, meaning no turn has run on that runtime session
  yet. Otherwise the page is read again after the ack, and from then on every turn reaches this
  socket.
- **What is on screen.** The stored rows, plus live items only for what isn't settled yet:
  - the turn streaming now, including the turn that was running at open (`inflight`);
  - prompts sent here;
  - finished turns, until their re-read lands.
- **No matching.** Live and stored content are never matched: no text, call-id or anchor
  comparison. The one exception is a row id Hermes gives for a prompt sent here: the
  `user_row_id` of a `prompt.submit` answered `streaming` names that prompt's own stored row
  (see "Proven by its row id" below). While a turn runs, some content can show twice:
  - the stored part of a turn that was already running at open (Hermes stores each tool round
    before its tools run, `agent/turn_tool_round.py:127-130`);
  - its echoed `inflight.user`;
  - a prompt the history already holds, sent without a `user_row_id` (queued, steered, redirected,
    or row-less `streaming`; see below).
- **When a turn finishes** (`message.complete`, from any source), the app reads the newest rows
  again:
  - same endpoint, `order=latest`, 120 rows;
  - older pages only until one overlaps the shown rows, at most 4 pages, never the whole history;
  - one re-read at a time, and a turn that finishes meanwhile gets the next one.
- **What the re-read does.** It replaces the shown history from the first shown row it holds
  onward. Older pages the user loaded stay. If it overlaps nothing (more new rows than 4 pages), it
  becomes the history, and older rows load again by scrolling.
- **A re-read that lands while a turn is open** (a retry of an earlier turn's failed read, the
  read a submit answer asks for, a chat shown again) also holds that turn's rows stored so far,
  which the turn shows live. Only the rows before the first of them go in: a tool row or an
  assistant row of a call the turn shows live, or an assistant row with the text of one of its
  live segments (whitespace aside). That row and every newer one wait for the turn's own re-read.
  Call ids (`deterministic_call_id`, `agent/message_sanitization.py:505-508`) and phrases repeat
  across turns, so these rows are never cut:
  - rows up to the open turn's own prompt row, when known (its `streaming` answer's
    `user_row_id`, whichever comes first, the answer or `message.start`);
  - rows up to the newest one the history held, or a finished turn's receipt named, when the turn
    opened here;
  - a row the history shows already.

  A cut can still fall inside an earlier turn this chat cannot place: one that sent no receipt
  (`prompt_turn.py:874-900`), one closed here without `message.complete`, or one run by another
  client, while the open turn's prompt row is unknown. It is unknown for a turn this chat did not
  send, a prompt answered `queued` or a row-less `streaming` one (an image only: no `user_row_id`),
  a turn reopened after an `error` closed it, and a prompt whose expectation a `running: false`
  ended before its `message.start`. So a cut
  page drops a finished turn's live items only if its rows went in: the open turn's prompt row
  went in (every turn that finished before it is below it, since a `streaming` answer means no
  turn ran at submit), or the turn's receipt rows did. Otherwise its live items stay until a read
  that is not cut, so it can show twice for a while but is never hidden. Rows of another client's
  turns that were cut show at the open turn's re-read.
- **What the re-read drops.** A turn's rows are stored before its `message.complete` is emitted
  (`prompt_turn.py:1153-1182`), so a re-read requested after it holds them. That includes a turn
  stopped by the user:
  - Stop during the model call stores the partial reply as an assistant row
    (`agent/turn_api_call.py:206-214`; a repetition loop is stored hidden on purpose);
  - Stop during a tool stores a closing row (`agent/message_sanitization.py:287-299`).

  It drops:
  - the live items of every turn that finished before the re-read was requested;
  - prompts sent here, but only if the session was quiet throughout the re-read: no turn running,
    none started since it was requested, and every `prompt.submit` answered.

  - **Proven by its row id: at once, quiet or not.** A prompt answered `streaming` with
    `user_row_id` N goes as soon as the shown history holds stored row N: when a re-read installs
    it, or when the answer arrives and an earlier re-read already showed it. Row N is that prompt
    (`methods_prompt.py:815-821`), so nothing else is needed. Desktop ties its optimistic message to
    the same id (`apps/desktop/src/app/session/hooks/use-prompt-actions/submit.ts:969-986`). The row
    must be *shown*: a page that does not hold it, a row Hermes hides, or a row with the same text
    and another id proves nothing, and the bubble stays.

    This settles the warm-agent race of issue #5. The answer asks for a re-read, `message.start`
    arrives while that read is in flight, and the page lands holding row N. The read is not quiet
    (a turn started), so before this rule the bubble stayed beside its stored row for the whole
    turn, and until the next turn if the turn's own re-read failed. It also settles a fast reply
    whose `message.complete` and re-read land before the answer: the bubble stays while no answer
    has proved it, then goes when the answer arrives.

  The quiet rule exists because a follow-up turn announces itself with `message.start` before it
  stores its prompt (`prompt_turn.py:421-427`). Follow-up turns are a queued prompt, or a steer the
  turn couldn't deliver, which is re-queued after the turn (`prompt_turn.py:438-450`,
  `agent/turn_finalizer.py:742-746`). Until such a turn finishes, the bubble stays.

  How many quiet re-reads a prompt needs depends on its answer:
  - **`streaming` with `user_row_id`: one, if its row id has not settled it first** (above). Its
    row was written before the answer (`methods_prompt.py:815-819`), so the first quiet re-read
    holds it, and the bubble never sits below its own reply.
  - **`streaming` without `user_row_id`: its own turn.** No row was written at submit. Causes:
    - an empty text, i.e. an image-only prompt (`_write_submit_user_row` returns early,
      `session_workdir.py:621`);
    - compute-host isolation;
    - a submit-time write that failed (`methods_prompt.py:798-803`, `session_workdir.py:639-641`).

    The turn writes the row when it runs, and it can start well after any quiet re-read: the agent
    build first waits for a deferred history (`server.py:1164`). So the bubble joins that turn:
    the one running now if it started after the prompt was shown, else the next to start. It goes
    with the turn's other live items, at the first re-read requested after the turn finished. If
    no turn starts, it stays.
  - **`queued`, `steered`, `redirected`, and a missing status: two in a row**, the second requested
    once the first had landed. These answers carry no `user_row_id` ("absent on
    queued/steered/redirected inputs", `contracts/prompt_voice.py:69-71`). The turn receipt in
    `message.complete` (`persisted_turn.user_row_id`, `prompt_turn.py:899-903`) names a turn's user
    row, not which bubble it holds (queued prompts can merge into one turn), so it is not used. `message.start` travels on the socket in batches of about 33 ms
    (`ws.py:82-83`), and a single re-read's HTTP answer could arrive before a start that was already
    sent. By the second read, the follow-up's prompt row has been written, or its start has arrived
    and ended the quiet spell.
- **Unstored partial replies.** The segment still streaming when a turn ended stays live, and
  the rest of the turn is dropped, when the partial may not be stored:
  - `error`: always. The partial reply is kept only in memory (`session_auto_continue.py:524-552`).
  - `interrupted`: unless the segment and `message.complete`'s non-empty text, both trimmed, are
    the same reply. The normal runtime stores the partial and sends exactly it
    (`agent/turn_api_call.py:206-214`); another runtime may store nothing (the Codex app-server,
    `agent/transports/codex_app_server_session.py:583-586`, whose event text is its last completed
    message, `agent/codex_runtime.py:743-749`). The segment goes when:
    - it equals the text;
    - it ends with the text. What streamed before the current call is stored by then, or by the
      same Stop (`agent/turn_api_call.py:213`), yet can run into one segment: a redirect sends no
      event, and the text before it is stored as a placeholder (`conversation_loop.py:345-365`);
      the segment rebuilt at open holds the turn's earlier calls (`session_history.py:400-408`);
    - the text ends with it: a prompt sent here during the call split the call's text into two
      segments, and the stored text holds both.

    An empty text keeps the segment. A repetition loop, sent as its sentinel, is stored hidden on
    purpose and goes as well.

  This compares a turn with its own event, never with stored rows. Where the event and the stored
  rows disagree, it leaves a duplicate; text Hermes streams but never stores goes, as it does for a
  `complete` turn (see Known limits). Bot Mode rewrites the text of `complete` turns only
  (`prompt_turn.py:18-27,936-937`), so an interrupted turn settles the same there.
- **Prompts sent during a reply.** The composer allows this. The prompt shows at once, whatever
  `prompt.submit` answers:
  - `streaming`: stored at submit, `methods_prompt.py:817-820`;
  - `queued`: stored at accept, `session_auto_continue.py:436-439`, and merged into an earlier
    queued prompt's row when sent in a burst, `:308-335`;
  - `steered`: stored when delivered, `agent/prompt_builder.py:595-601`;
  - `redirected`: `agent/interrupt_control.py:261-305`.

  Once the session is quiet, the stored rows show what Hermes made of it, including a merge, or a
  queued prompt Hermes retired instead of running (`methods_session.py:693-710`). An answer that
  arrives while no turn runs asks for a re-read itself, since no turn will finish to settle it. A
  submit that fails keeps its bubble, since only that bubble holds the text.
- **Tool rows.** Call ids repeat across rounds and turns (`deterministic_call_id`,
  `agent/message_sanitization.py:492-495`). `tool.start` reuses a live row only while that call is
  still running; `tool.complete` finishes the running row of that call, or adds one for a tool that
  started before this chat attached.
- **Nothing keeps spinning.** At `message.complete`, every live item stops; empty reply bubbles go.
- **Item ids are unique and stable** (SwiftUI's `ForEach`). A stored item is always `row-<id>`,
  whatever live rows exist, so it keeps its identity across re-reads. Live ids are `local-<n>` or
  `tool-<call>`. Any item whose id is taken, a live row or a row a page repeats, gets a suffix.
- **A cold restore** (§7 step 4) rebuilds the transcript from scratch. Any read in flight for the
  old one is cancelled, and is discarded if it lands anyway.
  - `[client choice]` Desktop instead grafts the new page onto the older rows it holds
    (`transcript-backfill.ts:381-438`).
- **No re-read on old gateways.** A history read from a gateway without `order=latest` paging is
  never re-read, because that read is not bounded. Its live items stay.

`[unverified]` Known limits:
- **Temporary duplicates while a turn runs:** the stored part and echoed prompt of a turn that
  was running at open, and a prompt the history already holds that has no `user_row_id` to prove
  it (queued, steered, redirected). They clear when that turn's re-read lands. A prompt answered
  `streaming` with `user_row_id` is not among them: it goes as soon as its row shows.
- **Duplicates until a later re-read or reopening:** when a re-read fails. The next finished turn
  re-reads.
- **Duplicates that only reopening clears:**
  - A turn running at open that ends with `error` before any tool boundary since the open: its
    one live segment holds both stored text and the unstored partial, and is kept whole so nothing
    is lost.
  - An `error` turn whose partial reply Hermes did store after all, e.g. collapsed into an
    assistant row after a mid-stream death and continuation (`agent/turn_recovery.py:807-820`).
  - An `interrupted` turn whose stored partial differs from the event's text, or whose runtime
    stored it but sent other text.
  - An old gateway, which is never re-read.
- **Older pages after a long gap:** after more new rows than a re-read covers, older pages the
  user loaded are dropped from view. They load again by scrolling.
- **A gap from deactivated rows:** more than 10 rows leaving the display read inside one loaded
  window skips rows on the next older page (see Older pages).
- **Foreign turns:** a turn started by another client shows no prompt bubble while it streams (no
  event carries it); its stored prompt shows after its re-read.
- **Prompts Hermes drops vanish.** A queued prompt Hermes retires, or a steer that Stop wipes
  (`agent/interrupt_control.py:246-247`), disappears after the quiet re-reads, as the stored rows
  say. The same goes for a pre-redirect partial that Hermes keeps only as model-facing text
  (`conversation_loop.py:345`).
- **Request rate.** Each finished turn costs one re-read of 120 rows (two after a busy prompt).
  Re-reads run one at a time.
- **A Stop that races a finished response.** If Stop clears a redirect between the model call's
  `finally` and `clear_interrupt` (`agent/turn_api_call.py:148-155`), Hermes discards the fully
  streamed response and stores nothing. When the event carries that text, the client drops it
  too. The window is microseconds wide.
- **Reasoning of an interrupted turn.** The interrupted row stores no reasoning, so reasoning
  streamed during the turn goes with the re-read, as a reopen shows it.
- **Streamed text Hermes never stores** goes with the re-read, for any turn status, as a reopen
  shows it:
  - ephemeral scaffolding, e.g. narration streamed with `finish_reason=tool_calls` but no tool
    calls, before the re-prompt (`agent/turn_final_response.py:289-316`,
    `session_persistence.py:43`);
  - the preamble of an attempt whose tool call was truncated and retried
    (`agent/turn_truncation.py:400-415`);
  - the `⚠ Connection dropped mid tool-call; reconnecting…` marker and the preamble before it
    (`agent/chat_completion_helpers.py:3730-3747`).

### 4.2 Switching chats

Where the time goes when a chat opens:
- **Round trips, in sequence:**
  - **A Bot Chat** first needs its registry lookup (`session.list` by title, §8.2).
  - **Then `session.resume`.** It is pool-dispatched (`server.py:179-191`), so it can wait behind
    other slow handlers. The deferred ack itself is cheap: it mints the runtime record and only
    schedules the history read (`methods_session.py:949-967`).
  - **Then the REST page** (§4.1). For a Sessions or launch-profile chat it is read alongside the
    resume. For a Bot Chat it could only start once the lookup had named the chat.
- **Before this change:**
  - The previous chat stayed on screen until the ack arrived. Going back to a chat paid the whole
    chain again.
  - On the client, a 120-row page costs about 0.5 ms to decode, 0.15 ms to project
    (`Transcript.installLatestPage`), and 0.07 ms per reply to parse Markdown (release build,
    Apple silicon). The wait is the network and the gateway, not the client.

What the app does now (`GatewayConnection+Revisit.swift`):
- **A warm cache, like Desktop's** (`apps/desktop/src/app/session/hooks/use-session-actions/index.ts:1378-1760`).
  - The last `warmChatLimit` (6) chats keep their `ChatSession`.
  - While this socket still serves their runtime session, they keep receiving its events, so they
    stay current.
  - Going back to one shows it at once, as it was. In the background:
    1. A Bot Chat is looked up by name again (§8.2). If its tip changed, the new tip is resumed
       into the same chat.
    2. `session.activate {session_id, omit_messages:true}` binds the runtime session to this socket
       again. Another client may have taken it (events are routed to one transport,
       `server.py:681-689`), or a reconnect dropped the binding.
    3. The newest rows are read again (`Transcript.installRereadPage`). That brings in whatever was
       stored while the events went elsewhere.
  - Stored rows stay the source of truth, and no text is matched. A turn that ended elsewhere is
    ended here too (`Transcript.reconcileRunning`); its live items wait for that re-read.
  - **4001/4007** (the runtime session is gone), or an ack naming another stored key, resumes the
    chat's stored key into the same `ChatSession`, as a reconnect does (§7).
  - Any other failure keeps the cached transcript.
  - **Sends wait for the reconcile.** The cached transcript shows at once, but a send waits
    until the reconcile has settled which runtime session the chat belongs to
    (`ChatSession.settleIdentity`). Otherwise a prompt could go to a runtime session the chat is
    about to leave: one that is gone, or a retired Bot Chat.
    - The wait can be cancelled from the composer, and then the draft comes back.
  - A send waits through a replaced reconcile too, until none is in progress.
  - **A rebuild** (`ChatSession.reset`, after a resume or a reconnect) carries no bubbles over.
    The rebuilt transcript holds only the snapshot and the stored rows, so nothing can show
    twice. Nothing typed is lost:
    - **A failed prompt's text goes back to the composer**, ahead of any draft already there,
      and its error stays on screen. Several come back in the order they were sent.
      - A failed image send already put its text and cards back when it failed
        (`ChatComposer.submit`).
      - If an input method is composing at that moment, the composition is left alone: the
        draft holds the returned text at once (a send reads it), and the text view shows it
        when the composition ends, combined with what was composed (`DraftMerge`,
        `ComposerTextView.Coordinator.showDraft`). If the draft was replaced over the
        composed stretch instead (cleared by a send), the draft wins.
    - **A send still in flight settles itself.** Its live ids are numbered above the old
      transcript's (`Transcript(snapshot:localIDsAfter:)`), so its old bubble id names nothing
      in the new one.
      - If it fails, its text goes back to the draft.
      - If Hermes took it, a re-read of the newest rows shows its stored row. If the newest
        page is not in yet, the re-read waits for it.
      - On a gateway older than `order=latest` paging, rows cannot be re-read (§4.1). There
        such a prompt does not show until the user opens the chat again. Its reply still
        streams in.
    - **A row-less prompt** (answered `streaming` without `user_row_id`, e.g. image-only, §4.1)
      is dropped: its turn stores the row.
  - **One reconcile per chat.** Going back again while one still runs on this socket joins it.
    One started on an older socket is cancelled and replaced.
  - **Late answers are dropped.** Results are applied only while their socket is still the
    connection's own; a reconnect keeps `generation`, so the client is checked too.
  - **Memory:** at most 6 chats, each holding the pages the user loaded.
- **Drafts belong to the chat** (`GatewayConnection.composer(for:)`), not to its view.
  - Opening another chat leaves the draft and attached images alone, whether that open
    succeeds, fails or is cancelled. Going back to a warm chat brings its draft back.
  - A draft goes when its chat leaves the warm cache, or on disconnect.
- **Known limits.**
  - **Eviction drops the draft.** Opening a 7th chat evicts the least recently shown one from
    the cache, and with it that chat's draft and attached images. A chat dropped because it no
    longer exists (a Bot Chat the registry lost) loses its draft too.
  - **A short gap for a row-less prompt.** An image-only prompt whose turn has not stored its
    row yet shows nothing for a few seconds after a rebuild. It appears with that turn's
    events, or with the re-read after the turn. No text is lost: it had none.
  - **A failed prompt Hermes took anyway.** A submit that failed on the client side may still
    have been accepted, e.g. when the socket dropped after the gateway took it (§10.3). After a
    rebuild its stored row shows, and its text is also back in the draft. The client cannot
    tell the two cases apart and never matches by text; the user decides whether to resend.
- **A first open** publishes `GatewayConnection.opening` at once. The app shows that chat's
  title and a spinner instead of the previous chat, until the chat is active or the open fails.
  Picking the chat already on screen meanwhile shows it again; the slower open, now
  superseded, does not take the screen when it finishes.
- **A Bot Chat's newest page** is read while its registry lookup runs, for the tip the roster
  names (`canonical_session.resolved_id`). It is used only if the lookup names the same tip; the
  lookup stays the identity (§8.2).

## 5. Events a chat client handles

From `contracts/events.py`:

| `type` | payload | Client behaviour |
|---|---|---|
| `message.start` | none | Open an assistant segment. |
| `message.delta` | `{text, rendered?}` | Append the text. |
| `reasoning.delta` | `{text}` | Append to the reasoning (`agent_callbacks.py:135-138`). |
| `reasoning.available` | `{text}` | Hermes relays the model call's content this way when its response ends. In a round that already shows text it is dropped; otherwise it is shown as the reasoning block, as Desktop does ("Rounds" below). |
| `thinking.delta` | `{text}` | **Not reasoning** (`agent_callbacks.py:117-123`). Most frames are spinner rewrites and Desktop drops them. It keeps only an "explained provider wait" matching `providerWaitText` (`⏳/⚠/↻/⚙` + "waiting on", "loading", "rate limited", …), and any other frame clears it (`gateway-event/message-stream.ts:195-205`, `store/provider-wait.ts:43-53`). Model output also clears it (`PROVIDER_WAIT_SUPERSEDING_EVENT_TYPES`, `gateway-event/index.ts:67-78`). The app keeps it in `Transcript.providerWait`, never in `status`. |
| `message.interim` | `{text, already_streamed}` | Commentary the model writes beside tool calls (`prompt_turn.py:768-773`). It seals the current round's text ("Rounds" below); the next deltas open a new bubble (`use-message-stream/index.ts:614-719`). `TranscriptItem.isInterim` marks it. |
| `tool.generating` | `{name}` | The model is writing a tool call's arguments. No row: Desktop shows a "drafting tool" status (`gateway-event/tools.ts:33-54`); `Transcript.generatingTool`. The streaming bubble is sealed. |
| `tool.start` | `{tool_id, name, context?, args?, args_text?, preview?, labels?}` | Add a tool row (`TranscriptItem.tool`, a `ToolActivity` in phase `running`). `context` is an 80-char preview; `args_text` is verbose-mode only (`events.py:261-275`). |
| `tool.complete` | `{tool_id, name, args?, duration_s?, result, summary?, result_text?, inline_diff?, todos?, revision?}` | Finish the row. **There is no tool-output or tool-progress event**: the output is `result_text`, else `result` (JSON-parsed, or the raw string, `tool_progress.py:343-346`). `inline_diff` comes with edit tools. The row is drawn from `result` (`ToolActivity.result`, `ToolCallView`), as Desktop draws its tool part (`buildToolView`); a stored tool row's content is its result too, for every tool (`applyStoredToolResult`). The contract has no `error`; Desktop reads one only for an error animation (`gateway-event/tools.ts:109`). `[client choice]` The app marks such a row `failed`. A tool still running when the turn ends is marked complete. |
| `status.update` | `{kind, text}` | Transient status line. |
| `btw.complete` / `background.complete` | `{task_id, text, question?}` | Answer to `prompt.btw` / `prompt.background` (§10.7). `text` starts with `error: ` on failure (`methods_prompt.py:1282-1315`). |
| `message.complete` | `{text: str \| JsonValue, status?: complete\|error\|interrupted, reasoning?, error?, usage?, persisted_turn?, …}` (`events.py:189,205`; decode `text` as any JSON). The app does not use `persisted_turn`; it re-reads the newest rows instead (§4.1). | **The terminal frame of every turn.** Errors inside a turn arrive here with `status:"error"`; there is no separate turn-end event (`events.py:138-208`, `session_auto_continue.py:555-581`). `[unverified]` When a turn contained tool calls, the app shows the streamed segments and uses `text` only when nothing was streamed; the doc does not say whether `text` is the last segment or the whole reply. |
| `session.title` | `{session_id:<stored id>, title}` | Rename. |
| `session.info` | `SessionLiveInfo` | |
| `error` | `{message}` | A session-level failure outside a turn. |
| `request.cancel` | `{id, method, reason}` | Remove the matching server-request card. |
| `approval.cancelled` | `{session_id, request_ids:[approval request_id], reason, …}` | Broadcast globally (`session_lifecycle.py:505-510`). |
| `sessions.changed`, `session.reclaimed`, `notification.show` / `.clear` | see §11 | Sidebar, reclaimed runtimes and notices. |

**Rounds.** `[client choice]` (`Transcript.currentRound`) One rule places a turn's text events.
A *round* is one model call of the open turn and what it showed: its live assistant items since
the round began.
- **A turn tool row ends a round.** Hermes runs a call's tools only after storing its row (`agent/turn_tool_round.py:130-163`), so `tool.start` and `tool.complete` mean every item before them is stored.
- **`tool.generating` does not end one.** It fires while the call still streams its tool calls (`agent/chat_completion_helpers.py:2643,2924`). The call's text can go on after it, and its interim then holds all of it.
- **With no tool rows in the turn,** an interim ends a round instead. Tool progress off sends no `tool.start` (`tui_gateway/tool_progress.py:291`) and no `tool.generating` (`agent_callbacks.py:156`). A tool round's interim is sent once its row is stored (`turn_tool_round.py:150-155`). Other interims are sent *before* their row is stored (rows below), so a boundary only says what came before it, not what was stored.
- **What an `error` end stored comes from the turn's receipt,** not from the event shape: `message.complete` carries `persisted_turn.row_ids` for every status (`prompt_turn.py:874-941`), built from the result's messages that the persist stamped with their row ids (`agent/session_persistence.py:266-300`).

| Event | Which round | What it does | Hermes |
|---|---|---|---|
| `message.interim` `{text}` | the current one: Hermes sends it after the call's response, before its tools run | Seals the round's text, among segments no interim sealed yet, matched whitespace-normalized as Hermes matches it. In order: (1) a segment with the interim's text is sealed; (2) if the segments' text, joined, is the interim's or its start (a partial stream, or text `tool.generating` split), the first takes it in place and the others give theirs up, so one copy; (3) an interim of this turn with that text means a repeated delivery, so it stays one row; (4) with no text in the round, the streaming bubble or the newest reasoning-only segment takes it; (5) otherwise it is appended once (Codex commentary beside a streamed partial answer). The round's segments stop streaming. | visible text, stripped (`agent/stream_delivery.py:197-216`); compared normalized (`:103-104`); a repeat is never sent (`:165-167`); the first delta after a tool round starts with `"\n\n"` (`:305-310`); Codex commentary is sent mid-stream, before the response is stored (`:188-195`, `agent/codex_runtime.py:969-972`) |
| `reasoning.available` `{text}` | the current one: sent when the call's response ends (`normalize_model_response`) | If the round shows text, the frame is that text and is dropped, so it never replaces reasoning. Otherwise it is the block Desktop shows: it fills or replaces the streaming bubble's reasoning (`use-message-stream/index.ts:526-537`). | the one emitter, `_relay_thinking`, relays the call's *content*, tags stripped, at most 500 characters (`agent/turn_response_intake.py:103-117,157-158`); only with show-reasoning on (`tui_gateway/tool_progress.py:383-386`) |
| `message.complete` `complete` | all | Every round's rows are stored; the turn's re-read replaces its live items. | rows stored before the event (`prompt_turn.py:1153-1182`) |
| `message.complete` `error` | the failing call is the current round | Every earlier round's items go with the re-read. The current round's items (after the last finished round, including segments split by a note, `/btw` or prompt, and Codex commentary of that call) stay as unstored partial text, unless the turn's receipt shows them stored: the re-read (or an older page that holds the row) settles an item that an assistant row of that receipt shows with the same text, all whitespace aside. Only that turn's rows are compared. Once every receipt row was read with no match, the item stays. Without a receipt the current round stays. | earlier calls were stored before their tools ran (`turn_tool_round.py:130-163`). The failing call's partial is often stored too: the terminal persist on retry exhaustion stores the message list (`agent/turn_recovery.py:820-826,1241`), with a streamed partial merged into one row (`settle_delivered_partial`, `:830-847`, `agent/turn_truncation.py:89-90`). It stays unstored when nothing was saved: the context-overflow stub, or a failed save before tools (`turn_tool_round.py:141-149`). The receipt is missing when Hermes cannot address the turn's rows (no committed rows, a bad user index, or preflight returning the old transcript, `prompt_turn.py:886-899`) |
| stall or degenerate continuation | the current round | Its interim seals the round's text as any interim does. Its row is not stored yet: on a later `error` end the receipt settles it. In a turn with no tool rows the interim ends its round instead, so the item goes at the re-read, stored by the final save. | the stall guard: a text-only reply announcing a next step, whenever the agent has tools (`valid_tool_names`, `agent/turn_final_response.py:180-188`); the degenerate guard: a fragment after tool work (`:189-204`). Either is appended in memory and sent as an interim with no flush, then a nudge continues the turn (`:205-237`) |
| length (stream-death) continuation | the current round | The text streamed before the stream died stays in its bubble; the continuation's text streams on into it. On an `error` end the receipt settles the partial, compared with all whitespace removed: Hermes joins two fragments with a `"\n"` where neither side has whitespace (`agent/conversation_loop.py:301-302`), which the screen never showed. A continuation that repeats 32 or more characters of the tail is stored with the overlap removed (`:298-300`): that one no row matches, so it stays live beside its row. | a stream that dies after visible text never raises: it becomes a `finish_reason="length"` stub (`chat_completion_helpers.py:3647-3667`), and the turn continues with a fragment row and a nudge (`agent/turn_truncation.py:312-345`) |
| Codex incomplete | the current round | As the stall continuation: its interim before storage; the receipt settles it on an `error` end. | `agent/turn_truncation.py:626-628` |
| `message.complete` `interrupted` | the stopped call is the current round | Hermes stores the stopped call's partial and sends it as the event's text, so only the segment still streaming may stay, and only when it is not that text (see `Transcript.finishTurn`). | `agent/turn_api_call.py:206-214`; Stop during a tool, `agent/message_sanitization.py:287-299` |

**Rich content in stored rows** (`StoredMessageProjection`, REST rows of §4.1):
- A tool row becomes a finished `ToolActivity`: name and arguments from the preceding assistant
  row's `tool_calls`, by id. Its output is kept only for `write_file`, `patch` and
  `skill_manage`, as `_history_to_messages` does (`session_history.py:322-334`); the app does not
  hold other tools' raw output in memory.
- A user row with `display_kind:"steer"` is a mid-turn steer. The REST read gives the user's own
  words as `display_content` (`web_routers/sessions.py:663-667`); `TranscriptItem.isSteer`.
- A user row that starts with `@file:` / `@folder:` lines (one per attached file, §10.5) shows
  them as `TranscriptItem.attachments` (file names) and the rest as its text, like Desktop's
  `splitLeadingAttachmentRefs` (`apps/desktop/src/components/assistant-ui/reference-kinds.ts:177-197`).
  Only the leading run is lifted; a reference typed mid-prose stays text.
- Such a row is stored as Hermes expanded it for the model: the prompt, then a
  `--- Context Warnings ---` section and an `--- Attached Context ---` section holding each
  file's whole text (`agent/context_references.py:240-246`; the expanded prompt is the stored
  one, `tui_gateway/prompt_turn.py:705-722,782-783`). Like Desktop's `displayContentForMessage`
  (`apps/desktop/src/lib/chat-messages/hydration.ts:129-145`), both sections are dropped
  (`InjectedContext.strippingAttachedContext`), so the bubble shows the file as an attachment and
  not its text. A file named only in the attached section (`📄 @file:… (N tokens)`) comes back
  as a leading `@file:` line; the `@image:` lines Hermes appends after the expansion stay.
- A snapshot that does carry messages (`session.create`, or a gateway that ignored
  `omit_messages`) is read the same way from `_history_to_messages`' shape
  (`{role:"tool", name, context, args?, tool_call_id?, content?}`, `session_history.py:285-362`).

**Local rows.** Slash-command output, notices, and `/btw` / `/bg` questions and answers
(§10.6-10.7) are shown on this device only; no stored row ever holds them, so no re-read can
settle them. `[client choice]` Such a row joins the stored part of the transcript once the newest
page is in and no unsettled live item is ahead of it, anchored to the stored row it follows, and
keeps that place when pages are installed or re-read. A row added while a turn runs moves
below that turn's rows once they are stored. A rebuild (cold resume, §7) drops them. A re-read
that replaces the whole loaded window (§4.1) puts a row whose anchor it no longer holds at the
top; older pages loaded later go above it, not around its anchor.

A failed turn (`status:"error"`) keeps every live segment of its last model call, also the ones
a local row or a prompt sealed mid-reply: none of them is stored.

**Waiting for the reply.** `[client choice]` (`Transcript.waiting`, `ResponseWaitingRow`) Between
a send and the first token, Hermes sends little that can be shown. It sends:
- the submit answer;
- `message.start`, with no payload;
- one `thinking.delta` spinner frame per API call (`agent/turn_iteration_prep.py:319-324`);
- `reasoning.delta`, only with show-reasoning on;
- `status.update`, only for lifecycle events such as compaction or memory recall;
- `notification.show` with key `agent-build-slow`, only when the agent build takes more than 30 s
  (`tui_gateway/server.py:945,989-996`, cleared by `notification.clear`).

So the app shows one waiting row in the assistant column, as Desktop's `ResponseLoadingIndicator`
does (`components/assistant-ui/thread/status.tsx:243-268`):
- **When it shows:** from the moment a prompt is sent here (before its answer) until the reply
  shows visible text (whitespace is none) or a tool row. Reasoning alone does not end it. Only
  output since the latest send, or since the turn now running started, counts: an earlier turn's
  reply, such as a failed one whose partial reply stays live, does not end a new wait.
- **When it goes:** when the app no longer counts the session as running ("Running state" below),
  or when visible output arrives, whichever is first.
- **What it shows:**
  - a pulse, still under Reduce Motion;
  - "Thinking…";
  - the time since the send. A turn this chat did not send, one running at open, counts from
    when the row appeared.
- **Hints:** when Hermes says what the wait is about, the hint replaces "Thinking…", most specific
  first:
  1. the turn's `status.update` text;
  2. an explained provider wait (`thinking.delta`, see the table);
  3. "Drafting ‹tool›…" while `tool.generating` names a tool;
  4. the slow agent-build notice.
- **VoiceOver:** the label is "Hermes is responding".
- **No bare "…":** an assistant row with nothing to show (no text, no reasoning, no
  "Interrupted") is not drawn. The waiting row stands in its place, and the reply's first line
  takes the same spot.
- **Stopped before any text:** the reply shows "Interrupted", with any reasoning that streamed, and
  no action bar. No stored row holds it, so it is a local row (§5 "Local rows"): it stays across
  re-reads, right after the turn's last committed row (`persisted_turn.row_ids`, so below the
  turn's own tool rows), or after its prompt row when the turn sent no receipt.
- **Action bar:** an assistant row gets its action bar only once it has text, and only then counts
  as the newest message whose bar stays visible. While the reply is awaited, the prompt's bar
  stays visible. Desktop shows the footer only with visible text (`assistant-message.tsx:345-356`).

**Running state** (`Transcript.isRunning`: the Stop button, the waiting row's lifetime). It is
derived from three server facts and nothing else:
- **(T)** a turn is open: from `message.start`, or any streamed event of a turn this chat saw no
  start of, until `message.complete`. A *streamed event* is one of the turn's own: `message.delta`,
  `reasoning.delta`, `reasoning.available`, `thinking.delta`, `message.interim`, `tool.generating`,
  `tool.start` or `tool.complete`. `thinking.delta` counts (Hermes streams it with the deltas,
  `_STREAMING_EVENT_TYPES`, `tui_gateway/ws.py:82`): only the session's agent sends it, from its
  API-call loop (`agent_callbacks.py:123`, `agent/turn_iteration_prep.py:319-324`), with
  show-reasoning on or off. `status.update` and `notification.show` do not count: Hermes also
  sends them between turns (heartbeats, background-process notices,
  `session_notifications.py:178,254,442`);
- **(E)** a `message.start` is still to come for a prompt sent here: one not answered yet, or
  answered `streaming` or `queued` (`expectedStarts`);
- **(B)** the server said a turn runs (`running: true` on reactivation) and none is open here yet.

*Running* is exactly T ∨ E ∨ B. *Waiting* is running with no visible output (assistant text that is
not blank, an interim, a tool row) since the latest send or turn start. The table below gives what
each answer and event does to them. "—" means unchanged.

| Server fact | Turn (T) | Expected starts (E), busy (B) | The prompt | Source |
|---|---|---|---|---|
| send (`prompt.submit` in flight) | — | E += prompt | bubble shown | — |
| answer `streaming` | — | — (its turn starts next) | row id kept for the drop rule (§4.1) | `methods_prompt.py:668` (running set before the answer), `:815-821` |
| answer `queued` | — | E keeps it, as queued | quiet re-reads settle it | `session_auto_continue.py:431-457` (always for a send with images: it is never a text-only correction, `:419`); its turn starts with `message.start` after this one (`prompt_turn.py:438-448`) |
| answer `steered` | — | E −= prompt | quiet re-reads settle it | into the running turn (`agent/interrupt_control.py:265-275`); a steer left over at turn end is queued and gets its own `message.start` (`prompt_turn.py:441-447`, `agent/turn_finalizer.py:744-746`) |
| answer `redirected` | — | E −= prompt | quiet re-reads settle it | a correction inside the running turn, no new turn (`agent/interrupt_control.py:277-281`, `agent/turn_iteration_prep.py:370-375`); the default `busy_input_mode` is `interrupt`, so every text send during a reply gets this (`server.py:378-380`, `session_auto_continue.py:420-428`) |
| submit failed, prompt withdrawn | — | E −= prompt | bubble stays (failed) or goes (withdrawn) | — |
| Stop: `session.interrupt` answered | — (the turn's `message.complete` follows) | E −= every queued prompt, and a `queued` answer arriving later for a prompt unanswered when Stop was sent expects no start | bubble stays; its row, stored at accept, shows after the re-read | Hermes clears its queue and bumps the queue generation with no event (`session_lifecycle.py:708-712`, `_persist_queued_user_row`, `session_auto_continue.py:441`); it handles `prompt.submit` and `session.interrupt` inline in arrival order (`rpc_dispatch.py:62`), so a submit sent before the Stop was queued before the clear |
| `error`, no turn open | — | E := unanswered only; B := false | bubble stays | the turn will not start: Stop during the agent build (`methods_prompt.py:625-635`), an ownership refusal (`prompt_turn.py:123-134`), a queued prompt that failed to dispatch (`session_auto_continue.py:505-513`); a failed build is followed by `message.complete(error)` (`methods_prompt.py:617-623`) |
| `error`, turn open | closes it only if it has shown nothing (as for `running: false`) | then as with no turn open | — | a follow-up turn refused after its `message.start` sends only this (`_dispatch_followup_turn`, `prompt_turn.py:421-436`, then `:123-134`); a failed pending model switch or configured-model adopt sends it at turn start and the turn goes on (`session_compression.py:197-211`, `model_switch.py:495`, `prompt_turn.py:685`): its next streamed event opens T again, at the latest the `thinking.delta` of its first API call (after any turn-start compression, which sends none: `agent/turn_context.py:1182-1198`, `agent/turn_preflight.py`); a refused follow-up never reaches the agent and sends none |
| `message.start` (or a first streamed event) | opens | E := ∅; B := false | — | every turn, also follow-ups (`prompt_turn.py:426,1154`) |
| `message.complete` `complete` | closes | — | its re-read settles the turn's live items | `prompt_turn.py:1183` |
| `message.complete` `interrupted` | closes | — | a reply with no text stays as a local row showing "Interrupted" and any reasoning, after the turn's last committed row (`persisted_turn.row_ids`; without a receipt, its prompt row) | Hermes stores no row for an empty partial (`agent/turn_api_call.py:204-210`); receipt `prompt_turn.py:897-903,940-941` |
| `message.complete` `error` | closes | — | the failing round's partial stays unless the turn's receipt shows it stored (§5 "Rounds"); `lastError` | terminal persist `agent/turn_recovery.py:820-826,1241`; receipt `prompt_turn.py:874-941` |
| `session.info` `running: false` | closes it only if it has shown nothing (no text, tool row or reasoning) | with no turn open: E keeps only unanswered and queued; B := false | — | every turn body closes with it (`prompt_turn.py:1196-1225`); it also comes between a turn and the queued one after it |
| reactivation `running: true` | — | B := true if no turn is open | — | `session.activate` / `session.resume` `running` (`server.py:3157,3172`) |
| reactivation `running: false`, reclaimed runtime | closes | E := unanswered only; B := false | — | `server.py:3157,3172`; `session.reclaimed` (`session_lifecycle.py:475`) |
| reconnect (cold restore) | rebuilt from the snapshot (`inflight`, `running`) | E := ∅ (a send in flight waits in `settleIdentity`) | — | §7 |

Invariants:
- **Nothing hides content.** Ending a turn closes its items as finished, and the re-read drops only
  what it holds. A turn that has shown text, a tool row or reasoning is never closed by
  `running: false` or `error`.
- **Every fact has an ending event.** T ends with `message.complete`, or with `running: false` or
  `error` when it showed nothing. E entries end with `message.start`, their answer, an `error` with
  no turn open, `running: false` (all but queued and unanswered ones), or Stop (queued ones). B
  ends with `message.start`, `message.complete`, `running: false` or an `error`.
- **Any streamed event means running again** (it opens T). A stale `running: false` or a
  non-terminal `error` that closed an empty turn, or cleared B in a chat shown again, is undone by
  that turn's next streamed event; the agent's first API call sends `thinking.delta`, so that is
  at the first API call (after any turn-start compression), whether or not show-reasoning is on.
  This relies on Hermes sending no `thinking.delta` after a turn's `message.complete` (verified:
  only the turn's own API-call loop sends it); a later frame would show a turn running that no
  event ends.
- **A failed re-read is never the only way out.** Stopping needs no re-read. A failed re-read is
  tried again after 2 s, 8 s and 30 s (`ChatSession.rereadRetryDelays`), so bubbles, and a queued
  prompt Hermes dropped without a word (below), settle once reads work again. After the last retry
  nothing is tried until the next turn, revisit or reconnect asks for a re-read; that one starts a
  new streak with all three retries, however long the outage was. A rebuild (`reset(to:)`), a new
  history load and a forgotten chat cancel a pending retry.

Paths where Hermes sends nothing, and what ends them:
- **A queued prompt dropped silently**: its drained turn finds the queue generation changed
  (`prompt_turn.py:135-146`). Stop does this, and is handled above. Otherwise (a compaction's
  re-anchor in that window) its expectation ends when the quiet re-reads settle its bubble
  (retried as above), or with the next `message.start`, `error` with no turn open, revisit or
  reclaim.
- **A drain whose claim a generation bump cancelled** goes back to the queue silently and clears
  `running` (`session_auto_continue.py:473-480`). The prompt still runs after a later turn, with its
  own `message.start`. If Stop caused the bump, the client has already ended its expectation; its
  bubble stays, and that later start shows the turn.
- **Stop drops a redirect that was accepted but not yet applied** (`agent/interrupt_control.py:194`,
  `_pending_redirect = None`): the correction is never stored. The bubble stays until the quiet
  re-reads settle it (round 1's nit N4, deferred). The running state is not affected: a
  `redirected` answer expects no start.
- `[unverified]` **A turn that cannot start because the session is closing**
  (`prompt_turn.py:1238-1245`). It ends with the reclaim (`session.reclaimed`).

Unknown event types must be ignored. Hermes has about 80 notification types; see
`x-notifications` in the OpenRPC file.

## 6. Server→client requests (approval, clarify, …)

Source: `tui_gateway/server_requests.py:1-35,70-72` and `contracts/server_requests.py`.

```json
{"jsonrpc":"2.0","id":"srq-1a2b3c4d5e6f","method":"approval","params":{"session_id":"…","request_id":"…","command":"rm -rf build","description":"…","choices":["once","session","always","deny"]}}
```

- **Answering.** Send a normal response with the same id, e.g.
  `{"jsonrpc":"2.0","id":"srq-…","result":{"choice":"once"}}`. The server does not reply to it.
  An answer for an id that is no longer open is dropped.
- **MVP methods:**

  | Method | Params | Answer |
  |---|---|---|
  | `approval` | `{request_id, command, description, choices, allow_permanent?, allow_session?, tool_name?}` | `{choice: once\|session\|always\|deny, all?}` |
  | `clarify` | `{questions:[{qid, question, choices?, multi_select}], answers?}` | `{answers:{qid: string\|null}}`. Omitting `answers` cancels. Per-question locking uses the `clarify.lock` RPC. A multi-select answer is a JSON array string (§10.8). |
  | `sudo` | `{command?}` | `{value}`. An empty string means skipped. |
  | `secret` | `{env_var, prompt, metadata?}` | `{value}`. An empty string means skipped. |

  Clarify and the other prompts time out after 300 s by default (`server.py:1390-1419`).
- **Window-owned bridges** (`terminal.read`, `preview.read`, `preview.act`, `window.read`, `tour`):
  the app answers **error `4404`** ("not shown here").
  - The server treats any other error as the *final* answer (`server_requests.py:253-275`).
  - A 4404 is only a decline. The request settles when every attached answering client has
    declined, so a Desktop window showing the same session can still answer
    (`server_requests.py:22-28,221-250`).
- **Other unsupported methods** (`vault.*`, `display.install.sudo`, unknown ones): the app
  answers `-32601` so the agent fails fast instead of waiting for the deadline.
  - Not 4404: once every client has declined, the request resolves with a JSON "not shown" string
    *as the value*, which these `{value}` prompts would take as the secret.
  - Known limitation: if a Desktop window is attached as well, our `-32601` can win over its
    answer to a vault prompt.
  - `[unverified]` The programmatic-integration doc also lists a `connection` request answered
    with `{settled_by, targets}`. The contracts only show a `connection.request` *event*.
- **Withdrawal.** The server sends one `request.cancel {id, method, reason}` event
  (`reason` is one of timeout, interrupted, shutdown, resolved or session_closed).

## 7. Reconnect and resume

- **Replay ring.** Each session keeps the last 512 events (4 MiB) in memory
  (`event_replay.py:27-35`). `replay_epoch` is a random id per backend process
  (`event_replay.py:22-25`).
- **What happens on disconnect.**
  - Sessions created without `close_on_disconnect` are pointed at a drop-everything "detached"
    transport, and an orphan reap is scheduled (`session_lifecycle.py:991-1043`,
    `server.py:211-227`).
  - Events are routed by `session["transport"]` (`server.py:681-689`), so **nothing reaches the
    new socket until the session is re-bound**.
  - The reap grace is **20 s** by default (`ws_orphan_reap_grace_s`, `server.py:139`).
  - A detached *running* turn is interrupted only after **600 s** without activity
    (`server.py:150`).
- **Only `session.activate`, `session.resume` and `prompt.submit` re-bind** the transport and
  cancel the reap (`_rebind_live_transport`, `session_lifecycle.py:826-845`). They return 4007 if
  the runtime session is gone.
- **`session.events.since` re-binds nothing.** It only reads the ring. For an unknown or reaped
  sid it returns an **empty success** (`{events:[], latest_seq:0, truncated:false}`), so it
  cannot detect a lost session (`methods_session.py:2603-2617`, `event_replay.py:131-154`).
- **Unanswered server requests** are not in the replay ring. They come back as `open_requests`
  from `session.resume`, `session.activate` and `session.events.since`, and the client delivers
  them again as if they were new (`server_requests.py:15-18`).

Client algorithm (`GatewayConnection` + `GatewayClient.reattach`). It is related to the shared TS
client's replay (`apps/shared/src/json-rpc-gateway.ts:504-670`), but adds the explicit re-bind:

1. Reconnect with exponential backoff and jitter, using a fresh transport and a fresh ticket.
   - A connect/disconnect generation token discards stale attempts and closes their sockets.
   - A socket whose restore failed is closed before the next attempt.
2. Compare the new `gateway.ready.replay_epoch` with the epoch committed at the last
   **successful** restore. A failed attempt never commits its epoch.
3. If the epoch is unchanged and a `seq` watermark exists:
   1. Start holding live events for the session.
   2. Call `session.activate {session_id, omit_messages:true}` to re-bind; 4001/4007 means gone.
   3. Call `session.events.since {session_id, last_seen}`.
   4. Trust the result only if `truncated` is false, `epoch` matches and `latest_seq >= last_seen`.
      Then deliver the replayed events, then the held-back ones (deduplicated by `seq`), and
      re-deliver `open_requests`.
4. Otherwise, call `session.resume {session_id:<stored key>, profile?, omit_messages:true,
   defer_history:true}` (the profile the session was opened on, §8.1). Rebuild the transcript from
   `inflight` plus the newest REST page (§4.1), and re-deliver `open_requests`.
   - The held-back events are dropped; the snapshot supersedes them.
   - Older pages loaded before are dropped too, and a page still in flight for the old
     transcript is discarded when it lands.
5. A fresh `connect()` (e.g. the iOS app returning to the foreground) restores the active session
   the same way.
   - The session is cleared, and the connection stays up, only when restore fails with
     4001/4007 (session gone) or 4064 (its profile is gone, §8.1), or when a Bot Chat is no
     longer registered (§8.2). Resume of an unknown stored id is 4007 (`methods_session.py:833`).
   - The reconnect loop does the same: it does not retry a restore that can never succeed.
   - Any other error fails the connect and keeps the session for the next attempt: 4009
     "disconnect interrupt settling" (`session_lifecycle.py:821-822,953-955`), 5000, -32000, …
6. A chat whose runtime was reclaimed (`session.reclaimed`, §11) skips step 3: there is nothing to
   re-bind. While the restore runs, the chat's actions wait for it
   (`ChatSession.settleIdentity`), and a resume of the reclaimed runtime still in flight on the
   old socket is cancelled, so the chat is resumed once, not twice.

`[unverified]` Events emitted between the re-bind and the resume snapshot on the step-4 fallback
could be counted twice or missed. The window is small and not covered by the server's contract.

## 8. Bots: profiles and the Bot Chat

The sidebar lists every Hermes profile as a **bot** with one permanent chat. This is the
contract of Hermes Desktop's Bot Mode (`apps/desktop/src/AGENTS.md` "Bot Mode",
`apps/desktop/src/plugins/hermes-bots/canonical-chat.ts`). The app and Desktop therefore share
the same conversation.

### 8.1 Profiles and profile-scoped calls

- **`profile` param.** Most methods accept `profile` (`ProfileParams` / `SessionParams.profile`,
  `contracts/common.py:224-234`).
  - The call then runs against that profile's `state.db` and `HERMES_HOME`
    (`server.py:558-596`).
  - If no profile of that name exists, the call fails with **4064** "Profile '…' does not
    exist." (`server.py:561-577`, `rpc_dispatch.py:35-36`).
  - Omitting `profile` means the gateway's launch profile.
- **Profiles answer through one gateway.** A runtime session created or resumed with `profile`
  remembers it, so later calls carrying only `session_id` stay scoped (`server.py:596-623`).
  - A **cold** `session.resume` must send `profile` again. Without it the stored id is looked up
    in the launch profile's database and fails with 4007.
  - `[client choice]` `ChatSession.profile` holds the profile, and `GatewayConnection` passes it
    on reconnect.
- **`profiles.list`** returns one row per profile (`methods_profiles.py:281-302`):
  ```json
  {"name":"coder","path":"…","is_default":false,"model":"…","provider":"…","description":"","display_name":"",
   "skill_count":3,"previous_names":[],"role":null,
   "last_session":{…}|null,"worker_session":{…}|null,"canonical_session":{…}|null,
   "ui_meta_revisions":{},"ui_meta":{…}?,"has_avatar":false}
  ```
  - **`canonical_session`** is the profile's Bot Chat, resolved by title on every listing:
    `{id, resolved_id, root_title, title, preview, started_at, last_active, message_count,
    live_message_count?}`.
    - `id` is the registry row and `resolved_id` the compression-lineage tip.
    - `preview` is the tip's newest user or assistant text: at most 80 characters, followed by
      `...` when cut (`methods_profiles.py:108-122,161-195`).
    - It is `null` when the profile has no Bot Chat yet.
  - **`last_session`** is the newest human-facing session of any kind
    (`methods_profiles.py:198-228`). It is **not** the bot's chat.
  - **`worker_session`** is the newest kanban or tool worker row. Workers update `last_active`
    at least every 60 s while running (`methods_profiles.py:199-206`).
  - Times are Unix seconds.
- **The row.** `[client choice]` Mirrors Desktop:
  - **Order:** `default` first, then the server's order.
  - **Name:** `ui_meta["hermes-bots"].title`, then `display_name`, then "Hermes" for `default`,
    then the profile name in title case (`plugins/hermes-bots/labels.ts:45-75`).
  - **Preview:** the `canonical_session` preview.
  - **Activity:**
    - *working*: a turn is running in this app, or `worker_session.last_active` is less than
      150 s old;
    - *active now*: `canonical_session.last_active` is less than 90 s old
      (`row-helpers.ts:55-86`);
    - *waiting for you*: a server request for a session of that profile that this app opened.
  - **Refresh:** the roster is re-read after every connect, every finished turn of a profile's
    session and every `sessions.changed` (both throttled, §11), and every 15 s while the sidebar
    is shown. Desktop polls every 5 s
    (`methods_profiles.py:249-250`).
  - **Avatar:** `[client choice]` the profile's image when `has_avatar` is true, else
    initials on `ui_meta["hermes-bots"].color` (a hex colour), else a colour from the name.
    Desktop's vector shapes and faces (`plugins/hermes-bots/avatar.tsx`) are not drawn.
- **Avatar images** live in the profile's asset store, shared with Desktop's Bots plugin
  (`plugins/hermes-bots/profile-ops.ts`):
  - `profiles.get_asset {name, asset:"avatar"}` → `{found:false}` or
    `{found:true, mime, size, data:"data:<mime>;base64,…"}` (`methods_profiles.py:450-463`).
  - `profiles.set_asset {name, asset:"avatar", data}` stores a PNG, JPEG or WebP of at most
    2 MB (data URL or bare base64, type sniffed) as `<profile>/assets/avatar.<ext>`;
    `{name, asset:"avatar", clear:true}` removes it. Answers `{ok, asset, size, removed?}`
    (`methods_profiles.py:411-447`).
  - `[client choice]` The app reads each avatar once per connection, for rows with
    `has_avatar`, as Desktop does (`pullServerAvatars`, `profile-ops.ts:165-215`). It uploads
    a 256 px centre-cropped PNG, as Desktop's picker makes (`avatar-image.ts:18`).
  - Desktop backfills a 160 px PNG of its vector face for profiles that have no image
    (`pushLocalAvatars`, `profile-ops.ts:59-100`), so an avatar removed here can come back
    while Desktop is running.
  - **Profile scope:** Sessions lists only the selected profile. Opening a bot or listing
    a non-launch profile may enable multi-profile hosting (`server.py:579-586`,
    `tui_gateway/launch_profile_policy.py`).

### 8.2 Opening the Bot Chat

The Bot Chat's only identity is **(profile, session titled exactly `Bot Chat`)**. The state
DB's title uniqueness makes that a registry of at most one row per profile
(`apps/desktop/src/AGENTS.md`, Bot Mode). **No session id is ever stored as the bot's chat or
used as a fallback.** Every open of a bot (`GatewayConnection.openBotChat(profile:)`) looks the
chat up again. The one exception: if that bot's Bot Chat is already on screen, the open returns
it as it is. A Bot Chat shown earlier in this connection (§4.2) comes back on screen at once;
the lookup then runs in the background, and a changed tip is resumed into it.

1. **Look up the chat by title:**
   `session.list {profile, title:"Bot Chat", include_hidden:true, limit:200}`.
   - This is an indexed, window-free exact-title lookup.
   - Hidden rows are returned (Bot Chats are born hidden).
   - Archived and denied-source rows are not.
   - The single row carries `resolved_id`, the lineage tip (`methods_session.py:526-559`).
2. **Row found:** `session.resume {session_id:<resolved_id or id>, profile, omit_messages:true,
   defer_history:true}`, then the newest REST page (§4.1).
3. **Fail closed.** Neither of these may create a chat (`canonical-chat.ts:282-292,328-338`):
   - The lookup errors → `BotChatError.registryUnavailable`.
   - The lookup is empty but the roster's `canonical_session` says the chat exists →
     `BotChatError.registryUnconfirmed`. A backend in the middle of a restart can answer an
     empty list.
4. **Confirmed absent:** create the chat.
   - `session.create {profile, title:"Bot Chat", hidden:true, follow_profile_config:true}`, as
     Desktop does (`canonical-chat.ts:468-488`).
   - Then `session.title {session_id:<runtime>, title:"Bot Chat"}`. This persists the row under
     its name immediately (`methods_session.py:1229-1241`, `canonical-chat.ts:493-511`).
5. **Adopt before creating.** If that title is already taken, the write fails with 4022
   "Title 'Bot Chat' is already in use by session …" (`hermes_state_titles.py:154`,
   `methods_session.py:1242-1243`).
   - That means another client created the chat after our lookup. Look it up again and open the
     winner (`canonical-chat.ts:513-535`).
   - The stray lazy session has no row and is left for the gateway to prune.
6. **Only a saved, named chat becomes the Bot Chat.** Any other `session.title` failure fails
   closed with `BotChatError.notRegistered`, and so does a `pending: true` answer, which means the
   row was not written. The failures are 4021, other 4022s and 5007
   (`methods_session.py:1226-1245`).
   - The lazy session is never used. It is hidden and untitled, so the next open would create
     another chat, and anything typed into it could not be reached from any list.
   - `[client choice]` Desktop instead sends an intro prompt to make such a session permanent
     (`canonical-chat.ts:536-560`). The app sends nothing on the user's behalf and asks the
     user to try again.

**Reconnect.** A cold restore of a Bot Chat (§7 step 4) also looks the chat up by title first,
then resumes the tip the lookup returns. The id the chat had before the outage is not reused:
- Desktop may have retired and replaced the chat in the meantime.
- Resuming a server-minted key can re-create a missing row (`methods_session.py:782-808`).

If the lookup finds no Bot Chat, the session is dropped from screen and nothing is created.
The same-backend fast path (§7 step 3) re-attaches the still-live runtime session and needs no
lookup.

Concurrent opens of one bot share a single resolution (`canonical-chat.ts:38-40`).
`[client choice]` When opens overlap, the one started last takes the screen. An earlier one
still finishes and is returned to its caller, but is not shown. Its runtime session stays
attached to the socket, so its `open_requests` are still re-delivered and show on the bot's
row.

### 8.3 Side chats and the Sessions page

- **Side chat.** A side chat ("New chat with this agent" in Desktop) is a plain
  `session.create {profile}`: no title, not hidden. It is never the bot row's target.
- **Sessions page** has a roster profile picker, defaulting to the default profile (or the
  first roster entry). Bots shows permanent Bot Chats only. Navigation changes do not open chats.
  - `[client choice]` The page's "New chat" row creates a side chat with the selected profile.
    It is enabled only while connected and the selection is in the roster
    (`GatewayConnection.canStartListChat`).
  - Server: `session.list` has `limit` but no offset and no clamp
    (`contracts/sessions.py:221-224`). It reads the `max(2*limit, 200)` most recent
    non-hidden, non-archived rows, drops the internal sources `kanban`/`tool`/`oneshot`, then
    cuts to `limit` (`methods_session.py:563-577`, `_listing_rows` :149-152,
    `hermes_state_sessions.py:199`). A short response is therefore either the end of the list
    or a window crowded by internal rows.
  - `[client choice]` Only the selected profile is listed: `session.list {profile, limit:200}`,
    re-read with a doubled limit while the response is full or still growing. Two reads in a
    row with the same short count settle the list; that limit is remembered per profile, so a
    later refresh is one read (re-laddering only if it comes back full). A run of more than
    `2*limit` consecutive internal rows below the visible ones would still end the list early.
    Hidden, archived and internal rows stay server-filtered; this listing never asks for them.
  - **Order:** the server's most recent activity order (`methods_session.py:149-152`).
  - **What is left out:** Bot Chat rows. A Bot Chat row has `root_title` (when the gateway sends
    it) or `title` equal to `Bot Chat`, or its id is the roster's `canonical_session.id` /
    `resolved_id`.
    - Bot Chats are normally hidden anyway: Desktop creates them with `hidden:true` and its sweep
      re-hides them (`plugins/hermes-bots/hide-bot-chats.test.ts:1-16`).
    - A *visible* row titled `Bot Chat` is left out too. The title lookup doesn't filter on
      `hidden` (`methods_session.py:526-550`), so that row is what the bot row opens.
    - Hermes uses `hidden` only to decide whether such a row may be renamed
      (`hermes_state_titles.py:100-110`).
  - `[client choice]` Only rows of `desktop` and `tui` (and rows without a source) are listed,
    whatever Settings hides: cron runs are the Cron Jobs tab's, and messaging platforms,
    subagents and the rest stay out, as in Desktop's recents (`SIDEBAR_EXCLUDED_SOURCES`,
    `apps/desktop/src/app/session/hooks/use-session-list-actions.ts:66-73`).
  - `[client choice]` The app does not run that sweep. It never writes `hidden`.
- **Opening a Sessions row:** `session.resume {session_id, profile, omit_messages:true,
  defer_history:true}`, then the newest REST page (§4.1).

## 9. HTTP API server (secondary option, not used by the MVP)

This is the OpenAI-compatible server in `gateway/platforms/api_server.py`, described in
`website/docs/developer-guide/programmatic-integration.md:126-198`.

**Endpoints:**
- `POST /v1/runs` returns 202 with `{run_id}`.
- `GET /v1/runs/{id}/events` is an SSE stream of lifecycle events.
- `POST /v1/runs/{id}/approval`, `/steer` and `/stop`.
- Also `/v1/chat/completions` (SSE), `/v1/responses` and `/v1/capabilities`.

**Terminal events:** `run.completed`, `run.cancelled`, `run.failed` and `run.interrupted`.

**Why the apps don't use it:**
- It has no session browsing.
- It has no server→client clarify.
- It is a different auth surface.

`[unverified]` The SSE payload schemas were not reviewed; the doc points to
`user-guide/features/api-server`.

## 10. Composer and session actions

The composer mirrors Hermes Desktop's (`apps/desktop/src/app/chat/composer/`), the reference
client: model and reasoning effort (§10.1-10.2), images (§10.3), voice (§10.4), files (§10.5),
slash commands (§10.6), steering a running turn (§10.7), clarify multi-select (§10.8), and
renaming, archiving and deleting side chats (§10.9). Everything goes over the same `/api/ws`
JSON-RPC.

Every call takes the chat's **runtime** `session_id`, except `session.delete`, and
`session.archive` on a row that is not open (stored id plus `profile`). The model, effort and
image calls also carry the chat's `profile` when it has one (§8.1). Without `profile`,
`@_profile_scoped` handlers take the scope from the live session named by `session_id`
(`server.py:598-623`). A chat whose runtime was reclaimed is resumed before any of these calls
(§11).

Swift: `HermesProtocol/ComposerMethods.swift` holds the wire types. `HermesKit/Composer/`
(`ChatComposer`: one per warm chat, `GatewayConnection.composer(for:)`), `ChatSession`,
`SlashCommands.swift` and `GatewayConnection+Manage.swift` hold the logic.

### 10.1 Model picker

- **Listing.** `model.options {session_id, profile?, explicit_only:true}`
  (`methods_complete.py:357-369`) returns `{providers, model, provider}` (`inventory.py:165`).
  - Each provider row is
    `{slug, name, models:[id], total_models, is_current?, authenticated?, capabilities?, …}`.
  - `capabilities` maps each model id to `{fast, reasoning, ultrafast?, can_disable_reasoning?}`
    (`inventory.py:317-362`).
  - Desktop's chat picker sends `explicit_only: true` (`apps/desktop/src/lib/model-options.ts:146-169`),
    so ambient credentials are hidden.
  - Desktop skips rows with no models (`model-options.ts:131-133`).
- **Current model.** The session's `session.info` `model`/`provider` win. The `model.options`
  pair is the fallback (`model-status-label.ts:1-33`).
  - A lazy session's info has `model` but neither `provider` nor `reasoning_effort`
    (`server.py:2831-2839`).
- **Switching.** The app sends
  `config.set {session_id, key:"model", value:"<model> --provider <slug> --session"}`.
  - The persistence rules are in `resolve_persist_behavior` (`hermes_cli/model_switch.py:510-540`).
    Without a flag, a pick is written to the profile's `config.yaml` when no default is configured
    yet, or when `model.persist_switch_by_default` is true. `--session` (and `--once`) always opt
    out.
  - Desktop's *primary* chat omits the flag and lets the gateway decide. Its secondary tiles send
    `--session`, so that a pick there "must not rewrite the profile default"
    (`apps/desktop/src/app/session/hooks/use-model-controls.ts:335-344`).
  - `[client choice]` The app always sends `--session`. Changing the model here never changes
    the bot's profile config, whatever that profile's settings.
  - **Answer:** `{key, value, warning, confirm_required, confirm_message, scope}`
    (`methods_config_set.py:161-163`).
  - **`confirm_required: true`** (e.g. an expensive model) means nothing was applied. The app asks
    the user. On yes, it resends with `confirm_expensive_model: true`. A second
    `confirm_required` counts as a failure, as in Desktop
    (`apps/desktop/src/lib/guarded-model-switch.ts:36-53`).
  - **During a running turn**, the pick is stashed and applied at the next turn start, and the
    answer carries `deferred: true` (`methods_config_set.py:69-90,122-123`).
  - `session.info` follows once the agent exists (`methods_config_set.py:34-37`). The app shows
    the pick right away and lets `session.info` correct it.
  - Picks overlap when the user picks again before the first answer. The gateway applies the
    switches in arrival order (`config.set` is not in the pool-dispatched set, `server.py:179-191`),
    so the last pick sent wins there. The app likewise ignores an
    answer to an older pick.
- **Errors.**
  - A sessionless `config.set model` is 4001 (`methods_config_set.py:153-160`).
  - A `session_id` the backend no longer holds is 4001 for `model`/`fast`/`yolo`/`reasoning`, and
    never falls back to a global write (`methods_config_set.py:482-494`).
- **Not used:** the `/model` slash command (`slash.exec` / `command.dispatch`). It goes through
  the same switch parser, but Desktop's picker uses `config.set`, and a structured answer is
  easier to handle.

### 10.2 Reasoning effort

- **Read.** `config.get {key:"reasoning", session_id}` returns `{value, display}`
  (`methods_config.py:206-224`).
  - `value` is the session's pin (`create_reasoning_override` or the agent's
    `reasoning_config`), else the profile's `agent.reasoning_effort`, else `medium`.
  - `none` means thinking is off.
  - The app reads `session.info.reasoning_effort` first and calls `config.get` only when that is
    missing.
- **Write.** `config.set {key:"reasoning", session_id, value:<level>}`, with **no** `scope`, pins
  the effort on that session only (`methods_config_set.py:308-336`, branch at :321-331).
  - `scope:"global"` writes the profile config. The app never sends it.
  - This is the same call Desktop makes (`apps/desktop/src/lib/reasoning-step.ts:58-73`,
    `store/model-presets.ts:170-176`).
  - The display words (`show`/`on`, `hide`/`off`, `full`/`all`, `clamp`/…) rewrite the profile's
    display config whatever the session (`methods_config_set.py:312-317`).
    `ChatSession.setReasoningEffort` sends only `none` or one of the levels, exactly as written.
    Anything else throws before a frame goes out.
- **Levels:** `minimal, low, medium, high, xhigh, max, ultra`, plus `none`
  (`apps/shared/src/reasoning-effort.ts`).
  - The picker is hidden when the model's `capabilities.reasoning` is false
    (`composer/reasoning-pill.tsx:43-45`).
  - `none` ("Off") is offered unless `can_disable_reasoning` is false
    (`app/shell/model-edit-submenu.tsx:134`).
  - A model the catalog doesn't list keeps the dial: the catalog itself defaults `reasoning` to
    true (`inventory.py:317-321`).

### 10.3 Images

- **Upload.** `image.attach_bytes {session_id, content_base64, filename}` writes the image into the
  session's images directory and queues it (`methods_prompt.py:886-914`).
  - Answer: `{attached, path, count, remainder, text, bytes, name, width?, height?, token_estimate?}`
    (`methods_prompt.py:1222-1226`, `server.py:861-870`).
  - The **filename's extension** decides the stored type; magic bytes decide only when there is
    none (`prompt_attachments.py:64-71`).
  - Accepted: png, jpg, jpeg, gif, webp, bmp, tiff, tif, svg, ico
    (`hermes_cli/cli_terminal_input.py:33-36`). Anything else, HEIC included, is 4016.
  - Errors: 4017 for bad base64, 4018 over 25 MB (`prompt_attachments.py:16,50-60`).
- **Not usable from another device:**
  - `image.attach {path}` reads a path on the gateway host.
  - `clipboard.paste` reads the gateway host's clipboard (`methods_prompt.py:834-855`).
- **Sending.** The next turn start takes every queued image and empties the queue
  (`prompt_turn.py:147-149`).
  - `prompt.submit` has no empty-text check (`methods_prompt.py:681-831`), and Desktop sends an
    image-only prompt (`composer/hooks/use-composer-submit.ts:252`).
- **Removing.** `image.detach {session_id, path}` returns `{detached, count}`
  (`methods_prompt.py:998-1010`).
- **Frame size.** The dashboard accepts WebSocket frames up to 384 MiB (`hermes_cli/web_server.py:434,1247`).
- `[client choice]` **Upload when attached, like Claude Code** (decided by the user, 2026-10-29).
  Desktop's remote mode uploads at send instead (`use-prompt-actions/index.ts:439-443`).
  - An image is uploaded (queued) as soon as its card is added; its card shows a spinning ring
    meanwhile, and Send waits for every upload. `image.attach_bytes` answers only once the image
    is queued, so the ring shows that it is under way, not how far.
  - The queue is the session's, and the next turn start takes all of it, so the composer always
    sends every card it has. Removing a card detaches its image.
  - A card whose early upload failed says so; Send uploads it again.
  - On Send the cards leave the composer at once (the prompt's bubble shows them). The send uploads
    only the images not already queued in the current runtime session (a revived runtime has a new
    queue), then sends `prompt.submit`.
  - If the send fails, every image it queued, early or not, is detached (or stranded, below), and
    the cards and the draft come back for a retry, which uploads them again. If an upload fails,
    the composer also shows the error.
  - With no connection, nothing is sent: the draft stays and the composer says so.
  - **Stranded images.** When the socket drops mid-send, the `image.detach` for images already
    queued cannot be delivered. The runtime session can outlive the outage with them still
    queued, through a fast reattach (§7) or a `session.resume` of the still-live session.
    - `GatewayConnection` keeps those paths, keyed by runtime session id. They are kept on the
      connection, not the `ChatSession`, so they survive reopening the chat, and the list is
      capped at 50 (the oldest are dropped).
    - The paths are detached right after every connect or reattach, and again before any send on
      their session.
    - The work is per session. Each session's images are detached in parallel, chained only after
      that session's previous flush. A send waits for its own session's detaches, never another
      session's.
    - A send whose session still has a stranded path that got no answer does not go out. The
      composer shows the error and keeps the draft and the cards.
    - While the send waits, its button is a spinner the user can tap to cancel. The draft and the
      cards come back, and the detach carries on in the background. Once the prompt is on
      screen, it is submitted regardless of cancellation.
    - Any answer settles a path, including `detached:false` and 4001 (session gone).
    - `image.detach` resolves the session with `_sess_building`, which also starts a lazy
      session's agent build (`server.py:1245-1251`). That is harmless.
    - **Windows that remain:**
      - A turn **another client** starts on the session before the cleanup runs takes the
        stranded images.
      - `[client choice]` **A detach that times out on a socket that stays up** puts the image
        back on the list. It is retried on the next send on that session or the next
        connect, not in the background. Retrying at once on a live but silent socket would
        loop; the heartbeat (§3) drops a dead socket within 45 s, and the reconnect then
        retries. Until then, another client's turn can take the image.
      - `[unverified]` An upload that **times out** may still have been queued, under a path the
        client never learned. Nothing can detach that one.
  - Why not upload eagerly: a queued image rides with whatever turn starts next, including one
    started by another client on the same session. That window still exists between the upload
    and `prompt.submit`, and the client can't close it: `prompt.submit` takes no image list.
  - **Ambiguous drop during `prompt.submit`.** If the socket drops after Hermes accepted the
    submit but before the answer arrived, the app reports a failure and keeps the cards and the
    draft. A retry then runs the message, with its images, a second time. A client cannot tell
    this case from a submit that never arrived.
- **Sending while a turn runs.** The composer shows Send beside Stop whenever it holds something
  to send. What Hermes does with the message depends on its content:
  - **With images**, a busy `prompt.submit` claims the queued images at once and queues them with
    the prompt as its own turn. It never steers such a prompt into the running turn, nor
    interrupts it. The answer is `{status:"queued"}` (`session_auto_continue.py:414-448`).
  - **Text alone** follows the profile's `display.busy_input_mode`, which defaults to
    **`interrupt`** (`tui_gateway/server.py:375-377`). The running reply is redirected, or
    stopped and the text queued (`session_auto_continue.py:415-446`). `queue` and `steer` are the
    alternatives.
  - The app reads no setting for this, so its tooltip and accessibility hint state both cases.
  - Either way, the prompt's bubble follows the §4.1 lifecycle. It shows at once and is marked
    answered with the `prompt.submit` status (`streaming`, `queued`, `steered` or `redirected`)
    and `user_row_id`. It is dropped by quiet re-reads once the stored rows hold the outcome.
  - Bubbles settle by quiet re-reads (or with their own turn, §4.1), never by matching text or
    images.
- **How images show** (`ImageDirectives`, `TranscriptImage`).
  - A user message's images are cards above its caption, never text.
  - **The live bubble** carries each image's local id, so its thumbnail is already on this
    device, and the gateway path `image.attach_bytes` answered.
  - **The stored row** names the same path in an `@image:<path>` line
    (`tui_gateway/session_history.py:51-60`). Quoted values are read back as
    `format_reference_value` writes them (`agent/context_references.py:141-149`). Only whole
    lines are directives.
  - So the row shows the bubble's thumbnail, cached under its path, without a download. Cards
    have a fixed size (160×120 pt), so nothing moves when the bubble is replaced.
- **Reading a stored image** (`DashboardConnector.imageData`).
  - First `GET /api/media?path=` → `{data_url}` (`hermes_cli/web_routers/files.py:329-354`).
  - That route serves only the dashboard's own `HERMES_HOME/{images,screenshots,cache}`
    (`files.py:307-318`). An upload to a session on another profile lives under *that* profile's
    home (`tui_gateway/prompt_attachments.py:82-95,133-134`), so the route answers 403.
  - Those are read as Desktop's remote mode reads them:
    `GET /api/fs/read-data-url?path=&profile=` → `{dataUrl}` (`files.py:901-922`,
    `apps/desktop/src/lib/media.ts:132-136`).
  - The fallback is only for paths with an image extension: `@image:/some/large.log` is not
    downloaded just to show a placeholder.
  - **Failures** (404 gone, 413 too large, offline) show a placeholder card with the file name.
    They are retried after a minute at most.
  - **Thumbnails** are decoded downsampled, to at most 480 px. An image whose header reports
    more than 100 million pixels is not decoded at all; a small, highly compressible file can
    expand to gigabytes.
  - At most 3 images are downloaded and decoded at a time (`AsyncLimiter`). The cache holds at
    most 300 thumbnails, or 64 MB.
- `[client choice]` **Re-encoding** (`ImageAttachmentPolicy.encodeAttempts`).
  - PNG/JPEG/GIF/WebP up to 25 MB are sent unchanged.
  - Anything else (HEIC photos, pasted TIFF), and anything larger, is re-encoded, and the first
    output within 25 MB wins:
    1. native size, unless the source alone is over the cap;
    2. 4096 px on the long side;
    3. 2048 px.
  - Each size is tried in the preferred format (PNG when the image has alpha, else JPEG), then
    as JPEG.
  - Unknown dimensions start at native size.
  - An oversized animated GIF becomes a single JPEG frame.
- `[client choice]` **Card limit.** At most 10 cards per message. Each card holds its bytes in
  memory, and an upload briefly needs several times that (base64, JSON, frame).

### 10.4 Voice

- **The gateway's voice methods are host-side.**
  - `voice.record {action:"start"|"stop"}` is VAD push-to-talk on the **gateway host's**
    microphone (`hermes_cli.voice.start_continuous`). It needs voice mode on, and the transcript
    arrives as a `voice.transcript` event (`methods_voice.py:714-780`).
  - `voice.toggle` reports or flips voice mode (`methods_voice.py:683-712`).
  - Neither takes audio from the client, so neither helps a native client on another device.
- **Desktop's dictation goes over HTTP.** Desktop records locally and posts `{data_url, mime_type}`
  to the dashboard route `POST /api/audio/transcribe`, which answers `{ok, transcript, provider}`
  (`apps/desktop/src/api/system.ts:183-204`, `hermes_cli/web_routers/audio.py:83-143`).
  - It needs STT configured on the host.
  - Using it would mean authenticated dashboard REST calls from HermesKit (cookie session or
    bearer), plus microphone capture and permissions in the apps.
- `[client choice]` **Not wired yet.** The macOS mic button is shown disabled, with an
  explanation. iOS hides it, since it has no hover to show one.

### 10.5 Files

| Method | Params | Result | Notes |
|---|---|---|---|
| `file.attach` | `{session_id, name, data_url}` (or a gateway-visible `path`) | `{attached, name, path, ref_path, ref_text, uploaded}` | Writes the bytes into the profile's `attachments/` folder, or `<workspace>/.hermes/attachments` with `attachments.storage: workspace` (`prompt_attachments.py:88-95`). A gateway-visible `path` inside the workspace is used as is (:208-211). Any MIME type is accepted, and a name collision gets `-2`, `-3`… The result's `ref_text` is `@file:<ref_path>`, quoted when needed (`methods_prompt.py:975-995`, `prompt_attachments.py:187-248`). Error 4015 without `path` or `data_url`, 5028 on failure. |

- **Upload when attached.** `ChatComposer.attachFile(_:filename:mimeType:)` uploads a file at
  once (`ChatSession.attachFile`), like Desktop's drop-time eager upload
  (`use-prompt-actions/index.ts:176,324-327`), and keeps its `ref_text` as a `ComposerFile` card.
  PDFs are files too; Desktop never calls `pdf.attach`. While an upload runs, `canSubmit` is false.
  - An image Hermes takes unchanged (`ImageAttachmentPolicy.canSendUnchanged`) becomes an image
    card instead and follows §10.3. Other images should be converted by the app first.
  - `[client choice]` Files over 50 MB are refused before any call, and empty files too.
    `file.attach` has no cap of its own, but the bytes travel base64 (about 4/3 larger) in one
    JSON-RPC frame. The real limits:
    - the dashboard WebSocket accepts frames up to 384 MiB (`_DESKTOP_ATTACHMENT_WS_MAX_BYTES`,
      `hermes_cli/web_server.py:437-439`);
    - gateways below desktop contract v5 keep a 16 MiB frame cap (`tui_gateway/server.py:2269`);
    - Desktop reads at most 256 MiB for an attachment (`use-prompt-actions/utils.ts:443-446`).

    50 MB is Hermes' own PDF cap (`_PDF_ATTACH_MAX_BYTES`, `prompt_attachments.py:17`); it keeps
    one upload to a frame size every v5+ gateway takes, and the app's memory use bounded.
- **Sending.** The prompt is the files' references, one per line, then a blank line and the
  typed text (`use-prompt-actions/submit.ts:224-234`); a prompt of files alone is just the
  references. The bubble shows the text and the files' names (`TranscriptItem.attachments`); the
  stored row shows the same way (§5). Images ride the session's queue alongside (§10.3).
- **Failures.** A failed send keeps the file cards and gives the text back, as with images. A
  file staged on the gateway is not removed when its card is: the contract has no `file.detach`
  (nor any other call that removes a staged file), and a file no prompt references is never read.
- Chat attachments never use the dashboard's `/api/files/upload`, which belongs to the file
  browser (`hermes_cli/web_routers/files.py:643-715`). `GatewayClient` allows 300 s for an upload.
- **Where files come from in the apps** `[client choice]`:
  - the `+` menu's Choose Files… (any type), the iOS photo library, and its Paste;
  - a drop of files onto the composer (macOS and iPad), or onto the macOS text area;
  - a paste: Finder's Copy of files attaches the files (never their icon), and on iOS a
    copy in the Files app (file contents with no URL) attaches the file. Text with a
    file beside it stays text (`ClipboardPolicy`).
  - Images by extension (`ClipboardPolicy.imageFileExtensions`) go as images (§10.3); a
    file named like an image that does not decode goes as a file. Folders are refused.
  - The composer shows a pending card per upload (`ChatComposer.uploadingFileNames`).
- **In the bubble.** A user message lists its files as chips under its images. The bubble
  and the stored row both keep each file's reference value (`TranscriptItem.attachmentPaths`):
  the live bubble from `ref_text`, the row from its leading `@file:` lines. A chip downloads
  the file to preview or save it (§10.10).

### 10.6 Slash commands

| Method | Params | Result | Source |
|---|---|---|---|
| `commands.catalog` | `{session_id?, profile?}` | `{pairs:[[name, desc]], canon, commands:{"/x":{argument_mode?, desktop?, desktop_subcommands?}}, categories:[{name, pairs}], skills:{"/x":{usage, origin}}, skill_count, warning}` | tools_commands.py:185-229; methods_tools.py:503-537 |
| `complete.slash` | `{text, session_id?, profile?}` | `{items:[{text, display, meta, kind?:"command"\|"skill"}], replace_from}` | profiles_vault_complete_foreign_subagents.py:50-67; methods_complete.py:278-331 |
| `slash.exec` | `{session_id, command}` (no leading `/`) | `{output?, warning?}`, or a dispatch directive with `type` | tools_commands.py:283-305; methods_tools.py:1118-1196 |
| `command.dispatch` | `{name, arg?, session_id?}` | `{type:"exec"\|"alias"\|"plugin"\|"send"\|"skill"\|"prefill", output?, target?, message?, notice?, display?, name?, status?}` | tools_commands.py:247-280; methods_tools.py:1098-1115 |
| `session.compress` | `{session_id, focus_topic?}` | `{status: compressed\|aborted\|pending, removed, summary:{headline, token_line, note, noop, aborted}, info, messages, …}`, or `{compressed:false, lock_held, message}` | sessions.py:553-592; methods_session.py:2097-2167 |
| `prompt.background` | `{session_id, text}` | `{task_id}`; the answer arrives as `background.complete {task_id, text}` | prompt_voice.py:232-233; events.py:451; methods_prompt.py:1039-1060 |
| `session.save` | `{session_id}` | `{file}` | sessions.py:457-469; methods_session.py:2170-2199 |
| `session.status` | `{session_id}` | `{output}` | sessions.py:472-481; methods_session.py:1972 |

- **Catalog.**
  - Quick commands (config `quick_commands`) form the "User commands" category; plugin commands
    form "Plugin commands" (`methods_tools.py:460-486`).
  - Skills appear only in `pairs` and `skills`, not in `categories` (:489-500). Desktop lists them
    under "Skills" (`use-slash-completions.ts:173-215`).
  - `commands[x].desktop` is either `hidden` (left out of the list, still runnable) or a reason the
    command can't run in a GUI: `terminal`, `messaging`, `settings`, `advanced` or
    `composer-voice` (`desktop-slash-commands.ts:440-483`).
  - `commands[x].desktop_subcommands` narrows a command to the subcommands a GUI may run.
    Desktop's local table gives `/skills` only `pending|approve|reject|diff|approval`: "the CLI
    hub mutations must not be reachable from a desktop exec"
    (`desktop-slash-commands.ts:314-325`).
  - `canon` maps aliases to canonical names.
  - `SlashCatalog` encodes all of this; `SlashCatalog.refusal(for:argument:)` is the gate.
- **Completion.** `SlashCompletions.applying` inserts an accepted item as Desktop does:
  - At the command stage, `replace_from` is 1: the item replaces from after the slash, so `text`
    is the bare name (`compress`), with `/compress` in `display`. An exact match carries a
    trailing space (`compress `), except the picker commands `/model`, `/skin` and
    `/personality` (`_PICKER_COMMANDS`, `commands_completion.py:263,338-342`). The gateway's own
    extras keep their slash (`/density`, `/details`) (`commands_completion.py:60-62`;
    `methods_complete.py:17-24,301-331`). `SlashCompletions` turns every command-stage item into
    `/name`, as Desktop's `commandText` does (`use-slash-completions.ts:52-54`).
  - Rows the catalog doesn't list are kept, as on Desktop (`isDesktopSlashExtensionCommand`,
    `desktop-slash-commands.ts:672-680,752-753`): skill bundles (`kind: "skill"`, never in
    `commands.catalog`, `methods_tools.py:444-532`), the gateway's extras, plugin commands. A
    registry command the catalog marks `hidden` or GUI-unavailable stays out.
    Responses captured from the real handlers pin this:
    `Tests/HermesKitTests/RealSlashResponses.swift`.
  - Query results group as Desktop's do: "Commands", then "Skills", by the item's `kind`
    (`use-slash-completions.ts:258-287`). An alias shows only when typed in full.
  - At the argument stage, `replace_from` is the column after the last space and `text` is only
    the argument stub (`methods_complete.py:331`). Desktop inserts
    `text[..<replace_from] + item.text` (`use-slash-completions.ts:224-252`).
- **What counts as a command.** Text matching `^/[^\s/]*(?:\s|$)` (`apps/shared/src/slash.ts:11`);
  so `/usr/bin` is a prompt. The name is lower-cased, and the argument keeps its interior
  whitespace (`slash.ts:35-39`). `ChatComposer.submit` sends the draft as a prompt; the app calls
  `ChatSession.runSlash` for a draft that `SlashCommand.isCommand` accepts.
- **Running one** (`use-prompt-actions/slash.ts:262-464`, `ChatSession.runSlash`):
  1. **Bot Chat reset.** In a Bot Chat, `/new`, `/reset` and `/clear` run `/compress` instead:
     "/new inside a bot's canonical forever-chat would fork the relationship"
     (`plugins/hermes-bots/plugin.tsx:765-800`). `[client choice]` Desktop rewrites only a bare
     `/new` or `/reset`. The package also covers arguments and the `/clear` alias, so a Bot Chat
     never gets a client-side new chat.
  2. **Client-side commands.** Desktop's client actions and pickers never reach the gateway
     (`desktop-slash-commands.ts:189-325`).
     - The package runs the ones that are a plain RPC with no UI:
       - `/compress` (`/compact`) → `session.compress`, 660 s timeout like Desktop. The
         transcript keeps the earlier messages, as Desktop's merge does, and gains the summary
         line (`use-prompt-actions/slash.ts:684-865`).
       - `/bg` (`/background`) → `prompt.background`, answered by `background.complete`.
       - `/save` → `session.save`; `/status` → `session.status`.
       - `/btw` (§10.7) and `/title` (§10.9).
       - `/stop`, as Desktop does (`use-prompt-actions/slash.ts:525-570`): `session.interrupt`
         for the running turn, then `process.stop {}`, the registry's meaning of `/stop` ("Kill
         all running background processes", `hermes_cli/commands.py:124`), answering
         `{killed}` (`contracts/tools_commands.py:54-64`). Both results show in one note,
         a failure of either as its own line; a reclaimed chat has no turn to stop.
     - The rest need UI (`/new`, `/model`, `/resume`, `/branch`, `/help`, `/skin`, …) and come back
       to the app as `.clientAction`, under the command's canonical name when the loaded catalog
       maps the typed alias to one (`/fork` → `branch`).
  3. **The gate.** Before anything goes to `slash.exec`, the session's catalog is loaded if it
     isn't yet; a failed load throws, so nothing is sent ungated. The typed name is resolved
     through `canon`, then refused as `.unavailable` (`desktop-slash-commands.ts:551-587,705-720`)
     when:
     - the catalog marks it unavailable in a GUI and the first argument is not an allowed
       subcommand;
     - or its `desktop_subcommands` don't include the first argument (or there is none).
  4. **Gateway commands.** Everything else goes to `slash.exec`. If that errors, the command falls
     back to `command.dispatch`; a skill, for example, gets 4018 "use command.dispatch"
     (`methods_tools.py:1118-1196`). If the fallback only answers "not a quick/plugin/skill
     command", the `slash.exec` error is the one thrown (`slash.ts:430-463`).
  5. **Directives:**
     - `exec` / `plugin`: show `output` (a local row, §5).
     - `alias`: run `/<target> <arg>`.
     - `send` / `prefill` with a `notice`: show the notice first.
     - `prefill`: put `message` in the composer (`.prefill`).
     - `send` / `skill`: submit `message` with `prompt.submit`, showing `display`. The expanded
       skill body is never shown; the bubble settles like any prompt (§4.1), and the stored row
       shows the invocation as typed (`StoredMessageProjection.skillInvocation`).
  6. `[client choice]` **While a turn is running**, Desktop holds the kickoff in its own
     client-side queue. The app instead sends it with `prompt.submit {queued:true}`, which the
     gateway holds until the turn ends.

### 10.7 Steering a running turn

| Method | Params | Result | Source |
|---|---|---|---|
| `session.steer` | `{session_id, text}` | `{status:"queued"\|"rejected", text}` | sessions.py:617-633; methods_session.py:2444-2479 |
| `session.redirect` | `{session_id, text}` | `{status:"redirected"\|"queued"\|"rejected", text}` | sessions.py:634-635; methods_session.py:2453-2459,2480-2482 |
| `prompt.btw` | `{session_id, text}` | `{task_id}` | prompt_voice.py:221-235; methods_prompt.py:1063-1082 |
| `session.interrupt` | `{session_id}` | `{status}` | §4 |

These are explicit actions (`ChatSession.steer`, `redirect`, `askBTW`). `ChatComposer.submit`
while a turn runs stays a plain `prompt.submit`, which Hermes handles by `busy_input_mode`
(§10.3).
- **Steer** injects the text into the running turn's next tool result, without a new user turn.
  - On an idle session it answers `rejected`, and the client should send the text as a normal
    prompt (`methods_session.py:2472-2475`). `ChatSession.steer` does.
  - While compression runs, the text is `queued` for later (:2461-2469), as the next turn.
    `[client choice]` The reply is the same `queued` a delivered steer gets, so the row still
    shows as a steer; the re-read settles it either way.
  - After `queued` the transcript shows the text as a user prompt with `displayKind == "steer"`.
    Hermes stores a delivered steer as its own user row with `display_kind:"steer"`
    (`agent/prompt_builder.py:594-601`), so the bubble settles like a `steered` prompt: by quiet
    re-reads (§4.1), after which the stored steer row shows.
- **Redirect** stops the active model request and resumes the turn with the correction.
  - This is what Desktop's composer does on Enter while a turn runs: its `onSteer` is
    `redirectPrompt`, which calls `session.redirect` (`use-prompt-actions/index.ts:775-895`).
  - Desktop uses `session.steer` only for hidden notes (:901-940). The package offers both.
- **Redirect rows** follow Desktop (`index.ts:817-861`):
  - The correction is a **plain user prompt**, added before the call: the turn's end can race the
    answer. The reply so far is sealed above it, and later deltas go below.
  - `redirected`: the row stays and settles like a `redirected` prompt (§4.1).
  - `queued`: during the turn's build window or a running compression the gateway makes the text
    the *next turn* (`methods_session.py:2453-2469`). The row moves to the end, settles like a
    `queued` prompt, and the outcome is `.queuedForNextTurn`.
  - Anything else withdraws the row; `rejected` then sends the text as a normal prompt.
- **Rows added mid-turn.** A user prompt, steer, redirect, note or `/btw` row added while a reply
  streams seals the streaming bubble first (Desktop's `appendAfterActiveReply`). Later deltas open
  a new bubble below the row, and `message.complete` stops every row of the turn. A final `text`
  that the turn's segments, joined, already end with is not added again.
  - **Late text of the old call.** A prompt or redirect reaches Hermes a moment after its row
    shows, and the model call streams on until then. Hermes keeps everything it streamed as the
    interrupted reply (`agent/conversation_loop.py:322-361`), so after a user prompt (not a note
    or `/btw`) the text deltas still join the sealed bubble above the row. The corrected call's
    first text delta starts with `"\n\n"` (`_stream_needs_break`, `conversation_loop.py:361`;
    `agent/stream_delivery.py:305-310`): that delta, or any other turn event (reasoning, a tool,
    an interim, `thinking.delta` at the next API call, `message.start`, `message.complete`),
    opens the bubble below. Once the prompt is answered `steered` or `queued` (or it was a
    `session.steer`), the model sees it with a tool result at the earliest
    (`agent/interrupt_control.py:267-278`), so `"\n\n"` no longer ends it; only another event
    does. Desktop seals at once and has this split (`steer-arrival-order.test.tsx`).
- **By the way.** `prompt.btw` answers a side question from a snapshot of the conversation; the
  live turn and its history are untouched.
  - The answer arrives on the session as `btw.complete {task_id, text, question}`
    (`events.py:443-452`).
  - Desktop runs `/btw` this way rather than through `slash.exec`, whose worker would only return
    the acknowledgement (`desktop-slash-commands.ts:271-279`).
  - The transcript shows a local system row (§5) with a `SideQuestion`, filled in on
    `btw.complete`; `sideQuestion.isPending` says it still waits (the row never spins). The
    answer can arrive before the `prompt.btw` reply; the row is then created by the answer and
    not added twice.
  - `/bg` works the same way with `prompt.background` / `background.complete`, as a `SideQuestion`
    of kind `.background` (`gateway-event/status.ts:212-240`).

### 10.8 Clarify multi-select

- **When it applies.** Desktop honours `multi_select` only when the question still has choices
  after blank ones, and ones over 8000 characters (`MAX_CHOICE_CHARS`), are dropped
  (`store/clarify.ts:42-102`). The tool suffixes the first choice
  with " (Recommended)" when there are at least two (`mark_recommended`,
  `tools/clarify_tool.py:14,19-25`).
- **Answer format** (`clarify/pending.tsx:121-141`):
  - Multi-select: a **JSON array string** of the picked choices without that suffix, plus the typed
    "other" text as one more element.
  - Single-select: the bare choice, else the typed text.
  - Nothing picked: `null` (skipped).
  - The tool accepts a list, a JSON array string or a single string (`clarify_tool.py:36-47`).
- **Replay.** `answers` holds the locked answers; a multi-select one is parsed back as JSON
  (`pending.tsx:90-111`).
- **In the package:** `ClarifyQuestion.allowsMultipleChoices`, `answer(for:)` and
  `selection(fromAnswer:)`; `ClarifyRequest.lockedSelection(for:)`; and
  `ChatSession.answer(_:selections:)`.

### 10.9 Rename, archive, delete, fork, pin

| Method | Params | Result | Source |
|---|---|---|---|
| `session.title` | `{session_id:<runtime>, title}` | `{title, pending}` | §4; methods_session.py:1220-1249 |
| `session.archive` | `{session_id:<runtime or stored id>, archived, profile?}` | `{archived, session_key}` | sessions.py:337-352; methods_session.py:1252-1279 |
| `session.delete` | `{session_id:<stored id>, profile?}` | `{deleted:<stored id>}` | sessions.py:294-303; methods_session.py:1175-1198 |
| `session.branch_stored` | `{parent_session_id:<stored id>, profile?, source?, idempotency_key?, …}` (`session.create`'s params) | `{session_id, stored_session_id, message_count, messages_omitted:true, info}`, no `messages` | methods_session.py:330-493 |
| `session.branch` | `{session_id:<runtime>, count?, name?, idempotency_key?}` | `{session_id, stored_session_id, title, parent, message_count, messages, info}` | methods_session.py:2202-2204; methods_session_branch.py:84-139 |

- **Desktop uses REST for these.**
  - The endpoints are `PATCH /api/sessions/{id}` with `{title?, archived?, …}` and
    `DELETE /api/sessions/{id}?profile=` (`hermes_cli/web_routers/sessions.py:792-879`,
    `apps/desktop/src/api/sessions.ts:374-389,708-743`).
  - It renames through `session.title` when the session is live in the window, and falls back to
    REST otherwise (`session-actions-menu.tsx:112-143`).
  - `session.archive` is the gateway's documented "Desktop PATCH parity" twin.
  - `[client choice]` The package only uses JSON-RPC, so it needs no second auth surface.
- **Rename** needs a live runtime id: `session.title` only resolves `session_id` among live
  sessions. `[client choice]` The app renames only a chat it has open (on screen or warm, §4.2),
  and throws `SessionActionError.notOpen` otherwise. Opening a row just to rename it would cause
  two problems:
  - Resuming re-binds the row's event stream to this socket (§7), away from a Desktop window
    showing it.
  - `session.close` would then tear it down for everyone (`methods_session.py:2202-2206`).
  - `[client choice]` The app's Rename on a row that isn't open opens it first, as a click
    on the row would, then renames it; the user sees the chat they renamed.
- **Archive** applies to the whole lineage (`methods_session.py:1252-1279`).
  - It takes a live runtime id first; an unpersisted chat gets `pending_archived`.
  - Otherwise it takes a stored id, key or title in `profile`'s db. A reclaimed chat's stored id
    is archived.
  - `session.list` has no archived filter, so archived rows never list
    (`hermes_state_sessions.py:1315`). Unarchive is therefore only offered as an undo.
- **Delete.**
  - The gateway refuses with 4023 while the session is live anywhere in the gateway process
    (`methods_session.py:1185-1186`), and answers 4007 for an unknown id.
  - Like Desktop (`use-session-actions/index.ts:3240-3403`), the app first interrupts and
    `session.close`s the runtime it has live for that row (the chat on screen, a warm chat, or one
    it opened earlier on this connection), then deletes. The chat leaves the warm cache with its
    composer.
  - `[client choice]` 4007 counts as deleted: a chat with no first turn has no row.
  - A 4023 that remains means another client has the chat open; the error is shown.
- **Fork** copies a whole stored session (`session.branch_stored`, as Desktop's whole-session
  branch, `use-session-actions/index.ts:2726-2745`).
  - The gateway reads the parent's display history server-side, keeps its visible
    user/assistant turns (`_visible_branch_history`, `methods_session_branch.py:21-25`), and
    answers without them (`messages_omitted`).
  - Unlike a plain `session.create`, the copy's row is saved at once
    (`_seed_branch_row`, `methods_session.py:283-300,461-462`), linked by `_branched_from`, and
    titled with the parent's next lineage title: "Plan" → "Plan #2"
    (`_branch_title`, `methods_session_branch.py:13-18`; `hermes_state_titles.py:23-35`).
  - A parent with no visible turns is refused with 4008 "send a message first".
  - `[client choice]` The package lists the profile again and opens the copy with
    `session.resume`, which reuses the runtime the branch started on this socket. Bot Chats
    aren't forked (`.botChatProtected`).
- **Branch from a message** (the "…" menu under a reply) is Desktop's "Branch in new chat"
  (`branchLoadedSession`, `use-session-actions/index.ts:2928-3002`): `session.branch` on the
  chat's live runtime with `count`.
  - The gateway copies the first `count` of the parent's visible turns, its user and assistant
    rows with text (`_visible_branch_history`, `methods_session_branch.py:21-25,108-109`), saves
    the new row at once under the parent's next lineage title, and starts its runtime on this
    socket.
  - Like Desktop (`selectBranchMessages`, `use-session-actions/utils.ts:1791-1848`), the count
    comes from the whole stored transcript (`GET /api/sessions/{id}/messages`, oldest first, 500
    rows a page): the copied rows up to the message's row, found by its id, or for a message shown
    before its row was read back, by role and text counted from the end (`MessageBranch`).
  - `[client choice]` Refused while a turn runs (`MessageBranchError.busy`, Desktop's
    `branchStopCurrent`); not offered in a Bot Chat. The branch opens as Fork's copy does.
- **Pending rows across a rebuild** `[client choice]`: the owning `ChatSession` retains
  unresolved local ids across transcript generations, including dispatched RPCs. An
  acknowledged carried row with `user_row_id` stays until that exact stored row is installed,
  including when a stale initial page arrives first. Failure still uses the existing
  single-copy draft/card recovery; no RPC is replayed by this UI preservation.
- **macOS sidebar relative dates** `[client choice]`: one minute-level `TimelineView`
  supplies an explicit reference date to labels. This ages the cached latest-message
  date without changing list-read revisions, cache keys, or network refresh frequency.
- **Local outgoing visibility** `[client choice]`: a user row with local text/image ids/file
  names appears before runtime recovery, image cleanup, uploads or `prompt.submit` acknowledgement.
  It says “Sending…” until acknowledgement; `queued` says “Queued” (Hermes stores a queued
  prompt's row when it accepts it, `tui_gateway/session_auto_continue.py:435-450`). Upload
  paths update the existing row. A same-chat runtime rebuild preserves unresolved prompts.
  Acknowledgement and stored `user_row_id` use the existing prompt reconciliation, never a
  text-only echo match.
  - A failure after `prompt.submit` went out keeps the bubble with “Not confirmed” and the
    error: a dropped socket may have lost the answer of a submit Hermes ran.
  - A failure before it went out is not ambiguous. When the composer takes the message back
    (a `ComposerError`, a cancel, or a send with images or files) the bubble goes, so the
    message shows once. A text-only one (offline, failed runtime resume) keeps its bubble with
    “Not sent”; a rebuild returns its text to the draft, as before.
  - No automatic retry or durable offline queue is introduced. Existing composer draft/card
    recovery remains in effect, including preservation of newer typing.
- **Sidebar relative dates** use the newest stored message, not session creation.
  - `session.list` sends `started_at` and omits latest-message/activity metadata
    (`tui_gateway/methods_session.py:110-122`); its ordering already uses latest activity
    (`:148`). The app preserves that server order and its existing pinned grouping.
  - `[client choice]` Materialized session rows request one newest stored message with
    `GET /api/sessions/{id}/messages?order=latest&limit=1`, scoped to the row's profile
    and compression tip (`hermes_cli/web_routers/sessions.py:726-768`). This date can
    represent a user, assistant, tool or system message; it is not runtime activity.
    Rows ask again on each list refresh (`sessions.changed`, completed turns); the
    connection reuses a read while the row's profile, tip id and `message_count` are
    unchanged (every stored message bumps it, `hermes_state_messages.py:376-387`), so a
    refresh reads only rows with new messages. Failed reads are not kept.
    No transcript walk or per-row whole-history fallback is made. Missing, nonpositive,
    nonfinite, failed reads or unsupported paging show no date, never creation time.
- **Pin** is not on the JSON-RPC surface.
  - Hermes keeps it in `sessions.pinned` and Desktop writes it through the dashboard's fenced
    REST `PATCH /api/sessions/{id} {pinned}` (`apps/desktop/src/api/sessions.ts:374-428`).
  - `session.list` rows don't carry it (`_session_row_summary`, `methods_session.py:110-122`).
  - `[client choice]` The app keeps its own pins (`SessionPins`), per server, profile and stored
    id, and lists pinned rows first. They don't sync with Desktop's, and a pinned row older than
    the list's window doesn't show.
- **Bot Chats are protected.**
  - A Bot Chat is (profile, hidden session titled exactly `Bot Chat`) (§8.2,
    `hermes_state.py:1602-1608`).
  - The server only refuses *renaming* it (`hermes_state_titles.py:100-109`). Archiving would
    retire it: an archived hidden "Bot Chat" gives its title up to the next one
    (`hermes_state_titles.py:140-153`). Deleting has no guard at all.
  - Desktop only hides Rename for Bot Chat tabs (`workspace-scope.ts:75-85`).
  - `[client choice]` The package refuses rename, archive, unarchive and delete with
    `SessionActionError.botChatProtected`, and sends nothing, when:
    - the chat was opened as a Bot Chat;
    - its title or `root_title` is `Bot Chat`;
    - its stored id is the roster's `canonical_session.id` or `resolved_id` for that profile.
  - It also refuses to give any session the title `Bot Chat` (`.reservedTitle`), which would make
    that session the bot's chat. `/title` goes through the same checks.

### 10.10 Files Hermes sends

- **`MEDIA:` tags are the only channel.** No event, message field or RPC carries a file
  (`apps/shared/src/gateway-contract.openrpc.json`). The `desktop` surface's system prompt, which
  the dashboard chat uses, says: deliver files by writing `MEDIA:/absolute/path/to/file`; images,
  audio and video render inline, everything else becomes a card with download and preview
  (`agent/prompt_builder.py:749-756`).
- **Parsing** (`MediaTags`) follows Desktop's `renderMediaTags` / `mediaTagValues`
  (`apps/desktop/src/lib/chat-messages/parts.ts:121-300`):
  - a tag on its own line, or inline; the value may be quoted with `` ` ``, `"` or `'`;
  - an unquoted path may contain spaces only when it ends in one of Hermes'
    `MEDIA_DELIVERY_EXTS` (`gateway/platforms/base.py:1289`);
  - a bare value sheds trailing `.,;:!?`, and a value without a `/`, `\` or an extension is
    prose, not a file.
  - `[client choice]` Desktop rewrites a tag into an inline link. Here a tag alone on its line
    is removed, an inline one becomes the file's name, and the files show as cards right after
    the line that held the tag (`MediaTags.segments`), each once, so a file listed under a
    bullet shows under that bullet. SVG thumbnails are drawn by Quick Look, which ImageIO
    cannot do. Tags inside fenced code blocks are examples and stay text (Hermes masks
    code before its own delivery too). While a reply streams, a tag on its unfinished last
    line waits, so a half-written path never shows as a card.
- **Reading the bytes:** `GET /api/fs/download?path=&profile=&session_id=`
  (`hermes_cli/web_routers/files.py:931-960`), as Desktop downloads a delivered file
  (`apps/desktop/electron/gateway-file-download.ts:100-112`).
  - Authenticated like the other REST calls (§4.1): `Authorization: Bearer`, or the cookie
    session.
  - The answer is the file itself (`FileResponse`, `Content-Disposition: attachment`), with no
    size cap; `HTTPClient.download(for:)` streams it to a temporary file.
  - `session_id` is a **stored** session key; a relative path resolves against that session's
    folder (`_fs_download_path`, `files.py:891-901`). The apps send it only for relative paths: a
    chat Hermes has not stored yet answers 404.
  - `/api/fs/read-data-url` caps at 16 MiB, `/api/media` serves only `HERMES_HOME/{images,
    screenshots,cache}` images; neither suits arbitrary files. Image *thumbnails* still use the
    §10.3 path (`imageData`).
- **In the apps** (`TranscriptFiles.swift`): images show as thumbnails, other files as chips with
  their kind's icon. Clicking (tapping) one downloads it once per server, profile and path into
  the caches folder and opens Quick Look. The menu has Save… (macOS save panel) or Save to Files
  (iOS), Open (macOS, the default app), and Share once downloaded.

## 11. Live sidebar (server pushes)

These arrive in the same `event` notification envelope (§2). Broadcasts carry an empty
`session_id` and go to every socket (`_broadcast_global_event`, `server.py:738-754`).

| `type` | Scope | Payload | App behaviour |
|---|---|---|---|
| `sessions.changed` | broadcast | `{}` | See the note below the table. |
| `session.title` | session | `{session_id:<stored key>, title}` | Renames the row (`prompt_turn.py:795-797`). |
| `session.info` | session | `SessionLiveInfo` | Emitted whenever the live session's info moves, among others: after a `session.title` call (`methods_session.py:1248`), after a compression (`methods_session.py:2130-2132`), on a config change (`methods_config_set.py:37`), and by `broadcast_session_info` (`server.py:2449-2455`). The app also renames the row when `stored_session_id` and `title` are set. `[client choice]` Desktop does not use it for sidebar titles. |
| `session.reclaimed` | broadcast | `{session_id:<runtime>, stored_session_id, reason: idle_timeout\|lru_evict\|ws_orphan_reap}` | The backend dropped a live session (`session_lifecycle.py:465-480`). See the note below the table. |
| `notification.show` | session-routed | `{text, level: info\|warn\|error\|success, kind: sticky\|ttl\|agent, ttl_ms?, key?, id?}` | Added to `GatewayConnection.notifications`. A notice with the same `key` replaces the old one. Fields per `events.py:332-341`. Only a `kind:"ttl"` notice with a positive `ttl_ms` removes itself after that time; every other notice stays until cleared or dismissed. `ttl_ms` is "honored only when kind == ttl" (`agent/credits_tracker.py:111-112`), as in Desktop (`apps/desktop/src/store/agent-notices.ts:118-134`). `[client choice]` A `ttl` notice without a usable `ttl_ms` stays; Desktop falls back to its toast default. |
| `notification.clear` | session-routed | `{key}` | Removes that notice (`events.py:344-349`). |

**`sessions.changed`:**
- **What triggers it.** The change watcher hashes the session columns (title, archived, hidden, …)
  of every served profile db every 0.5 s. It broadcasts at most every 2 s, trailing edge included
  (`change_watcher.py:285-331`). Any rename, archive, delete, new row or turn from any client
  triggers it, including every streaming turn.
- `[client choice]` The app refreshes `sessions`, the roster and the visible selected profile’s sessions, at most once per
  `pushedRefreshInterval` (10 s, Desktop's heavy-pass interval, `use-background-sync.ts:1302-1381`),
  with one trailing refresh after a burst. The first change after a quiet period refreshes at once.
  A profile chat's `message.complete` refreshes at once too, so the bot's preview follows the
  finished turn: it replaces a pending trailing refresh and restarts the window, so the turn's
  own `sessions.changed` still collapse behind it. A refresh asked for while one runs queues
  exactly one more.

**`session.reclaimed`:**
- Like Desktop (`gateway-event/lifecycle.ts:123-165`), the app forgets the runtime id and drops
  the requests opened under it (including `otherSessionRequests`), then refreshes the lists.
- Every chat on that runtime, the one on screen or a warm one (§4.2), stays, with
  `ChatSession.isRuntimeGone` set. A turn it still showed as running ends there: nothing will
  complete it.
- Its next action (send, steer, slash command, file upload, model or effort change, rename…)
  resumes it from its stored key first, as a reconnect's cold restore does (§7; a Bot Chat by its
  name, §8.2). Showing a warm one again does the same, without `session.activate`. Resuming at
  once would undo an idle reclaim every TTL. A failed resume shows on the prompt's bubble; a
  chat the gateway no longer has is forgotten.
- Only a Bot Chat on screen is re-resolved at once, by title, as Desktop's bots plugin does
  (`plugins/hermes-bots/plugin.tsx:653-701`). `[client choice]` Not after `lru_evict`, where the
  resume would evict another session in turn.
- One resume per chat at a time: a second action waits for the first, and none starts while a
  reconnect restores the chat or a revisit reconciles it (`ChatSession.settleIdentity`, §7).
- Reads made while the runtime is gone do not resume it: the model list is the profile's, and
  the effort is the last one the session reported.

Other events:
- The contract has no `profiles.changed` or `bots.changed` event. Roster changes reach clients
  only through `sessions.changed` and polling, so the sidebar keeps its 15 s poll.
- The app ignores `projects.changed`, `cron.changed`, `platforms.changed`, `pairing.changed` and
  `bot_relay.outbox.pending` (`change_watcher.py:285-296`); they are out of scope.
