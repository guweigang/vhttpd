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

This document records the remaining work after the v2 runtime/config refactor. The code refactor stages are treated as complete when the unit/integration test matrix is green, but product-level acceptance still requires real configuration smoke tests.

## Current Status

- Stage 7 runtime isolation and module closure: code-complete.
- Automated test matrix: green as of 2026-06-30.
- Product-level acceptance: not complete until the real scenario checks below pass.

Validated automated commands:

- `make build`
- `make test`
- `make test-inproc`
- `make test-codexbot-fast`
- `make test-codexbot-lifecycle`
- `make test-e2e`

## Stage 1: Baseline and Compatibility

Completed:

- Baseline runtime behavior was captured through existing unit and integration tests.
- Legacy v1 compatibility paths remain covered by config tests.

Remaining:

- Keep a small v1 compatibility smoke fixture in the final acceptance run.
- Document any compatibility-only fallbacks that should be removed after v2 adoption is complete.

Acceptance signal:

- `src/config/v1_plan_compat_test.v` passes.
- One legacy config starts successfully and serves a basic request.

## Stage 2: Configuration Model V2

Completed:

- V2 concepts are represented in config/runtime-plan tests: resources, adapters, transforms, pipelines, listener binding, and compatibility projection.
- `make test` covers `src/config` and `src/runtime_plan` modules.

Remaining:

- Run real TOML fixtures for at least one simple site, one multi-site setup, and one relay/transform setup.
- Tighten documentation so users understand which objects are resources and why pipeline is the site-level composition unit.
- Audit examples to avoid patch-like mixed v1/v2 config style.

Acceptance signal:

- Real v2 TOML configs load without compatibility fallback.
- Diagnostics are clear when a pipeline references a missing adapter, transform, resource, or listener.

## Stage 3: Resource and Pipeline Projection

Completed:

- Pipeline projection, route projection, adapter projection, and capability diagnostics are covered by tests.
- Runtime builders consume runtime plans rather than ad hoc config fragments.

Remaining:

- Product smoke for HTTP pipeline dispatch.
- Product smoke for event/upload-completed pipeline dispatch.
- Product smoke for relay response pipeline dispatch.
- Confirm trace IDs are preserved through every pipeline boundary.

Acceptance signal:

- One request can be traced from ingress to transform to egress in logs/events.
- Cache, worker, relay, and transformer pipeline paths expose expected runtime diagnostics.

## Stage 4: Relay and Protocol Runtime

Completed:

- Relay descriptors, sessions, channels, carriers, agents, inbound/outbound delivery, and wire behavior are covered by tests.
- WebSocket relay runtime tests pass.

Remaining:

- Run a real two-process relay scenario: public relay process plus local server process.
- Verify reconnect behavior and backpressure behavior under a stopped/restarted local server.
- Verify relay delivery with trace IDs and admin snapshots.

Acceptance signal:

- A request reaches the local server through relay and returns to the caller.
- Relay admin/runtime snapshots show carrier, agent, channel, and session state correctly.

## Stage 5: Transformer Runtime

Completed:

- Native and vjsx transformer runtime paths are covered by transformer and conformance tests.
- Vjsx executor and host API tests pass.

Remaining:

- Run a real protocol-conversion pipeline using one native transform and one vjsx transform.
- Confirm transforms can be swapped by TOML without code changes.
- Validate failure reporting for transform errors, timeouts, and invalid output shape.

Acceptance signal:

- Same ingress request succeeds with native transform and with vjsx transform by config-only switch.
- Failed transform emits actionable error and keeps trace/request IDs.

## Stage 6: Provider, Worker, and Command Runtime

Completed:

- Provider registry, provider bootstrap, command executor, worker backend, Codex runtime, Feishu runtime, and in-proc vjsx tests pass.
- Codexbot fast and lifecycle tests pass.

Remaining:

- Run real provider startup with configured Codex, Feishu, and DB/cache where available.
- Verify provider instance add/update paths through admin/runtime APIs.
- Confirm worker queue behavior under busy workers and request bursts.

Acceptance signal:

- Provider instances appear in admin snapshots with correct source/static/dynamic state.
- Busy workers queue or reject according to configuration; no request is dispatched to a busy worker incorrectly.

## Stage 7: Runtime Isolation and Module Closure

Completed:

- App runtime construction moved toward module-owned constructors and runtime hubs.
- Runtime replacement was split into state, preview, event, action, and execution files.
- Startup runtime was split by domain: transport, assets, provider, and control plane.
- Contract tests guard key boundaries.

Remaining:

- Continue opportunistic cleanup only when it creates a real module boundary; avoid thin wrappers that merely rename `app.providers.x` access.
- Review test fixtures for repeated hand-built internals, but do not block acceptance on fixture cleanup.
- Keep new guardrails focused on behavior and ownership, not naming preferences.

Acceptance signal:

- `src/refactor_contract_test.v` passes.
- Production code paths use runtime builders/hubs for construction and plan projection.
- No new catch-all App hook or mixed runtime file replaces the split modules.

## Final Product-Level Acceptance Checklist

Run these before declaring the whole refactor goal complete:

1. WordPress v2 config smoke
   - Start the WordPress example using the v2 config.
   - Verify HTTPS scheme in PHP/worker-generated URLs.
   - Verify logged-in admin bar assets, cart, checkout, REST API loopback, and static assets.
   - Verify response cache headers and logged-in cookie bypass behavior.

2. Multi-site smoke
   - Start one vhttpd process with two listeners or site bindings.
   - Verify each site resolves the correct pipeline/resources.
   - Verify trace IDs identify the correct listener/site path.

3. Relay smoke
   - Start public relay and local server processes.
   - Verify a request flows through relay and returns.
   - Stop/restart the local server and verify reconnect behavior.

4. Protocol conversion smoke
   - Configure HTTP/WebSocket or relay ingress through a transform pipeline.
   - Run once with native transform and once with vjsx transform.
   - Verify config-only switching.

5. Observability smoke
   - For each scenario above, confirm logs/events include `trace_id` and request/provider/pipeline identifiers.
   - Confirm admin snapshots expose runtime state without requiring source-code knowledge.

## Definition of Done

The refactor is fully done only when:

- The automated test matrix is green.
- The five product-level smoke scenarios pass.
- The example configs are updated to idiomatic v2 concepts.
- Any compatibility-only fallback is documented with an owner and removal condition.
- No WordPress-specific logic leaks into generic vhttpd runtime modules except through configuration or `VHttpd\WordPress` package code.
