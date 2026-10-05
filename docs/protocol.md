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
  - `POST /auth/native/refresh {"refresh_token","provider"}` returns the same shape
    (`routes.py:519-547`).
  - Use the token as `Authorization: Bearer` for the ticket mint.
  - **App mode "Access token (ticket)"** takes such a token. The package has the PKCE helpers
    (`PKCE`, `DashboardClient.nativeAuthorizeURL/exchangeNativeCode/refreshNativeTokens`). The
    loopback-listener UI is not built yet.
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
| `session.list` | `{limit?, include_hidden?}` | `{sessions:[{id, title, preview, started_at, message_count, source}]}` | sessions.py:221-246 |
| `session.create` | `{title?, cwd?, model?, provider?, source?, close_on_disconnect?=false}` | `{session_id, stored_session_id, message_count, messages, info}`. The DB row appears on the first prompt. | sessions.py:118-151 |
| `session.resume` | `{session_id:<stored id or exact title>}` | `LiveSessionSnapshot`: `{session_id, message_count, messages:[TranscriptMessage], info, session_key, resumed?, running?, status?, inflight?, open_requests?, pending_approval?, …}` (see the note on stored keys below) | sessions.py:73-98,182-202; methods_session.py:898-914; server.py:3172-3186 |
| `session.activate` | `{session_id:<runtime id>, omit_messages?}` | same snapshot. **Re-binds this socket to a live session and cancels its orphan reap**; 4001/4007 if it is gone. | methods_session.py:1160-1172 |
| `session.history` | `{session_id}` | `{count, messages}` | sessions.py:484-494 |
| `prompt.submit` | `{session_id, text}` | `{status:"streaming"\|"queued"\|"steered"\|"redirected", user_row_id?}`. For an idle session it returns immediately and the turn streams as events. A busy session queues, steers or redirects according to `display.busy_input_mode`. The Desktop allows 1800 s for the ack (`apps/desktop/src/api/client.ts:27`), and so does `GatewayClient`. It also re-binds a detached session (methods_prompt.py:741-747). | prompt_voice.py:26-77; methods_prompt.py:681-831 |
| `session.interrupt` | `{session_id}` | `{status:"interrupted"\|"not_interrupted"}`. It also cancels the session's open server requests. | sessions.py:598-614 |
| `session.close` | `{session_id}` | `{closed}`. The stored row stays resumable. | sessions.py:385-394 |
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
| `message.complete` | `{text: str \| JsonValue, status?: complete\|error\|interrupted, reasoning?, error?, usage?, …}` (`events.py:189`; decode `text` as any JSON) | **The terminal frame of every turn.** Errors inside a turn arrive here with `status:"error"`; there is no separate turn-end event (`events.py:138-208`, `session_auto_continue.py:555-581`). `[unverified]` When a turn contained tool calls, the app shows the streamed segments and uses `text` only when nothing was streamed; the doc does not say whether `text` is the last segment or the whole reply. |
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
4. Otherwise, call `session.resume {session_id:<stored key>}` and rebuild the transcript from
   `messages` + `inflight`; re-deliver `open_requests`. The held-back events are dropped; the
   snapshot supersedes them.
5. A fresh `connect()` (e.g. the iOS app returning to the foreground) restores the active session
   the same way.
   - The session is cleared only when restore fails with 4001/4007 (session gone). Resume of an
     unknown stored id is 4007 (`methods_session.py:833`).
   - Any other error fails the connect and keeps the session for the next attempt: 4009
     "disconnect interrupt settling" (`session_lifecycle.py:821-822,953-955`), 5000, -32000, …

`[unverified]` Events emitted between the re-bind and the resume snapshot on the step-4 fallback
could be counted twice or missed. The window is small and not covered by the server's contract.

## 8. HTTP API server (secondary option, not used by the MVP)

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
