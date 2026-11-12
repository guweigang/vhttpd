# TOML pipeline applications

Use this profile for an application defined by configuration. Read `context_get`, `guidance_get(project)` and the selected runtime's `schema_get` entries for the listener, adapter and any transforms or policies.

In a stopped workspace, choose the `pipeline` application template. Its `component.toml` owns a business HTTP listener, a `fixed-response` adapter and a pipeline whose exact match is `/healthz`. The adapter returns HTTP 200 with `pipeline-ok`. A path outside that match returns 404.

For existing configuration, retain the component identity in `app.json` and its declared entry. Use `application_install_prepare` with the workspace-relative component path to preview installation. After installation, bind the component in Desktop.

Read every changed file's revision. Prepare, validate and apply changes while the environment is stopped. After `runtime_start` over Relay, poll `runtime_status` until `readiness` is `ready`. Stop polling on a failed or stopped phase. Verify both a matching and an unmatched path through `application_request`.

Application-owned configuration is released with `application_release_prepare` and its apply and rollback tools. Shared environment pipeline exact paths use `shared_config_diff`, `shared_config_preflight`, `shared_config_apply` and `shared_config_rollback`. These operations restart the whole target environment. Read the preview before confirming in Desktop.
