# codexbot-app-ts

TypeScript-first `vjsx` bot example scaffold for `vhttpd`.

Current files:

- `app.mts`: app entry
- `codexbot.toml`: example `vjsx` executor config
- `lib/bot-runtime.mjs`: bot composition root
- `lib/commands.mts`: upstream command helpers
- `lib/feishu.mts`: Feishu inbound parsing
- `lib/codex.mts`: Codex callback parsing
- `lib/state.mjs`: SQLite-backed chat/stream state

Current bot flow:

1. Feishu `im.message.receive_v1`
2. `/help`, `/projects`, `/project`, `/models`, `/model`, `/threads`, `/thread`, `/use`, `/new`, `/cancel`
3. `/settings` and `/setting` manage runtime config in SQLite
4. `/codex` can issue query-style Codex RPC calls from chat
5. `/create`, `/bind`, and `/unbind` manage chat-local project contexts in TypeScript
6. plain text -> `provider.message.send` + `provider.rpc.call(thread/start)`
7. Codex `codex.rpc.response` binds returned `threadId`
8. Codex `codex.notification` updates the same Feishu stream message
9. SQLite persists chat binding, stream draft, final result, lifecycle status, and settings
10. one chat only allows one active run at a time; overlapping prompts are rejected with a busy hint
11. `/cancel` sends `turn/interrupt` when the bot already knows `threadId + turnId`; otherwise it falls back to a detach-style cancel

Notes:

- state is persisted in SQLite
- default DB path is `tmp/codexbot-app-ts.sqlite`
- current TS-first runtime tables are `chat_state`, `stream_state`, and `command_context_state`
- SQLite also keeps `project_registry` and `project_binding_state` so `/projects` can survive project switching
- runtime settings live in the same SQLite file under the `settings` table
- Feishu session scope is now thread-aware: when inbound messages carry `root_id` or `parent_id`, the bot isolates state by thread root instead of collapsing the whole chat into one session
- when a Feishu message arrives from a thread, the initial bot reply is sent back via `message_id` targeting so the placeholder stays in the same conversation branch
- use `CODEXBOT_TS_DB_PATH` to override the DB file path
- `/admin/state` is for runtime inspection of the bot session store, not a separate product target
- chat rows now expose `sessionKey`; stream rows now expose `sessionKey`, `status`, `resultText`, and `lastEvent`; command context rows expose the last `/use` selection scope per session
- `cancelled` is a normal terminal status when `/cancel` is used
- interrupt is best-effort: the bot sends `turn/interrupt`, then detaches the Feishu/Codex stream bindings so the next prompt is not blocked
- `/projects`, `/models`, and `/threads` remember a selection scope, and that scope stays active across repeated `/use ...` until the next non-`/use` command
- in thread scope, `/use latest` or `/use <thread_id>` also triggers a `thread/read`, so the latest assistant reply is shown immediately
- `/settings` shows persisted config, and `/setting <name> <value>` updates it
- `/codex <method> [json]` allows guarded query-style Codex RPC calls from chat
- `/create <project_key>` now reads `project_root_dir` from the `settings` table, matching the PHP bot; it fails if the project already exists in SQLite or if the target directory already exists
- `/bind <project_key> [path]` binds a project record to the chat without switching the current session; if `path` is omitted, the bot resolves it from `project_root_dir/<project_key>`
- `/unbind <project_key>` removes the explicit chat binding, but it refuses to unbind the current session project
- `/new [model_id]` clears the current thread and optionally switches model for the next run

## Run

Build and start:

```bash
cd /Users/guweigang/Source/vhttpd
make vhttpd
export FEISHU_APP_ID=...
export FEISHU_APP_SECRET=...
export FEISHU_VERIFICATION_TOKEN=...
export FEISHU_ENCRYPT_KEY=...
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/codexbot-app-ts/codexbot.toml
```

Required env vars:

- `FEISHU_APP_ID`
- `FEISHU_APP_SECRET`
- `FEISHU_VERIFICATION_TOKEN`
- `FEISHU_ENCRYPT_KEY`

Usually optional:

- `CODEX_URL`: defaults to `ws://127.0.0.1:4500` in `codexbot.toml`
- `CODEXBOT_TS_DEFAULT_CWD`: defaults to `process.cwd()`
- `CODEXBOT_TS_DEFAULT_PROJECT`: defaults to `demo`
- `CODEXBOT_TS_DEFAULT_MODEL`: defaults to `gpt-5.4`
- `CODEXBOT_TS_SUPPORTED_MODELS`: defaults to `gpt-5.4,gpt-5.3-codex`
- `CODEXBOT_TS_DB_PATH`: defaults to `tmp/codexbot-app-ts.sqlite`
- `CODEXBOT_TS_APPROVAL_POLICY`: defaults to `never`
- `CODEXBOT_TS_SANDBOX`: defaults to `workspace-write`

## Commands

- `/help`: show the current command summary
- `/settings`: show all persisted settings
- `/setting <name> <value>`: upsert a setting, for example `/setting project_root_dir /Users/me/workspaces`
- `/codex <rpc_method> [json_params]`: run safe query-style Codex RPC calls like `/codex model/list` or `/codex thread/read {"threadId":"...","includeTurns":true}`
- `/create <project_key>`: create a fresh project directory below the configured `project_root_dir` and switch to it; it errors if the project key already exists or if the target directory already exists
- `/bind <project_key> [path]`: register or complete a project record, then bind it to the chat without switching the current session
- `/unbind <project_key>`: remove the explicit chat binding for a project; if it is the current session project, switch away first
- `/projects`: list projects explicitly bound to this Feishu chat and enter project selection scope
- `/project`: show the current project and cwd
- `/project <project_key>`: switch to a bound project, reset thread binding, and update cwd
- `/models`: list configured models and enter model selection scope
- `/model`: show the current model
- `/model <model_id>`: switch model and clear the current thread binding
- `/threads`: list recent threads for the current project and enter thread selection scope
- `/thread`: show the current bound thread plus last stream summary
- `/thread <thread_id>`: bind the current session to a known thread id
- `/use latest`: in thread scope, bind the latest known thread for the current project and immediately read it
- `/use <value>`: reuse the last listing scope to switch project/model/thread; the scope stays active until the next non-`/use` command
- `/new [model_id]`: clear the current thread; with a model id, switch model too
- `/cancel`: interrupt the active turn when possible, otherwise detach the active run
- plain text: start a new Codex task or continue on the selected thread

Useful checks:

```bash
curl --noproxy '*' -sS http://127.0.0.1:19883/health
curl --noproxy '*' -sS http://127.0.0.1:19883/admin/state
curl --noproxy '*' -sS -H 'x-vhttpd-admin-token: change-me' http://127.0.0.1:19983/admin/runtime
```

What to look for in `/admin/state`:

- `chats[].threadId`: whether the current Feishu chat is already bound to a Codex thread
- `streams[].draft`: the latest streamed draft text
- `streams[].status`: `queued`, `thread_ready`, `streaming`, `completed`, or `error`
- `streams[].resultText`: the latest stable message text we want to preserve
- `streams[].lastEvent`: the last upstream event that changed this stream
- `commandContexts[].scope`: whether the session is waiting for `/use` to select a `project`, `model`, or `thread`

Expected first real loop:

1. Send `/help` from Feishu
2. Send a plain text prompt
3. Feishu receives an immediate queued message
4. Codex `thread/start` response binds a thread
5. Codex notifications update the same Feishu stream message
6. `curl /admin/state` shows the same stream moving from `queued` to `thread_ready` to `streaming` or `completed`
