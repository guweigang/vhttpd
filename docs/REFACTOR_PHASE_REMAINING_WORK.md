---
title: Refactor Phase Remaining Work
tags:
  - refactor
  - runtime
  - v2-config
  - validation
status: draft
updated: 2026-07-04
---
# Refactor Phase Remaining Work

This document records the remaining acceptance work after the v2 runtime/config refactor. The code refactor stages are treated as complete when the automated test matrix is green. The whole refactor goal is complete only after the product-level checklist below passes.

## Current Status

- Stage 7 runtime isolation and module closure: code-complete.
- Automated test matrix: green as of 2026-07-01.
- Latest acceptance verification: `bash tests/e2e/config_acceptance_test.sh` passed on 2026-07-04 with 183 config-acceptance checks green; `VHTTPD_E2E_DB_LIVE=1 VHTTPD_E2E_DB_PASSWORD=... VHTTPD_E2E_WP_ROOT=/Users/guweigang/wwwroot/wordpress bash tests/e2e/config_acceptance_test.sh` passed on 2026-07-04 with 204 checks green against local MySQL plus the installed WordPress/WooCommerce site.
- Product-level acceptance: in progress.
- Completed acceptance slice: automated config smoke now covers V1 basic compatibility, V2 simple pipeline dispatch, V2 missing-reference diagnostics, multi-site listener/pipeline routing with admin plan visibility, WordPress V2 worker/static/security/REST OPTIONS routing with response-cache cookie behavior, HTTP protocol transform dispatch through native/vjsx implementations with transformer snapshots, hot replacement, and replacement event visibility, relay happy path/reconnect/fail-fast behavior with runtime/admin visibility, V2 WebSocket dispatch startup/probe/admin/log visibility, installed WordPress wp-admin/admin-bar static asset routing, V2 provider runtime/admin visibility for Codex and Feishu, provider-action dispatch through configurable vjsx provider runtime with hot replacement, provider instance add/update through admin APIs, MCP runtime/admin snapshots, DB/cache runtime snapshots on independent admin port plus data-plane admin modes, live MySQL query smoke, real PHP cache socket operations, upload-completed and generic event pipeline dispatch, PHP worker stream-dispatch SSE, and controlled worker busy/queue/full/timeout/release-cleanup visibility.

Validated automated commands:

- `make build`
- `make test`
- `make test-inproc`
- `make test-codexbot-fast`
- `make test-codexbot-lifecycle`
- `make test-e2e`
- `bash tests/e2e/config_acceptance_test.sh`

## Completed Baseline

The following refactor tracks are covered by code changes and automated tests:

- Baseline and v1 compatibility coverage.
- V2 config model: resources, adapters, transforms, pipelines, listener binding, and runtime-plan projection.
- Pipeline/route/adapter projection and capability diagnostics.
- Relay descriptors, sessions, channels, carriers, agents, inbound/outbound delivery, and wire behavior.
- Native and vjsx transformer runtime paths.
- Provider registry, provider bootstrap, command executor, worker backend, Codex runtime, Feishu runtime, and in-proc vjsx runtime.
- Runtime isolation: module-owned constructors, runtime hubs, split runtime replacement, and domain-specific startup runtime.

## Unified Remaining Acceptance Checklist

Run this checklist before declaring the whole refactor goal complete.

Progress markers:

- Completed: the acceptance item is covered by automated smoke and the remaining checks are either done or tracked elsewhere.
- Partial: the first automated slice passes, but listed checks still remain.
- Pending: no product-level smoke has passed yet.

### 1. V1 Compatibility Smoke

Purpose: prove compatibility paths still work while v2 adoption is rolling out.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts a generated v1 config, serves a vjsx request, and verifies `server.started`. Compatibility-only fallback ownership is documented below.

Checks:

- Start one legacy/v1 config successfully.
- Serve a basic HTTP request.
- Confirm compatibility-only fallbacks are documented with owner and removal condition.

Compatibility fallback owner and removal condition:

- Owner: `src/config/v1_plan_compat.v` owns legacy-to-V2 projection for `[worker]`, `[executor]`, `[[routes]]`, legacy assets, DB/cache, and upload-completed compatibility.
- Boundary: runtime modules consume the compiled `RuntimePlan`; they must not branch on legacy config shape.
- Removal condition: remove the fallback only after shipped examples and downstream deployments have migrated to `version = 2` resources/adapters/transforms/pipelines, and after a release note names the last supported legacy config version.

Related stages: Stage 1, Stage 2.

Acceptance signal:

- `src/config/v1_plan_compat_test.v` passes.
- One legacy config starts and serves a request.

### 2. V2 Simple Site Smoke

Purpose: prove the new config model works without compatibility fallback.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts a generated v2 config and verifies basic pipeline dispatch plus trace-id propagation. It also verifies missing adapter, transform, listener, and resource references fail startup with a non-zero CLI exit and emit clear `runtime_plan_unresolved_ref` diagnostics. `src/config/runtime_plan_loader_test.v` also scans repository V2 example TOML files, rejects legacy v1-only sections such as `[worker]`, `[executor]`, and `[[routes]]`, and verifies the examples load without compatibility fallback.

Checks:

- Start one simple v2 TOML config.
- Confirm resources, adapters, transforms, pipelines, and listener binding load as expected.
- Confirm diagnostics are clear when a pipeline references a missing adapter, transform, resource, or listener.
- Audit example config style so it does not mix v1/v2 concepts like a patch stack.

Related stages: Stage 2, Stage 3.

Acceptance signal:

- Real v2 TOML loads without compatibility fallback.
- Basic HTTP pipeline dispatch succeeds.
- Missing-reference diagnostics identify the unresolved resource ref.
- Admin/runtime diagnostics expose the selected pipeline and resources.

### 3. WordPress V2 Smoke

Purpose: validate the real showcase workload against v2 config and runtime boundaries.

Progress: Partial. `tests/e2e/config_acceptance_test.sh` now starts a generated WordPress-shaped V2 config against a temporary WordPress root, runs a real PHP worker through `examples/wordpress/app.php`, verifies `/meta` framework metadata and missing-`wp-config.php` install detection without DB, serves `wp-content` and `wp-includes` assets through static pipelines, applies asset cache-control, denies core PHP files through the security pipeline, verifies REST OPTIONS/CORS response headers through a fixed-response pipeline, verifies the front page reaches the worker redirect path, checks admin plan visibility for WordPress pipelines, preserves trace IDs for worker/static requests, and validates response-cache behavior for anonymous requests, `wordpress_test_cookie` ignore, and `wordpress_logged_in_*` bypass. Installed WordPress/WooCommerce browser flows still need manual or deeper environment-backed validation, but the live smoke now verifies forwarded HTTPS scheme handling for worker-generated URLs, canonical redirects for home/cart/checkout/REST, static routing for core, wp-admin, and admin-bar assets, and cache bypass headers/event visibility for WooCommerce cart cookies, and set-cookie cache bypass headers for installed worker responses.

Checks:

- Start the WordPress-shaped example using v2 config without requiring a real database.
- Verify HTTPS scheme in PHP/worker-generated URLs.
- Verify logged-in admin bar assets, static assets, cart, checkout, and REST API loopback.
- Verify response cache headers and logged-in cookie bypass behavior.
- Confirm WordPress-specific behavior stays in config or `VHttpd\WordPress`, not generic runtime modules.

Related stages: Stage 2, Stage 3, Stage 6, Stage 7.

Acceptance signal:

- Generated WordPress V2 smoke passes, and installed WordPress pages/admin flows work under v2 config.
- No generic vhttpd runtime module contains WordPress-specific compatibility logic.

### 4. Multi-Site Smoke

Purpose: prove pipeline is the site-level composition unit and multiple sites bind correctly.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts one vhttpd process with two HTTP listeners, verifies each listener selects its own pipeline, checks `x-vhttpd-pipeline`, confirms per-site trace IDs appear in the event log, verifies the admin plan exposes the expected pipeline/listener state, and verifies `/admin/runtime` on the independent admin port aggregates listener plus pipeline route summaries for both listener-bound apps.

Checks:

- Start one vhttpd process with two listeners or site bindings.
- Verify each site resolves the correct pipeline/resources.
- Verify trace IDs identify the correct listener/site path.
- Verify admin/runtime snapshots expose site/listener/pipeline state clearly.

Related stages: Stage 2, Stage 3, Stage 7.

Acceptance signal:

- Two sites serve different configured behavior from one process.
- Logs/events make the selected listener, site, and pipeline clear.

### 5. Relay Smoke

Purpose: prove configured relay works in a real two-process topology.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts public relay and local agent processes, verifies a request reaches the local agent and returns, checks public relay runtime descriptor/carrier visibility, checks the agent admin plan exposes the relay pipeline, verifies disconnected-agent requests fail fast with 503 plus `relay_carrier_unavailable` response headers while preserving trace/error observations, restarts the agent, and verifies public relay delivery recovers after reconnect.

Checks:

- Start public relay and local server processes.
- Verify a request flows through relay and returns to the caller.
- Stop/restart the local server and verify reconnect behavior.
- Verify backpressure behavior under interrupted or slow local server.
- Verify relay delivery includes trace IDs and useful admin snapshots.

Related stages: Stage 3, Stage 4.

Acceptance signal:

- A request reaches the local server through relay and returns.
- Relay admin/runtime snapshots show carrier, agent, channel, and session state correctly.

### 6. Protocol Conversion Smoke

Purpose: prove transforms are configurable protocol/runtime units, not hardcoded paths.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now validates the same HTTP `/convert` ingress through native and vjsx transform implementations by TOML-only selection. It also verifies vjsx transform failure status, `x-vhttpd-error-class`, thrown-handler failure reporting as `502`, thrown-handler `transport_error` headers, trace-id propagation for both failed and thrown transforms, admin transformer snapshots, event-log handler failure observations, admin plan visibility for transform pipelines, and replacement observability through `runtime.plan.replaced` plus post-replacement trace IDs. The smoke also starts a V2 WebSocket listener/pipeline using `websocket_dispatch`, verifies a Node WebSocket probe receives `sync` then `pong`, confirms `/admin/runtime/websockets` exposes the closed connection state, and checks service-log trace/listener completion visibility. Relay ingress is covered by the relay smoke; timeout/invalid-output failure cases remain tracked as broader protocol coverage, not blockers for the current HTTP/WebSocket conversion smoke.

Checks:

- Configure HTTP/WebSocket or relay ingress through a transform pipeline.
- Run once with native transform and once with vjsx transform.
- Switch transform implementation by TOML only.
- Validate failure reporting for transform errors, timeouts, and invalid output shape.

Related stages: Stage 3, Stage 5.

Acceptance signal:

- Same ingress request succeeds with native transform and vjsx transform by config-only switch.
- Failed transform emits actionable error and keeps trace/request IDs.

### 7. Event and Upload Completion Pipeline Smoke

Purpose: prove non-request/response ingress paths use the same pipeline model.

Progress: Completed for the current smoke scope. `tests/e2e/config_acceptance_test.sh` now starts a V2 upload route with `adapter:upload`, routes `upload.completed` through an event pipeline with a vjsx transform, verifies upload acceptance, verifies `upload.completed.dispatch`, records the transform id, and preserves trace IDs. It also dispatches a generic `inventory.changed` event through `/admin/runtime/events`, selects the configured event pipeline, runs the vjsx transform, records transform metadata, and preserves trace IDs. PHP worker stream-dispatch also has unit coverage and e2e verification through worker `open`/`next`.

Checks:

- Trigger an upload-completed event pipeline.
- Trigger at least one generic event ingress pipeline.
- Confirm the event can dispatch to native/vjsx logic as configured.
- Confirm trace IDs are preserved from event creation through dispatch.

Related stages: Stage 3, Stage 5, Stage 6.

Acceptance signal:

- Event pipeline dispatch succeeds without legacy handler fallback.
- Logs/events show upload/event id, pipeline id, engine/transform id, and trace id.

### 8. Provider and Worker Runtime Smoke

Purpose: prove runtime providers and worker dispatch behave under real startup/load conditions.

Progress: Partial. `tests/e2e/config_acceptance_test.sh` now starts a V2 config with configured Codex and Feishu adapters, verifies provider registration through `/admin/providers` and `/admin/providers/specs`, verifies the Codex runtime snapshot through `/admin/runtime/codex`, verifies the Feishu runtime snapshot through `/admin/runtime/feishu` on both independent admin port and data-plane admin modes, verifies provider runtime visibility through `/admin/providers/runtimes`, confirms both provider pipelines appear in `/admin/runtime/plan`, upserts and updates a dynamic Codex provider instance through `/admin/runtime/provider-instances`, verifies the instance snapshot, confirms the snapshot reflects desired-state updates, and preserves trace IDs for provider baseline/upsert/update requests. It also verifies provider-action dispatch through a configured vjsx provider runtime, confirms the configured capability reaches the runtime, exposes provider runtime entities in `/admin/runtime/plan`, previews provider runtime reloads, applies lightweight runtime-plan replacement, verifies provider-action trace events, and verifies the replaced provider runtime handles subsequent requests. The same script also starts MCP-enabled, DB-enabled, and cache-enabled configs; verifies `/admin/runtime/mcp` exposes max sessions, pending-message limit, session TTL, invalid sampling-policy normalization, and data-plane admin visibility; verifies `/admin/runtime/plan` exposes MCP sampling-policy diagnostics; verifies MCP HTTP DELETE without `Mcp-Session-Id` returns the `missing_session_id` error class after allowed-origin validation; verifies `/admin/runtime/db` exposes enabled state, socket, driver, and idle ping on both independent admin port and data-plane admin modes without requiring a live database query; verifies `/admin/runtime/cache` exposes enabled/started state, socket, and key count on both admin modes; and runs the PHP cache client through real `ping/set/get/exists/keys/delete` operations against the vhttpd cache socket. It also starts a real PHP worker pool, verifies a baseline request, observes an in-flight busy worker through `/admin/workers`, verifies queue capacity/timeout in `/admin/runtime`, and confirms trace-id preservation for the busy request. `src/worker_backend_runtime_test.v` now covers the deterministic queued-selector timeout path, including wait/timeout counters and queue-depth cleanup. A dedicated controlled-worker fixture now covers true-concurrent queue success, queue-full rejection, queue-timeout response, error-class headers, timeout counters, release-time queue-depth cleanup, served-request visibility, and trace/event-log observations. Live DB query smoke is available behind `VHTTPD_E2E_DB_LIVE=1` and passed against local MySQL on 2026-07-04, verifying the DB socket serves a real query and `/admin/runtime/db` records query count plus trace ID.

Checks:

- Run real provider startup with configured Codex, Feishu, and DB/cache where available.
- Verify provider instance add/update paths through admin/runtime APIs.
- Confirm worker queue behavior under busy workers and request bursts.
- Confirm no request is dispatched to a busy worker incorrectly.

Related stages: Stage 6, Stage 7.

Acceptance signal:

- Provider instances appear in admin snapshots with correct source/static/dynamic state.
- Busy workers queue, timeout, or reject according to configuration.

### 9. Observability Smoke

Purpose: prove the runtime is inspectable as a generic gateway.

Progress: Partial. The automated config smoke checks trace-id propagation across V2 HTTP dispatch, multi-site listener/pipeline routing, WordPress worker/static requests, native/vjsx transform dispatch, relay, WebSocket dispatch service logs, provider runtime baseline dispatch, provider-action dispatch/replacement, provider instance admin upsert/update, upload-completed event dispatch, PHP worker stream dispatch, and worker busy-state handling. It also verifies admin plan visibility for multi-site/protocol/relay/provider/WordPress pipelines, admin WebSocket closed-connection state, admin transformer snapshots for native/vjsx transforms, relay runtime descriptor/carrier visibility, provider runtime snapshots for Codex and Feishu, DB/cache runtime snapshots on both independent admin port and data-plane admin modes, provider instance snapshots and update trace events, MCP missing-session DELETE error-class headers, upload event transform dispatch metadata, response-cache store/hit/bypass observations with bypass reasons including installed set-cookie bypasses, cache socket operation counters, and worker runtime queue/busy snapshots. Controlled worker queue-full and queue-timeout failures are now observable through error-class headers, admin runtime counters, trace IDs, and event-log entries. Remaining broader coverage is tied to any deeper installed WordPress/WooCommerce browser flows and protocol/relay backpressure cases outside the current HTTP/WebSocket-focused smoke.

Checks:

- For every smoke scenario above, confirm logs/events include `trace_id`.
- Confirm request, provider, pipeline, listener/site, relay, worker, and transform identifiers are present where relevant.
- Confirm admin snapshots expose runtime state without source-code knowledge.

Related stages: all stages.

Acceptance signal:

- A user can follow one request/event from ingress to egress using trace id and runtime snapshots.

### 10. Boundary and Documentation Cleanup

Purpose: prevent the refactor from regressing into App-level or product-specific coupling.

Progress: Completed for the current refactor scope. `src/refactor_contract_test.v` passes and guards the key boundaries: generic runtime builders do not special-case WordPress, `app_runtime_builder.v` constructs runtime hubs through module-owned constructors, startup is split by domain runtime, runtime-plan replacement uses projection builders, and legacy upload/provider fallbacks are compatibility-only. Configuration concepts are documented in `docs/CONFIGURATION_MODEL_V2.md` and `docs/PROTOCOL_PIPELINE_RELAY_ARCHITECTURE.md`, including resources, listeners, adapters, transforms, relays, policies, pipelines, multi-site listener binding, and the rule that native V and VJSX transforms are interchangeable implementations behind the same pipeline boundary.

Checks:

- Keep opportunistic cleanup only when it creates a real module boundary; avoid thin wrappers that merely rename `app.providers.x` access.
- Review test fixtures for repeated hand-built internals, but do not block acceptance on fixture cleanup.
- Keep guardrails focused on behavior and ownership, not naming preferences.
- Tighten docs so users understand resources vs pipeline vs listener/site binding.

Related stages: Stage 2, Stage 7.

Acceptance signal:

- `src/refactor_contract_test.v` passes.
- Production code paths use runtime builders/hubs for construction and plan projection.
- No new catch-all App hook or mixed runtime file replaces split modules.
- Config concept docs describe entity resources separately from the site-level pipeline composition.

## Definition of Done

The refactor is fully done only when:

- The automated test matrix is green.
- The unified acceptance checklist above passes.
- Example configs are updated to idiomatic v2 concepts.
- Compatibility-only fallbacks are documented with owner and removal condition.
- No product-specific logic leaks into generic vhttpd runtime modules except through configuration or product-specific package code.
