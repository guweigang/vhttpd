# Codex Bot application components

Use the `codexbot` Desktop template or adopt the repository component with its `app.json` identity and `component.toml` entry. Read `app.mts`, `config/bot.example.json` and the selected runtime's vjsx and provider schemas.

The template ships the application, protocol types, routing and provider helpers. Its generated provider instances have startup and enable flags disabled. Keep private overrides in the target's `config/bot.local.json`. Check the component preview for all imported source files before installing or releasing.

GET `/` returns HTTP 200 with `app: codexbot-app-ts`. Verify that response to check the application entry. When the task includes a provider, configure its required credentials and resources through Desktop, enable the intended instance and check provider readiness separately. Use `runtime_diagnostics_get(providers)` locally or `target_diagnostics_get(providers)` remotely. An entry response alone does not establish provider readiness.

Edit with file revisions, validate and apply while stopped. Over Relay, poll `runtime_status` after accepted startup and stop on a failed phase. Verify the entry and each enabled provider workflow required by the task.

For remote release, use the target's installation ID for updates and verify the entry after both release and rollback. Use `target_applications_list` to find the application identity and `target_logs_query` to correlate application requests. Read `guidance_get(deploy)` and `guidance_get(debug)` for release and recovery.
