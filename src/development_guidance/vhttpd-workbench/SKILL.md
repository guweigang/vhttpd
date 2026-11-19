---
name: vhttpd-workbench
description: Develop, deploy, and troubleshoot vhttpd applications and environments. Use for Desktop MCP workflows involving vjsx, TOML pipelines, application releases, runtime packages, Relay, or protocol and authentication probes.
---
# vhttpd Workbench

Start with `context_get` to confirm the project binding, target runtime and `binding_revision`. Use `capabilities_list` to check the tools this session exposes. Reread context after a binding change before using old revisions or plans.

Read only the reference for the current job:

- [Develop](references/develop.md): bind an existing source directory, create or edit an application, validate, start and verify it. Over MCP without filesystem access, use `guidance_get` topic `workflow`.
- [Deploy](references/deploy.md): manage hosts and runtime packages, publish or roll back releases, and configure Relay. Over MCP, use topic `deploy`.
- [Debug](references/debug.md): diagnose runtime and request failures, verify protocol and authentication behavior, and recover from changes. Over MCP, use topic `debug`.

For runtime-specific contracts, use `schema_get` and `guidance_get` topic `vjsx` from the selected runtime. Read topic `project` for project instructions.

Keep credentials and private key material in Desktop or the configured environment. Check the target and impact before applying changes. Retain the recovery record until the expected business response is verified. If a mutation times out, inspect its status before retrying.