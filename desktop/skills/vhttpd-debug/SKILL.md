---
name: vhttpd-debug
description: Diagnose a vhttpd application with Desktop MCP and Workbench. Use for local reproduction, request and log correlation, remote inspection, and authorized account-scoped takeover.
---
# Debug a vhttpd application

Call `context_get` to confirm the bound application and capture its `binding_revision`. For remote work, use the local management connection and call `targets_list` then `target_status` for the environment. Keep local source, local runtime and remote installation identities distinct in your notes.

## Reproduce and identify the failing layer

For a running local environment, call `runtime_diagnostics_get` with `graph` to trace listeners, pipelines and adapters. Use `workers` for process health and load, `providers` for desired versus connected state, and `relay` for carrier counts, agent states and pending frames. These snapshots cover the whole environment, so use a local Desktop session. Use topic `websocket` for process-wide connection and room counts. On a connected remote target, `target_diagnostics_get` accepts the same topics. `relay_connections_list` reports saved connection IDs and whether credentials are present. Compare the saved Relay ID with the target's live agent ID when a carrier handshake fails. A Relay requires vhttpd at both ends, with the local Agent actively establishing the full-duplex WebSocket connection to the remote Hub. If the runtime is stopped, use `runtime_package_get` and `schema_get` to confirm the package and its supported configuration before starting.

1. Read `runtime_status` and query a narrow set of recent entries with `logs_query`. Search by the request or trace ID when available. For a remote installation, call `target_applications_list` for live application and installation identities, then `target_logs_query` with that application ID. Use `cursor` from `next_cursor` for subsequent entries and a request or trace ID as the search string. Use `target_events_query` for bounded environment event correlation. Known target credentials are masked and storage paths are omitted. Record the target, application, time, request method, path, response status and correlation ID.
2. Reproduce locally using the bound business listener and `application_request`. Prefer a read-only request where it reproduces the issue. Confirm the request's data effects before using a write method.
3. Compare the local response with the remote evidence. Use `target_request` for a GET or HEAD probe of the discovered target business listener, then correlate `target_logs_query` and `target_events_query`. Use `guidance_get` and `schema_get` for the bound runtime's supported APIs and configuration. If a source fix is needed, follow the revision-based workflow in `vhttpd-develop`.

For a TOML pipeline, compare a matching and an unmatched request, then inspect the configured listener, match and adapter. For WeChat, verify the compatibility hello route first and diagnose authenticated calls through login, function lookup and resource configuration. For Codex Bot, verify the application JSON at GET /, then inspect provider startup and connection state separately. Record any provider or resource that was disabled during the test.

For shared remote pipeline changes, use the deployment Skill's `shared_config_diff` and `shared_config_preflight` tools. Record the expected status for both the old and new paths before applying. After a timeout, compare the target's loaded and on-disk revisions before retrying or restoring.

## Use account-scoped takeover

In Desktop, bind the local source to the remote installation and start the local receiver. The remote Hub and business listener must share a runtime owner. Use the local management MCP.

1. Call `takeover_status` for the registered target and installation. If the receiver or Relay is unavailable, fix the Desktop configuration before retrying.
2. Call `takeover_prepare` with the target, installation, authentication application ID and a single authorized account. Review the receiver and lease duration, then call `takeover_start` with the plan ID and confirm in Desktop.
3. Send the agreed request to the original remote business address and verify local execution. Check that an account outside the lease still executes remotely. A timeout after handoff can leave execution uncertain. Check request ownership before retrying.
4. Call `takeover_release` with the exact lease ID. Use `takeover_status` to confirm remote ownership and issue a fresh request to verify that the remote application serves it.
