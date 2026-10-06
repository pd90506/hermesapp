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
| `prompt.submit` | `{session_id, text}` | `{status:"streaming"\|"queued"\|"steered"\|"redirected", user_row_id?}`. For an idle session it returns immediately and the turn streams as events. A busy session queues, steers or redirects according to `display.busy_input_mode`. The Desktop allows 1800 s for the ack (`apps/desktop/src/api/client.ts:27`), and so does `GatewayClient`. It also re-binds a detached session (methods_prompt.py:741-747). | prompt_voice.py:26-77; methods_prompt.py:681-831 |
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
    That cost stays on the server; nothing more goes over the wire. The app sends no `source`.

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
- **No matching.** Live and stored content are never matched: no text, row-id, call-id or anchor
  comparison. While a turn runs, some content can show twice:
  - the stored part of a turn that was already running at open (Hermes stores each tool round
    before its tools run, `agent/turn_tool_round.py:127-130`);
  - its echoed `inflight.user`;
  - a prompt the history already holds.
- **When a turn finishes** (`message.complete`, from any source), the app reads the newest rows
  again:
  - same endpoint, `order=latest`, 120 rows;
  - older pages only until one overlaps the shown rows, at most 4 pages, never the whole history;
  - one re-read at a time, and a turn that finishes meanwhile gets the next one.
- **What the re-read does.** It replaces the shown history from the first shown row it holds
  onward. Older pages the user loaded stay. If it overlaps nothing (more new rows than 4 pages), it
  becomes the history, and older rows load again by scrolling.
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

  The quiet rule exists because a follow-up turn announces itself with `message.start` before it
  stores its prompt (`prompt_turn.py:421-427`). Follow-up turns are a queued prompt, or a steer the
  turn couldn't deliver, which is re-queued after the turn (`prompt_turn.py:438-450`,
  `agent/turn_finalizer.py:742-746`). Until such a turn finishes, the bubble stays.

  How many quiet re-reads a prompt needs depends on its answer:
  - **`streaming` with `user_row_id`: one.** Its row was written before the answer
    (`methods_prompt.py:815-819`), so the first quiet re-read holds it, and the bubble never sits
    below its own reply.
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
    once the first had landed. `message.start` travels on the socket in batches of about 33 ms
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
  was running at open, and a prompt the history already holds. They clear when that turn's re-read
  lands.
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

## 5. Events a chat client handles

From `contracts/events.py`:

| `type` | payload | Client behaviour |
|---|---|---|
| `message.start` | none | Open an assistant segment. |
| `message.delta` | `{text, rendered?}` | Append the text. |
| `reasoning.delta` / `thinking.delta` (legacy) | `{text}` | Append to the reasoning. |
| `reasoning.available` | `{text}` | Whole reasoning block from a non-streaming provider. |
| `message.interim` | `{text, already_streamed}` | Commentary beside tool calls, "sealed as its own segment". `[unverified]` Exactly how this splits segments is inferred from the contract summary. |
| `tool.generating` | `{name}` | |
| `tool.start` | `{tool_id, name, context?, args?, preview?}` | Add a tool row. |
| `tool.complete` | `{tool_id, name, duration_s?, summary?, result?, result_text?, …}` | Finish the tool row. |
| `status.update` | `{kind, text}` | Transient status line. |
| `message.complete` | `{text: str \| JsonValue, status?: complete\|error\|interrupted, reasoning?, error?, usage?, persisted_turn?, …}` (`events.py:189,205`; decode `text` as any JSON). The app does not use `persisted_turn`; it re-reads the newest rows instead (§4.1). | **The terminal frame of every turn.** Errors inside a turn arrive here with `status:"error"`; there is no separate turn-end event (`events.py:138-208`, `session_auto_continue.py:555-581`). `[unverified]` When a turn contained tool calls, the app shows the streamed segments and uses `text` only when nothing was streamed; the doc does not say whether `text` is the last segment or the whole reply. |
| `session.title` | `{session_id:<stored id>, title}` | Rename. |
| `session.info` | `SessionLiveInfo` | |
| `error` | `{message}` | A session-level failure outside a turn. |
| `request.cancel` | `{id, method, reason}` | Remove the matching server-request card. |
| `approval.cancelled` | `{session_id, request_ids:[approval request_id], reason, …}` | Broadcast globally (`session_lifecycle.py:505-510`). |

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
  | `clarify` | `{questions:[{qid, question, choices?, multi_select}], answers?}` | `{answers:{qid: string\|null}}`. Omitting `answers` cancels. Per-question locking uses the `clarify.lock` RPC. |
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
    session, and every 15 s while the sidebar is shown. Desktop polls every 5 s
    (`methods_profiles.py:249-250`).
  - **Side effect:** History lists every profile, so the gateway serves profiles other than its
    launch profile from the first poll on. The first call scoped to such a profile switches it
    into multi-profile hosting: launch-profile secrets are frozen, and unscoped secret reads
    fail closed (`server.py:579-586`, `tui_gateway/launch_profile_policy.py`). Desktop's remote
    mode does the same.

### 8.2 Opening the Bot Chat

The Bot Chat's only identity is **(profile, session titled exactly `Bot Chat`)**. The state
DB's title uniqueness makes that a registry of at most one row per profile
(`apps/desktop/src/AGENTS.md`, Bot Mode). **No session id is ever stored as the bot's chat or
used as a fallback.** Every open of a bot (`GatewayConnection.openBotChat(profile:)`) looks the
chat up again. The one exception: if that bot's Bot Chat is already on screen, the open returns
it as it is.

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

### 8.3 Side chats and History

- **Side chat.** A side chat ("New chat with this agent" in Desktop) is a plain
  `session.create {profile}`: no title, not hidden. It is never the bot row's target.
- **History** lists each bot's sessions: `session.list {profile, limit:20}` per profile.
  - **Order:** grouped by bot in roster order, keeping the server's order within each bot. The
    server orders by most recent activity (`methods_session.py:149-152`).
  - **No cross-bot merge:** listing rows carry no activity time (`methods_session.py:118-126`),
    so different bots' rows can't be merged by it.
  - **What is left out:** Bot Chat rows. A Bot Chat row has `root_title` (when the gateway sends
    it) or `title` equal to `Bot Chat`, or its id is the roster's `canonical_session.id` /
    `resolved_id`.
    - Bot Chats are normally hidden anyway: Desktop creates them with `hidden:true` and its sweep
      re-hides them (`plugins/hermes-bots/hide-bot-chats.test.ts:1-16`).
    - A *visible* row titled `Bot Chat` is left out too. The title lookup doesn't filter on
      `hidden` (`methods_session.py:526-550`), so that row is what the bot row opens.
    - Hermes uses `hidden` only to decide whether such a row may be renamed
      (`hermes_state_titles.py:100-110`).
  - `[client choice]` The app does not run that sweep. It never writes `hidden`.
- **Opening a History row:** `session.resume {session_id, profile, omit_messages:true,
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

## 10. Composer: model, reasoning effort, images, voice

The composer mirrors Hermes Desktop's (`apps/desktop/src/app/chat/composer/`). Every call below
carries the chat's runtime `session_id`, plus its `profile` when it has one (§8.1). Without
`profile`, `@_profile_scoped` handlers take the scope from the live session named by
`session_id` (`server.py:598-623`).

Swift: `HermesProtocol/ComposerMethods.swift` holds the wire types. `HermesKit/Composer/` and
`ChatSession` hold the logic.

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
- `[client choice]` **Upload at send, like Desktop's remote mode.** Desktop does not upload images
  eagerly (`use-prompt-actions/index.ts:439-443`).
  - Images stay on the device until Send. Then they are uploaded one by one, and then
    `prompt.submit` is sent.
  - Removing a card is local; nothing is queued yet.
  - If an upload fails, the images already queued are detached, the cards stay, the draft comes
    back, and the composer shows the error.
  - If `prompt.submit` fails, the queued images are detached too, and the cards and draft stay for
    a retry.
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
  - An image prompt's stored row carries `@image:<path>` lines rather than the bubble's
    `[Image: name]` text (`tui_gateway/session_history.py:51-60`). That is fine: bubbles settle by
    quiet re-reads, never by matching text.
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
