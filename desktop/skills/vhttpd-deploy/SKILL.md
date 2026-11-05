---
name: vhttpd-deploy
description: Use Desktop Workbench to prepare, review and verify remote vhttpd application releases and runtime upgrades. Use for target discovery, component preflight, deployment status and recovery checks.
---
# Deploy with vhttpd Desktop

Use the local management MCP. Start with `context_get` and keep the returned `binding_revision` for the rest of the workflow. Call `targets_list` and select a target by its ID. Call `target_status` to check the registered environment, runtime version, readiness, application inventory and known operations. Use `target_applications_list` for live installation IDs and versions and `target_history_list` for known release and upgrade records. `target_diagnostics_get` and `target_logs_query` provide runtime and application evidence after publication. If the host or runtime is disconnected, connect through Desktop. Use the Desktop trust prompt for a first connection.

## Release an application

For TOML pipeline, WeChat cloud compatibility and Codex Bot, bind the installed component and confirm `app.json` and `component.toml` describe the same source. Choose a test request from the template guide. Inspect the preview for all runtime source and library files. Configure target resources and credentials through Desktop. Check both the business response and the operation record after release and rollback. A first install has no previous artifact. To verify rollback, publish a baseline, publish a second revision to the same installation ID, then roll back the second operation.

1. Call `application_release_prepare` with the target ID and component slot. Omit `installation_id` for a new installation. For an update, use the existing installation ID. Review the version, file actions and restart scope.
2. Call `application_release_apply` with the returned plan ID and confirm in Desktop. Poll `operation_get` with the operation ID. After `completed`, verify the target and make the agreed business request.
3. To roll back, prepare with `rollback_from` set to the current completed release operation ID and omit `installation_id`. Review the recovered version and call `application_release_rollback` with that plan. The previous artifact must still be retained. Verify the business response again.

## Change shared remote routing

Use the local management MCP and confirm the target ID and binding revision. For an existing shared HTTP pipeline with a single-line `match.paths` assignment, call `shared_config_diff` with the pipeline ID and the desired exact paths. Review the relative configuration source and the before and after paths.

1. Call `shared_config_preflight` with the plan ID to compile the whole proposed environment.
2. Call `shared_config_apply` with the same plan ID and confirm the restart in Desktop. Verify both the old and new paths at the business listener.
3. To restore the baseline, call `shared_config_rollback` with that plan ID and confirm in Desktop. Verify both paths again. Keep the same Desktop management session and binding until verification is complete.

If the tool reports a pending restart, check the target state before calling it again with the same plan ID. If the configuration changed since preview, inspect it and prepare a new diff.

## Upgrade a runtime

Use `runtime_package_get` to check the local selection before reproducing a target issue. Use `target_status` for the remote package inventory and version. After an upgrade, verify business behavior and use `runtime_diagnostics_get` to inspect the running local reproduction if it differs from the target.

Use `target_status` to choose an installed package ID. Call `runtime_upgrade_prepare` with `target_runtime_id`, review the version and affected applications, then use `runtime_upgrade_apply` and confirm in Desktop. Track the operation with `operation_get` and verify the active package and business behavior.

To return to the previous package, call `runtime_upgrade_prepare` with the current completed upgrade ID in `rollback_from`, then call `runtime_upgrade_rollback` with the returned plan and confirm in Desktop.

## Recover after a failure

For `rolling_back`, keep querying the operation until it reaches a terminal phase. For `rolled_back`, verify that the previous version is serving. For `rollback_failed` or an uncertain submission, retain the operation ID and inspect it before another write. Reconnect the original host in Desktop if needed. Keep credentials in Desktop.
