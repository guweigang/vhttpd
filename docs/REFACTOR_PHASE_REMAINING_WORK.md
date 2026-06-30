---
title: Refactor Phase Remaining Work
tags:
  - refactor
  - runtime
  - v2-config
  - validation
status: draft
updated: 2026-06-30
---
# Refactor Phase Remaining Work

This document records the remaining acceptance work after the v2 runtime/config refactor. The code refactor stages are treated as complete when the automated test matrix is green. The whole refactor goal is complete only after the product-level checklist below passes.

## Current Status

- Stage 7 runtime isolation and module closure: code-complete.
- Automated test matrix: green as of 2026-06-30.
- Product-level acceptance: in progress.
- Completed acceptance slice: automated config smoke now covers V1 basic compatibility, V2 simple pipeline dispatch, relay happy path, and PHP worker stream-dispatch SSE.

Validated automated commands:

- `make build`
- `make test`
- `make test-inproc`
- `make test-codexbot-fast`
- `make test-codexbot-lifecycle`
- `make test-e2e`

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

Progress: Partial. `tests/e2e/config_acceptance_test.sh` now starts a generated v1 config, serves a vjsx request, and verifies `server.started`. Compatibility-only fallback documentation is still pending.

Checks:

- Start one legacy/v1 config successfully.
- Serve a basic HTTP request.
- Confirm compatibility-only fallbacks are documented with owner and removal condition.

Related stages: Stage 1, Stage 2.

Acceptance signal:

- `src/config/v1_plan_compat_test.v` passes.
- One legacy config starts and serves a request.

### 2. V2 Simple Site Smoke

Purpose: prove the new config model works without compatibility fallback.

Progress: Partial. `tests/e2e/config_acceptance_test.sh` now starts a generated v2 config and verifies basic pipeline dispatch plus trace-id propagation. Missing-reference diagnostics and example-style audit are still pending.

Checks:

- Start one simple v2 TOML config.
- Confirm resources, adapters, transforms, pipelines, and listener binding load as expected.
- Confirm diagnostics are clear when a pipeline references a missing adapter, transform, resource, or listener.
- Audit example config style so it does not mix v1/v2 concepts like a patch stack.

Related stages: Stage 2, Stage 3.

Acceptance signal:

- Real v2 TOML loads without compatibility fallback.
- Basic HTTP pipeline dispatch succeeds.
- Admin/runtime diagnostics expose the selected pipeline and resources.

### 3. WordPress V2 Smoke

Purpose: validate the real showcase workload against v2 config and runtime boundaries.

Progress: Pending.

Checks:

- Start the WordPress example using v2 config.
- Verify HTTPS scheme in PHP/worker-generated URLs.
- Verify logged-in admin bar assets, static assets, cart, checkout, and REST API loopback.
- Verify response cache headers and logged-in cookie bypass behavior.
- Confirm WordPress-specific behavior stays in config or `VHttpd\WordPress`, not generic runtime modules.

Related stages: Stage 2, Stage 3, Stage 6, Stage 7.

Acceptance signal:

- WordPress pages and admin flows work under v2 config.
- No generic vhttpd runtime module contains WordPress-specific compatibility logic.

### 4. Multi-Site Smoke

Purpose: prove pipeline is the site-level composition unit and multiple sites bind correctly.

Progress: Pending.

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

Progress: Partial. `tests/e2e/config_acceptance_test.sh` now starts public relay and local agent processes, then verifies a request reaches the local agent and returns. Reconnect, backpressure, and admin snapshot checks are still pending.

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

Progress: Pending.

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

Progress: Partial. PHP worker stream-dispatch now has unit coverage and `tests/e2e/config_acceptance_test.sh` verifies SSE through worker `open`/`next`. Upload-completed and generic event ingress smoke are still pending.

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

Progress: Pending.

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

Progress: Pending.

Checks:

- For every smoke scenario above, confirm logs/events include `trace_id`.
- Confirm request, provider, pipeline, listener/site, relay, worker, and transform identifiers are present where relevant.
- Confirm admin snapshots expose runtime state without source-code knowledge.

Related stages: all stages.

Acceptance signal:

- A user can follow one request/event from ingress to egress using trace id and runtime snapshots.

### 10. Boundary and Documentation Cleanup

Purpose: prevent the refactor from regressing into App-level or product-specific coupling.

Progress: Pending.

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

## Definition of Done

The refactor is fully done only when:

- The automated test matrix is green.
- The unified acceptance checklist above passes.
- Example configs are updated to idiomatic v2 concepts.
- Compatibility-only fallbacks are documented with owner and removal condition.
- No product-specific logic leaks into generic vhttpd runtime modules except through configuration or product-specific package code.
