# codexbot-app-ts

TypeScript-first `vjsx` bot example scaffold for `vhttpd`.

Current files:

- `app.mts`: app entry
- `codexbot.toml`: standalone v2 launcher; `component.toml`: Desktop application component
- `config/config.mts`: cached application configuration and path helpers
- `config/bot.example.json`: configuration template; copy to private `config/bot.local.json`
- `config/loader.mjs`: configuration validation and paths relative to the configuration directory
- `config/provider-config.mts`: provider configuration adapter
- `codex/`: vendored Codex protocol subset plus local semantic adapter
- `feishu/`: Feishu inbound and card-policy package boundary for the TS app
- `lib/bot-runtime.mjs`: bot composition root
- `lib/command-router.mjs`: Feishu inbound command routing boundary
- `lib/codex-instance-policy.mjs`: Codex instance resolution and preflight policy boundary
- `lib/codex-query-command.mjs`: `/codex` query command boundary
- `lib/codex-protocol.mts`: compatibility re-export for the Codex semantic adapter
- `lib/bot-text-helpers.mjs`: user-facing text and status rendering boundary
- `lib/busy-guard.mts`: busy/stale-run policy helpers for stream state gating
- `lib/commands.mts`: upstream command helpers
- `lib/feishu.mts`: compatibility re-export for Feishu inbound parsing
- `lib/feishu-card-policy.mts`: compatibility re-export for Feishu thread/item card routing policy
- `lib/item-render-coordinator.mjs`: Feishu item stream / card fan-out coordination boundary
- `lib/codex.mts`: Codex callback parsing
- `lib/notification-router.mjs`: Codex notification routing boundary
- `lib/provider-runtime.mjs`: provider instance config, preflight, and startup boundary
- `lib/project-admin-commands.mjs`: `/create`, `/bind`, and `/unbind` command boundary
- `lib/rpc-router.mjs`: Codex RPC response routing boundary
- `lib/selection-commands.mjs`: project/model/instance selection command boundary
- `lib/session-commands.mjs`: `/settings`, `/threads`, and `/new` command boundary
- `lib/state.mjs`: SQLite-backed chat/stream state
- `lib/thread-task-commands.mjs`: thread selection, busy/cancel, and regular task command boundary

## Module Layers

The TS app is now intentionally split by responsibility instead of growing a single runtime file.

### Composition Root

- `lib/bot-runtime.mjs`: composition root only
- wires helpers, routers, command handlers, and state access together
- should stay thin; it is the assembly point, not the place for protocol or business rules

### Protocol / Rendering Helpers

- `lib/assistant-text-renderer.mjs`: normalizes Codex text into Feishu-safe markdown-ish output
- `lib/bot-text-helpers.mjs`: user-facing status/help/result text builders
- `lib/codex-rpc-helpers.mjs`: `/codex` parsing, default params, result formatting, thread-read extraction
- `lib/codex-start-params.mjs`: `thread/start` and `turn/start` request param builders
- `lib/codex-status-helpers.mjs`: Codex finalizing and terminal-status helpers
- `lib/command-text-rules.mjs`: lightweight command text classifiers like `/use`
- `lib/project-paths.mjs`: cwd/path derivation and directory existence helpers
- `lib/instance-alias.mjs`: shared `default -> main` alias normalization
- `lib/feishu-session-helpers.mjs`: Feishu reply/help session adapter helpers

### Stateful Coordination

- `lib/thread-session-coordinator.mjs`: thread-name cache, pending rename state, queued thread->turn continuation
- `lib/item-render-coordinator.mjs`: Feishu parent/item stream fan-out and item lifecycle coordination
- `lib/provider-runtime.mjs`: provider instance config materialization and startup orchestration
- `lib/state.mjs`: SQLite persistence and state transitions

### Routing / Command Boundaries

- `lib/command-router.mjs`: top-level Feishu command dispatch
- `lib/notification-router.mjs`: Codex notification routing
- `lib/rpc-router.mjs`: Codex RPC response routing
- `lib/codex-query-command.mjs`: guarded `/codex` query command handling
- `lib/project-admin-commands.mjs`: `/create`, `/bind`, `/unbind`
- `lib/selection-commands.mjs`: project/model/instance/session selection
- `lib/session-commands.mjs`: `/settings`, `/threads`, `/new`
- `lib/thread-task-commands.mjs`: busy/cancel/thread/use/plain-text task flow

### External Semantics

- `codex/`: vendored Codex TS semantics used as the source of truth for status/error interpretation
- `feishu/`: Feishu inbound parsing, dedupe, and card policy boundary

## Dependency Direction

Prefer this direction when adding new code:

- composition root -> routers / command handlers / coordinators / helpers
- routers / command handlers -> state + narrow helper modules
- helper modules -> pure formatting / parsing / policy logic
- state stays below command handlers and should not import app-specific routing logic

When a piece of logic starts needing its own vocabulary, tests, or reused dependency injection shape, that is usually the signal to create another helper/coordinator module instead of putting it back into `bot-runtime.mjs`.

## Lifecycle Hooks

`vjsx` app entries can now expose two optional startup hooks:

- `startup(runtime)`: lane-local hook, runs once per executor lane
- `app_startup(runtime)`: app-global hook, runs once per app load and is serialized by `vhttpd`

`examples/codexbot-app-ts` already implements both inside `createBotApp()`, so the default `app.mts` does not need any extra code:

```ts
import { createBotApp } from "./lib/bot-runtime.mjs";

const app = createBotApp();

export default app;
```

If you want to customize them in `app.mts`, override the exported object methods:

```ts
import { createBotApp } from "./lib/bot-runtime.mjs";

const base = createBotApp();

export default {
  ...base,

  async startup(runtime) {
    await base.startup?.(runtime);
    return { commands: [] };
  },

  async app_startup(runtime) {
    const baseResult = await base.app_startup?.(runtime);
    return baseResult || { commands: [] };
  },
};
```

For this example bot:

- `startup(runtime)` is currently lane-local and does no side effects
- `app_startup(runtime)` preflights provider instances for `codex` and `feishu`
- `app_startup(runtime)` may emit `provider.instance.upsert` and `provider.instance.ensure`
- `component.toml` contains only the application's v2 listener, engine, adapter, and pipeline
- Codex and Feishu instances come exclusively from the application's JSON configuration
- `startup: false` disables startup of that instance, including the default instance
- Feishu instances without credentials are skipped; a partial app ID / secret pair is rejected
- each lane reads configuration once when it loads; restart the application after editing it

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
- default DB path is `.var/codexbot.sqlite` inside the application; its parent directory is created automatically
- current TS-first runtime tables are `chat_state`, `stream_state`, and `command_context_state`
- SQLite also keeps `project_registry` and `project_binding_state` so `/projects` can survive project switching
- runtime settings live in the same SQLite file under the `settings` table
- Feishu session scope is now thread-aware: when inbound messages carry `root_id` or `parent_id`, the bot isolates state by thread root instead of collapsing the whole chat into one session
- when a Feishu message arrives from a thread, the initial bot reply is sent back via `message_id` targeting so the placeholder stays in the same conversation branch
- set `bot.db_path` in `config/bot.local.json` to change the DB path
- `/admin/state` requires `Authorization: Bearer <admin.token>`; an empty token disables access, and instance credentials are redacted
- chat rows now expose `sessionKey`; stream rows now expose `sessionKey`, `status`, `resultText`, and `lastEvent`; command context rows expose the last `/use` selection scope per session
- `cancelled` is a normal terminal status when `/cancel` is used
- interrupt is best-effort: the bot sends `turn/interrupt`, then detaches the Feishu/Codex stream bindings so the next prompt is not blocked
- `/projects`, `/models`, and `/threads` remember a selection scope, and that scope stays active across repeated `/use ...` until the next non-`/use` command
- in thread scope, `/use latest` or `/use <thread_id>` also triggers a `thread/read`, so the latest assistant reply is shown immediately
- `/settings` shows persisted config, and `/setting <name> <value>` updates it
- `/codex <method> [json]` allows guarded query-style Codex RPC calls from chat
- `/create <project_key>` uses `bot.project_root` unless `project_root_dir` is overridden in the `settings` table; it fails if the project already exists in SQLite or if the target directory already exists
- `/bind <project_key> [path]` binds a project record to the chat without switching the current session; if `path` is omitted, the bot resolves it from `project_root_dir/<project_key>`
- `/unbind <project_key>` removes the explicit chat binding, but it refuses to unbind the current session project
- `/new [model_id]` clears the current thread and optionally switches model for the next run
- add extra Codex servers and Feishu applications under `codex.instances` and `feishu.instances` in `config/bot.local.json`
- project-to-Codex routing now comes from `project_registry.default_codex_instance`, managed by chat commands instead of static config
- Feishu rendering now uses a hybrid model:
- the parent bot stream still owns the session-level status card and state bookkeeping
- Codex `item/*` notifications fan out into derived item streams, so one turn can render multiple Feishu interactive cards
- `item/agentMessage/delta` uses `stream.append`, and `item/completed` / `rawResponseItem/completed` use `stream.finish`, so vhttpd's built-in Feishu buffering still applies
- parent stream state remains the canonical place for `/thread`, admin snapshots, and project/thread continuity
- Codex status semantics are intentionally aligned with `~/codex/ts`: thread-level `active/systemError` are not treated as turn-level busy states, and structured turn errors are rendered from `TurnError` / `CodexErrorInfo`

## Configuration and Desktop installation

All bot, Feishu, and Codex settings belong to this application. Environment variables are never read as configuration or as fallbacks.

Copy `config/bot.example.json` to `config/bot.local.json` and edit:

- `feishu.instances.main.app_id` and `app_secret`; optionally `verification_token` and `encrypt_key`
- `codex.url`, `model`, `supported_models`, `effort`, `cwd`, `approval_policy`, and `sandbox`
- `bot.project_root`, `default_project`, `db_path`, `active_stream_stale_ms`, and `enable_provider_instance_preflight`
- `admin.token` for authenticated state inspection; leave empty to disable it

The local JSON file is authoritative. If it does not exist, the application uses the checked-in template, which has no Feishu credentials. Invalid JSON, unknown default instances, and invalid policies fail startup without printing secret values.

Every relative configured path resolves against the `config/` directory, using the original application entry rather than the process working directory or a temporary compilation directory. For example, `../.var/codexbot.sqlite` and `../.var/projects` stay inside this application after installation. The reserved `.var/` directory is excluded from code bundles, including managed workspaces. Point `codex.cwd` at an existing workspace accessible to the Codex server. Codex itself must already be installed, authenticated, and serving the configured WebSocket endpoint.

In Desktop:

1. Select the destination runtime environment and choose the application installation action.
2. Select this directory's `component.toml`, preview the changes, and install.
3. In the installed application directory `apps/<installation-id>/`, copy `config/bot.example.json` to `config/bot.local.json` and fill in the actual settings.
4. Restart the runtime environment to load the configuration, then send `/help` from Feishu.

The component uses a dedicated listener and engine. Provider instances are registered dynamically by `app_startup`; credentials do not go into the environment's root TOML. Private `bot.local.json`, `.var/`, and SQLite files are excluded from installation/deployment bundles, so configure each target locally. Subsequent code deployment does not overwrite those files. Do not commit or share the local file.

To install another copy in the same environment, give its listener, engine, adapter, pipeline IDs/group, and HTTP port distinct values in its source `component.toml`. The installation directory alone does not rename resource IDs. Each copy reads its own JSON file and database.

## Standalone run

From the repository root:

```bash
cp examples/codexbot-app-ts/config/bot.example.json examples/codexbot-app-ts/config/bot.local.json
# Edit bot.local.json before starting.
make vhttpd
./vhttpd --config examples/codexbot-app-ts/codexbot.toml
```

Build a new runtime for this version: normal builds now enable vjsx SQLite support, which Codexbot requires. To reuse an existing session database, explicitly set `bot.db_path` to that database; no legacy environment setting is consulted.

The standalone launcher includes the same component and adds its own control listener. Change the standalone control token in `codexbot.toml` before using it.

## Multiple instances

Add additional named entries to `codex.instances` or `feishu.instances` in the local JSON file. Codex instance entries can override URL, model, effort, cwd, approval policy, sandbox, reconnect delay, and flush interval. Feishu entries contain their own credential set. Use `startup: false` when an instance should be connected only when selected through preflight.

Project routing remains in SQLite under `project_registry.default_codex_instance`. Use `/project-instance <project_key> <instance>` to set a project default and `/instance <name>` to override the current session.

## Verification

```bash
node --test examples/codexbot-app-ts/tests/config.test.mjs
make test-codexbot
make test src/app_bundle/codexbot_test.v
```

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
- `/project-instance <project_key> <instance>`: set the default Codex instance for a bound project
- `/instances`: list known Codex instances
- `/instance`: show the current session instance and current project default
- `/instance <name>`: switch only the current session to another configured Codex instance
- `/models`: list configured models and enter model selection scope
- `/model`: show the current model
- `/model <model_id>`: switch model and clear the current thread binding
- `/threads`: list recent threads for the current project and enter thread selection scope
- `/thread`: show the current bound thread plus last stream summary and recent interaction summaries
- `/thread <thread_id>`: bind the current session to a known thread id
- `/thread rename <title>`: rename the current bound Codex thread via `thread/name/set`
- `/use latest`: in thread scope, bind the latest known thread for the current project and immediately read it
- `/use <value>`: reuse the last listing scope to switch project/model/thread; the scope stays active until the next non-`/use` command
- `/new [model_id]`: clear the current thread; with a model id, switch model too
- `/cancel`: interrupt the active turn when possible, otherwise detach the active run
- plain text: start a new Codex task or continue on the selected thread

Useful checks:

```bash
curl --noproxy '*' -sS http://127.0.0.1:19883/health
curl --noproxy '*' -sS 'http://127.0.0.1:19883/dispatch?path=/health'
curl --noproxy '*' -sS -H 'Authorization: Bearer <application-admin-token>' http://127.0.0.1:19883/admin/state
curl --noproxy '*' -sS -H 'x-vhttpd-admin-token: change-me' http://127.0.0.1:19983/admin/runtime
```

Notes:

- `GET /health` is host-level health and does not enter the TS/vjsx app
- `GET /dispatch?path=/health` enters the TS/vjsx app and will trigger `startup(runtime)` and `app_startup(runtime)` on first dispatch
- `GET /admin/state` on the data plane also enters the TS/vjsx app in this example

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
