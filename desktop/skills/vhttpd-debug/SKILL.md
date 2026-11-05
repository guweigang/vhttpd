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

## Verify an ordinary Relay carrier

Use the deployment Skill's ordinary Relay configuration flow. A saved connection, a successful temporary `relay_connection_probe`, and a registered live Agent are different states. The Agent must initiate its own WebSocket connection from local vhttpd to remote vhttpd; no SSH forwarding replaces this channel. `relay_runtime_status` exposes selected Agent states and explicitly process-wide counts. It also indicates whether the Relay remains configured.

After `relay_agent_control_apply`, poll `relay_operation_get` before checking registered state. Exercise the actual Hub forwarding path and check the expected response from the local adapter. Repeat after stop to establish that traffic no longer reaches it. Probe again while connected and check that the original carrier remains registered. The current lifecycle persists autostart and restarts the whole selected environment; inspect its other business listeners after each restart.

For a startup or publish failure, retain the config plan ID. `relay_config_restore` accepts the exact known baseline and refuses concurrent config changes; guarded recovery can restore a published plan when its managed runtime is no longer ready. Reclaim the Agent config, Hub listener and temporary catalog records separately, then verify baseline business and closed test ports. Raw tokens and arbitrary credential-bearing URLs do not belong in tool arguments.

## Recover edits to existing Relay definitions

Existing manual configurations use the deployment Skill's `relay_config_get` and `relay_config_edit_prepare/preflight/apply/restore` workflow; they do not require an MCP ownership marker. Check the real relative source and complete configuration revision, especially when the Relay is defined in an include file. The preview masks tokens and URLs, preserving private credentials unless an explicit saved connection reference is selected.

After apply, poll `relay_operation_get`, inspect `relay_runtime_status` and verify real traffic. A running process alone does not prove a changed Hub path or Agent setting is effective. An autostart edit restarts the whole environment; validate its other business listeners. Retain the original plan for exact restoration, including when the managed runtime has stopped. Do not overwrite concurrent changes or reuse a restored plan for another apply.

## Diagnose a database Relay

Use local management MCP and call `relay_database_resources_list` on the bound runtime. For the connected remote environment, supply target_id to inspect its database exports. Match the local resource_id, Relay ID, route and remote_resource to the remote export. This inventory reads the effective configuration; it does not prove database connectivity. Credentials and database addresses stay in configuration.

Call `relay_runtime_status` for the selected Relay, then `relay_database_probe` with the configured local resource_id. The runtime uses its existing Agent carrier, creates a short-lived database client and evaluates only the fixed SELECT 1 AS relay_probe expression; it closes that client after the probe without replacing the carrier. No SQL, URL, credential, transaction handle or arbitrary query is accepted. Successful stage query proves the request crossed the Relay and the MySQL driver returned the expected constant. It does not validate application tables, migrations, permissions for other statements or business data; verify the relevant application separately.

Use the returned stage to choose the next step:

- configuration: inspect resource kind, authenticated Agent binding, export resource and route.
- carrier: inspect Agent registration and the ordinary Relay connection probe before querying again.
- transport: compare route/resource identities with the remote export, inspect remote events and carrier generation. The sent query is not replayed automatically; an uncertain result is not a database authentication diagnosis.
- database: remote database execution failed. Check its configured database, user privileges, service availability and private driver logs in Desktop. This category intentionally does not distinguish authentication from SQL execution without evidence.
- response: the response was malformed or not the expected MySQL constant.
- runtime: check readiness and installed runtime support. runtime_probe_endpoint_unavailable_upgrade_required means the selected runtime lacks this Admin endpoint; use the normal package/upgrade workflow and retain the old package for recovery.

A healthy carrier and a failed database probe can coexist. Keep tokens and raw driver errors out of reports. Re-run the fixed probe after a correction, then verify the actual business request. Probes never change configuration or restart the environment.

## Compare and restore local runtime packages

Keep the baseline package ID from `runtime_packages_list`. Use `runtime_package_probe` before selecting an alternative. Download and install through the deployment Skill's explicit official tag, SHA256 and platform checks; installation alone does not change the selected runtime. Stop the local runtime, prepare/select the installed package, refresh `context_get` for its new binding revision and poll `runtime_package_operation_get`. Check both startup and actual business HTTP before attributing a fault to a version change. To restore the baseline, stop and select its saved package ID, refresh context and verify again. Existing change previews and old public Relay grants cannot be reused across a selection.

## Discover and verify an existing remote environment

Use `environment_discover` to refresh the connected host's candidates. A cached profile is not proof of a working Admin connection. Use `environment_adopt_prepare` and `environment_adopt_apply` to verify authenticated Admin identity and the reviewed configuration before diagnosing an existing target. Read `host_operation_get`, then verify business HTTP. Adoption never rewrites configuration or converts external processes to Desktop ownership. If a different host is needed, finish or inspect pending writes, call `host_disconnect`, and connect the new saved host. Disconnect does not stop its remote applications.

## Diagnose a stopped remote instance

Use `host_connect` for a saved key-authenticated host and poll `host_operation_get`. Password authentication and first-use host trust stay in Desktop. Query `instance_status` over SSH even when Admin is unavailable. A stopped instance can be started with `instance_start_prepare` and `instance_start_apply` after reviewing the plan and confirming in Desktop. Poll the returned operation ID, then wait for a successful business `target_request`; process existence alone is not readiness. To stop an isolated test instance, prepare and confirm `instance_stop_apply` and check live status again. This affects the entire environment. Stop never escalates from graceful SIGTERM to force kill. If stopping remains pending, inspect Desktop and query status before another action.

## Use account-scoped takeover

In Desktop, bind the local source to the remote installation and start the local receiver. The remote Hub and business listener must share a runtime owner. Use the local management MCP.

1. Call `takeover_status` for the registered target and installation. If the receiver or Relay is unavailable, fix the Desktop configuration before retrying.
2. Call `takeover_prepare` with the target, installation, authentication application ID and a single authorized account. Review the receiver and lease duration, then call `takeover_start` with the plan ID and confirm in Desktop.
3. Send the agreed request to the original remote business address and verify local execution. Check that an account outside the lease still executes remotely. A timeout after handoff can leave execution uncertain. Check request ownership before retrying.
4. Call `takeover_release` with the exact lease ID. Use `takeover_status` to confirm remote ownership and issue a fresh request to verify that the remote application serves it.
