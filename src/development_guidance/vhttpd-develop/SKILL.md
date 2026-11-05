---
name: vhttpd-develop
description: Create, install, edit and verify vhttpd applications through Desktop MCP. Use for vjsx HTTP and JSON apps, TOML pipelines, WeChat cloud compatibility, Codex Bot, and local runtime verification.
---
# Develop a vhttpd application

Choose the environment in Desktop. To create or install a component through MCP, explicitly open a local workspace session for a stopped environment. Call `application_templates_list`, then `application_install_prepare` with a component name and template. For an existing component, supply its workspace-relative `app.json` or component TOML path and retain its existing application identity. Review the file actions and call `application_install_apply` with the plan ID. Close the workspace connection and bind the installed app in Desktop before editing through Relay or preparing a remote release.

| Template | Starting point | Local verification |
| --- | --- | --- |
| `pipeline` | `component.toml` declares the listener, path match, pipeline and adapter. Read the target schema for each kind. | GET /healthz returns 200 and pipeline-ok. A path outside the match returns 404. |
| `wechat-cloud-functions` | `cloudfunctions/<name>/index.js` exports `main` and loads the bundled `wx-server-sdk` compatibility API. The client wrapper is in `client/vhttpd.js`. | GET /healthz invokes the bundled hello function and returns its message. |
| `codexbot` | Start at `component.toml` and `app.mts`. Review `config/bot.example.json` for provider instances and startup flags. | GET / returns 200 with `app: codexbot-app-ts`. Verify provider readiness separately when enabled. |

For the WeChat template, `cloud.init`, `getWXContext`, `callFunction`, and supported database and storage operations are implemented in `lib/cloud`. Inspect the bundled implementation for supported options. The health probe uses a fixed diagnostic invocation without a WeChat account. To enable authenticated calls, supply WeChat credentials in the target environment, connect a PostgreSQL or MySQL resource to the engine, and apply the matching bundled schema files. Then verify `POST /auth/login` and `POST /functions/<name>` through the client. For Codex Bot, enable only configured provider instances and keep private overrides in `config/bot.local.json` on the target.

Read the project contract for the selected shape. Use `guidance_get` with topic `pipeline`, `wechat-cloud-functions` or `codexbot`, or consult the matching reference below. Topic `workflow` supplies the Desktop package's current copy of this Skill, including Relay startup behavior. Topics `deploy` and `debug` supply the other two Desktop Skills with source and version metadata.

- [TOML pipeline contract](references/pipeline.md) covers configuration ownership and matching and unmatched requests.
- [WeChat compatibility contract](references/wechat-cloud-functions.md) covers function loading, supported SDK operations, credentials and validation.
- [Codex Bot contract](references/codexbot.md) covers entry verification and provider readiness.

Choose the method, path, expected status and response before editing. For application edits, use the following loop.

1. Call `context_get`. Check the selected application, runtime package version, script profile and environment impact. Send its `binding_revision` with subsequent calls. If the binding changes, reread context and confirm the intended application before continuing.
2. Call `capabilities_list` to check which tools are available to this session. On a selected project, set `include_runtime` to `true` to discover configuration domains from the target runtime. Use `schema_get` for a specific domain or kind. Read `guidance_get` with topic `project` for local conventions. For vjsx APIs use `guidance_get` with topic `vjsx` from the selected runtime. When working from the matching runtime package, consult [the vjsx script reference](references/vjsx.md). Use `templates_list` to compare runnable HTTP and JSON API templates and `schema_get` for configuration fields.
3. Use `files_list` and `files_read` to find the configured entry and get each file revision. Preserve secret placeholders. Send those revisions to `changes_prepare`, inspect the diff, then call `changes_validate`. A successful configuration check is followed by startup and a business request to verify JavaScript behavior.
4. Confirm the impact before stopping a running shared environment. Apply with `changes_apply` while stopped, then start with `runtime_start`. Over Relay, startup returns `accepted` before warmup finishes. Poll `runtime_status` with the binding revision until `readiness` is `ready`, ending on a failed or stopped phase. Verify the listener, status code and response using `application_request`. Keep the restore record until verification passes.
5. On startup or response failure, inspect `logs_query`, stop the runtime if it is running, call `changes_restore`, then restart and verify the baseline. If a file revision conflicts, reread it and prepare a new diff. Restore records belong to the current Desktop session.
