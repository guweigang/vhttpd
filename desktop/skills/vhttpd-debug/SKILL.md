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

For shared configuration, use shared_config_get to identify the actual component, source and safe field, then the deployment Skill's shared_config_edit_prepare/preflight/apply/restore workflow. Do not assume configuration is limited to pipeline paths: methods, hosts, routing references, response options, numeric policies and other allowed scalar/array fields can be edited together across shared includes. Preserve the expected matching, nonmatching and response behavior before applying. Poll shared_config_operation_get after accepted, then compare loaded/disk revisions and actual requests; every apply or restore restarts the whole environment.

For persisted recovery, call config_history_list, select the intended version_id and create a fresh config_history_restore_prepare plan, run config_history_restore_preflight and confirm config_history_restore_apply. Existing local Desktop GUI versions are included. Manual ready configurations can be retained using config_history_capture; a list is not a claim that a version matches the running instance. Version IDs survive Desktop restart; edit/restore plan IDs and operation records do not. Restore verifies the full current revision and exact source membership and shows a safe configuration preview. After validation, config_history_restore_undo can return to the preceding configuration, including through guarded recovery after the managed runtime stops. Recheck business responses after both operations.

A missing source, include topology change, changed protected credentials/paths, app source or control/Admin identity requires Desktop recovery. A new restore preparation requires a running effective configuration; listing history does not. Do not retry a failed/uncertain write blindly or overwrite concurrent edits. configuration_effective_history_save_failed_check_status means a publication may already be effective even though the new snapshot could not be saved: inspect live state and retain the earlier baseline. The old shared_config_diff flow still works for its exact path-only case.

## Diagnose a source workspace

A context with mode source_workspace uses an original directory without installation. Start with source_workspace_get: distinguish missing/invalid configuration from a runnable configuration and from a changed directory identity. An empty directory or an existing repository without vhttpd.toml can be edited before it is runnable. Add or repair the configured relative entry, validate its includes inside the bound source root, then verify startup and business requests. An installed application identity is not required for local source development.

Keep changes recovery records while debugging. Stop before changes_restore, verify the original bytes and response, then restore or deliberately discard every applied record before source_workspace_unbind or binding another project. Unbind releases access to that project; it does not delete source or undo the scaffold. Old revisions and previews cannot be reused. A plan/source conflict requires a fresh preview, and a replaced directory requires a new binding. Do not use source binding to widen the Desktop-selected authorization root. Source-only sessions do not grant platform management or remote installation; use their existing authorized workflows separately.

## Verify application protocols

Use application_protocol_probe on the bound local business listener, or target_protocol_probe on a connected registered target. Select protocol stream, websocket or mcp, a configured listener ID and a relative path. These tools require editing authorization because a WebSocket message can change business state; remote execution also requires Desktop confirmation. Use a disposable message and check its expected response. Never use this to probe the Relay carrier path or the Admin listener.

For stream, inspect status, content_type, complete SSE events and the bounded sample. max_items (1–8) limits complete data events; timeout_ms (100–5000) and 64 KiB limit collection. Sampling returns before a persistent stream ends. Partial bytes do not count as a complete SSE event. A 200 JSON response alone does not prove SSE or continuous delivery; verify the expected content type and data.

For websocket, message is an optional single text frame (up to 4096 bytes). Inspect handshake separately from received_text and messages: a successful upgrade without a reply is not an echo success. The probe answers Ping, samples at most eight unfragmented text frames and sends Close on exit. Fragmented, compressed, binary or oversized frames are outside this bounded probe; use application-specific verification for those protocols.

For mcp, the tool uses Streamable HTTP, negotiates 2025-03-26, sends notifications/initialized and tools/list, and reports bounded tool names/count without session headers. It accepts JSON or SSE JSON-RPC responses and attempts DELETE for a created session, including on errors. It does not invoke business tools, paginate the full catalog, supply credentials or prove arbitrary MCP business operations. An authenticated endpoint requires its existing application-specific workflow. MCP here is the application's business interface, separate from the Desktop MCP being used by the agent.

No custom URL, headers or credentials are accepted. Plaintext HTTP/WebSocket probes select the loopback address from the configured business listener: IPv4 bindings use 127.0.0.1; ::1 and :: bindings use ::1, with a bracketed IPv6 Host authority. Both application_protocol_probe and target_protocol_probe return address_family (ipv4 or ipv6). Check that field as well as the expected SSE events, WebSocket reply or MCP tools; an IPv4 success does not prove the IPv6 listener. No DNS fallback, proxy, route or system network change is needed. Test in an isolated application and keep the Admin listener separate. TLS and advanced WebSocket framing require separate coverage. Results redact known configuration secrets, but application samples are still business data: use an isolated fixture. A protocol failure does not restart or modify configuration and must not trigger an automatic replay of a sent message. Correlate application logs before retrying.

## Verify an ordinary Relay carrier

Use the deployment Skill's ordinary Relay configuration flow. A saved connection, a successful temporary `relay_connection_probe`, and a registered live Agent are different states. The Agent must initiate its own WebSocket connection from local vhttpd to remote vhttpd; no SSH forwarding replaces this channel. `relay_runtime_status` exposes selected Agent states and explicitly process-wide counts. It also indicates whether the Relay remains configured.

After `relay_agent_control_apply`, poll `relay_operation_get` before checking registered state. Exercise the actual Hub forwarding path and check the expected response from the local adapter. Repeat after stop to establish that traffic no longer reaches it. Probe again while connected and check that the original carrier remains registered. The current lifecycle persists autostart and restarts the whole selected environment; inspect its other business listeners after each restart.

For a startup or publish failure, retain the config plan ID. `relay_config_restore` accepts the exact known baseline and refuses concurrent config changes; guarded recovery can restore a published plan when its managed runtime is no longer ready. Reclaim the Agent config, Hub listener and temporary catalog records separately, then verify baseline business and closed test ports. Raw tokens and arbitrary credential-bearing URLs do not belong in tool arguments.

## Recover edits to existing Relay definitions

Existing manual configurations use the deployment Skill's `relay_config_get` and `relay_config_edit_prepare/preflight/apply/restore` workflow; they do not require an MCP ownership marker. Check the real relative source and complete configuration revision, especially when the Relay is defined in an include file. The preview masks tokens and URLs, preserving private credentials unless an explicit saved connection reference is selected.

After apply, poll `relay_operation_get`, inspect `relay_runtime_status` and verify real traffic. A running process alone does not prove a changed Hub path or Agent setting is effective. All edits and restores restart the whole environment; validate its other business listeners. For role conversion, check the new role, automatic removal of incompatible fields and saved connection reference; hub → agent requires connection_id and agent → hub requires a listener and authentication. Only the WebSocket carrier is supported. For remove_fields, verify the assignment is absent and observe the runtime default or required-field validation rather than treating an empty string as deletion.

For split definitions, inspect sources and field_sources and review all changed files in one plan. A duplicate field is a conflict, not an include override; older runtimes reject split Relay IDs entirely and need the reviewed runtime upgrade workflow. The editor preserves the file boundaries, comments and unrelated values. Retain the original plan for exact restoration of every changed file, including when the managed runtime has stopped. Restoration checks the complete current source revision before writing; concurrent edits in any included source require inspection. Multi-file publication compensates ordinary failures but is not crash recovery. Do not overwrite concurrent changes or reuse a restored plan for another apply.

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
