# Protocol Pipeline and Relay Implementation Plan

Status: implementation design

This document turns the target architecture in `PROTOCOL_PIPELINE_RELAY_ARCHITECTURE.md` and `CONFIGURATION_MODEL_V2.md` into an incremental engineering plan for the current repository.

The implementation is intentionally evolutionary:

- preserve current behavior while moving ownership
- compile legacy configuration into the new model
- establish one HTTP vertical slice before migrating session protocols
- reuse the current dispatch, executor, VJSX lane, worker pool, WebSocket hub, and Paseo work
- keep every phase independently testable and committable

## Decisions

### Evolve `src/dispatch` into the protocol kernel

The repository already has `src/dispatch`, but it currently aliases types from `executor`. The dependency direction will be inverted:

```text
config -> plan
dispatch -> plan
executor -> dispatch contracts + plan
adapters -> dispatch contracts
relay -> dispatch contracts
main/App -> assembled registries and protocol runtimes
```

The `dispatch` module must not import:

- `executor`
- `veb`
- WordPress, Feishu, Paseo, or OpenAI packages
- concrete DB/cache implementations
- network connection types

It may import standard value types and pure transport-independent helpers.

Resolved configuration belongs to a separate pure `plan` module. This prevents `dispatch` from becoming the next global owner of listeners, engines, DB/cache resources, and relay configuration.

### Keep network ownership outside transforms

Ingress runtimes own accepted client connections. Egress and relay runtimes own their outbound connections and pools. A transformer receives Exchange data and runtime service handles, never a TCP, TLS, WebSocket, or Unix socket object.

### Make subsystems closed runtime owners

The refactor does not stop at moving functions out of `main.v`. State and lifecycle move with behavior. Each subsystem exposes a narrow public contract and keeps its locks, queues, counters, maps, and implementation helpers private.

The target top-level ownership is:

```text
App
  -> DataPlaneRuntime
       -> PipelineRuntime
       -> AdapterRegistry
       -> TransformerRegistry
       -> RelayRuntime
  -> ControlPlaneRuntime
  -> ProcessLifecycle
```

DB, cache, engine, provider, WebSocket, stream, and MCP runtimes are owned by the registry/runtime that manages their lifecycle. They are not flattened back into `App`.

An aggregate struct is not automatically a module boundary. A `Hub` that only stores another module's maps and locks while behavior remains on `App` is still global state under a different name.

### Compile configuration once

Both V1 and V2 configuration produce one `plan.RuntimePlan`. Runtime assembly consumes only this plan.

```text
V1 TOML -> V1 decode -> compatibility compiler --+
                                                +-> RuntimePlan validation -> runtime assembly
V2 TOML -> strict V2 decode --------------------+
```

No request path may interpret legacy config fields.

### Native V and VJSX use one transformer contract

Native V and VJSX are interchangeable transformer backends. A pipeline references a transform ID, not a language or executor.

Initial switching is configuration-driven at startup. Runtime hot switching is deferred until immutable plan replacement and externalized state are complete.

### Protocol conversion is explicit

The pipeline compiler does not assume that HTTP, MCP, streams, and WebSocket messages are automatically convertible. A bridge transform must declare the conversion.

## Proposed Core Types

The exact V syntax may adjust during implementation, but ownership and semantics are fixed.

### Exchange identity

```v
module dispatch

pub struct ExchangeIdentity {
pub:
    id         string
    request_id string
    trace_id   string
    parent_id  string
}
```

Identity is created at ingress and never replaced. A fanout child receives a new exchange ID and keeps the parent/trace relationship.

### Exchange kind

```v
pub enum ExchangeKind {
    request
    response
    event
    stream_open
    stream_chunk
    stream_end
    session_open
    session_message
    session_close
    error
}
```

### Exchange payload

Use a V sum type for protocol-neutral payload families:

```v
pub type ExchangePayload = EmptyPayload
    | RequestPayload
    | ResponsePayload
    | EventPayload
    | StreamPayload
    | SessionPayload
    | ErrorPayload
```

Payload structs contain values, not live connections. Protocol-specific details remain in typed fields or namespaced metadata.

The first HTTP vertical slice may adapt the existing `http.Request` at the ingress edge, but `http.Request` must not become part of the final canonical Exchange.

### Exchange

```v
pub struct Exchange {
pub:
    identity       ExchangeIdentity
    kind           ExchangeKind
    ingress        string
    pipeline       string
    created_at_ms  i64
    deadline_at_ms i64
pub mut:
    headers  map[string]string
    metadata map[string]string
    payload  ExchangePayload
}
```

The Exchange is request-scoped. Native pipeline stages mutate it in-process without JSON serialization.

### Capabilities

```v
pub struct Capabilities {
pub:
    request_response bool
    events           bool
    stream_input     bool
    stream_output    bool
    full_duplex      bool
    sessions         bool
    multiplexing     bool
    cancellation     bool
    backpressure     bool
    replay           bool
}
```

Explicit fields are preferred over unvalidated string sets in the first implementation. The config compiler compares ingress, transform, and egress requirements.

### Transform action

```v
pub enum TransformActionKind {
    continue_pipeline
    respond
    forward
    fanout
    reject
    drop
}

pub struct TransformAction {
pub:
    kind       TransformActionKind
    target     string
    targets    []string
    status     int
    error      string
    error_class string
}
```

Transforms mutate the current Exchange and return an action. They do not return a second full Exchange copy.

### Transformer

```v
pub interface Transformer {
    id() string
    capabilities() Capabilities
mut:
    warmup(mut services RuntimeServices) !
    transform(mut services RuntimeServices, mut exchange Exchange) !TransformAction
    close()
}
```

`RuntimeServices` is deliberately smaller than the current `executor.AppFacade`. It initially exposes:

- event emission
- current time/deadline checks
- named state/cache access
- cancellation check
- redacted runtime metadata

DB and provider APIs are added as typed resource capabilities rather than provider-specific methods on a global facade.

The current `executor.AppFacade` is split by consumer capability instead of being extended:

- `WorkerPoolServices`
- `StateServices`
- `EventServices`
- `CommandServices`
- `RuntimeSnapshotServices`

Concrete wrappers may implement several interfaces, but each executor, adapter, or transformer accepts only the smallest interface it needs. Provider-specific methods such as Feishu callbacks must leave the generic executor facade.

### Native transformer registry

```v
pub type NativeTransformerFactory = fn (TransformSpec) !Transformer

pub struct TransformerRegistry {
mut:
    native_factories map[string]NativeTransformerFactory
    instances        map[string]Transformer
}
```

Native handlers are registered by stable names such as `http.rewrite` or `feishu.events`. Application/provider registration occurs outside the dispatch kernel.

### VJSX transformer

`executor.VjsxTransformer` implements `dispatch.Transformer` and delegates execution to the existing VJSX lane runtime.

Required behavior:

- encode Exchange only at the VJSX boundary
- execute on the configured lane/actor queue
- decode and validate one normalized action
- apply returned Exchange patches
- preserve trace ID and deadline
- expose only declared resource capabilities
- classify timeout, queue, script, and contract errors

The existing VJSX HTTP/WebSocket-specific dispatch methods remain as compatibility adapters until their callers migrate.

### Adapter contracts

Ingress protocols do not implement a fake universal socket interface. Their runtimes own protocol context and normalize it directly into Exchange:

```v
pub struct IngressDescriptor {
pub:
    id           string
    capabilities Capabilities
}
```

Examples:

- HTTP/veb runtime converts a request into a request Exchange
- WebSocket runtime converts callbacks into session Exchanges
- MCP runtime converts protocol messages into request/session Exchanges
- relay runtime converts relay frames into Exchanges

All ingress runtimes call the same `PipelineDispatcher.dispatch(mut exchange)` after normalization.

Egress remains a transport-independent delivery contract:

```v

pub interface EgressAdapter {
    id() string
    capabilities() Capabilities
mut:
    deliver(mut services RuntimeServices, exchange Exchange) !DeliveryOutcome
}
```

Ingress network runtimes invoke the pipeline after producing an Exchange. They are not called through a generic socket interface.

`DeliveryOutcome` describes protocol-neutral terminal behavior:

- response
- accepted event
- stream plan
- session plan
- relay delivery
- classified failure

Protocol runtime code renders the outcome to its owned client connection.

### Pipeline plan

```v
pub struct PipelinePlan {
pub:
    id         string
    group      string
    ingress    string
    matcher    MatchPlan
    transforms []string
    egress     string
    policies   []string
    required   Capabilities
}
```

`MatchPlan` owns precompiled path regexes and normalized method/query/header rules. It replaces request-time interpretation of `RuntimeRouteRule`.

For HTTP ingress, `MatchPlan` also supports normalized host matching. The listener runtime resolves TLS/SNI before pipeline dispatch; the pipeline matcher selects the virtual host behavior. `group` is an optional operational label and has no dispatch semantics.

### Runtime plan

```v
module plan

pub struct RuntimePlan {
pub:
    version     int
    server      ServerPlan
    listeners   map[string]ListenerPlan
    control     ControlPlan
    observability ObservabilityPlan
    resources   map[string]ResourcePlan
    engines     map[string]EnginePlan
    adapters    map[string]AdapterPlan
    transforms  map[string]TransformPlan
    policies    map[string]PolicyPlan
    pipelines   []PipelinePlan
    relays      map[string]RelayPlan
    diagnostics []PlanDiagnostic
}
```

Plan structs contain resolved configuration, not running sockets, workers, lanes, or pools.

`plan` is a pure value module. It owns resolved plan/spec types and typed resource references. It does not own runtime state or dispatch behavior.

Pipeline declaration order is preserved in the plan. Runtime assembly builds an ID index and an ordered ingress index; it does not replace the canonical ordered list with a map.

## Pipeline Execution

### Request flow

```text
listener runtime
  -> ingress adapter normalization
  -> pipeline match
  -> policy pre-checks
  -> transform chain
  -> selected egress adapter
  -> delivery outcome
  -> ingress protocol response rendering
```

### Transform loop

For each transform:

1. Check cancellation and deadline.
2. Record queue start when applicable.
3. Invoke native V or VJSX through the common interface.
4. Validate the action against current Exchange kind and capabilities.
5. Emit transition metrics with trace ID.
6. Continue or terminate according to the action.

### Fanout

Fanout is not implemented in the first HTTP slice. The type is reserved, but startup validation rejects it until an explicit aggregation policy is available.

### Streaming

A stream is a sequence of Exchanges sharing identity/session information. Stream payloads are not collected into one body by the pipeline core.

The first stream migration adapts existing `start/chunk/error/end` frames. Backpressure remains owned by stream and relay runtimes.

### Sessions

WebSocket and MCP sessions produce `session_open`, `session_message`, and `session_close` Exchanges. Session registries and live connections remain in their protocol runtimes.

## Configuration Compiler

### Resource references

References use a strict `kind:id` grammar:

- `adapter:wordpress`
- `transform:feishu`
- `resource:db/wordpress`
- `policy:cache/immutable_assets`
- `listener:public`
- `engine:wordpress`
- `relay:edge`
- `terminal:response`

The parser converts strings into typed `ResourceRef` values once. Runtime code does not split reference strings.

### Compile stages

1. Decode TOML according to version.
2. Expand environment expressions and resolve paths.
3. Translate V1 configuration when required.
4. Normalize resource IDs and references.
5. Validate resource-kind schemas.
6. Resolve listener pipeline order.
7. Compile matchers and policies.
8. Resolve adapter/transform/relay references.
9. Validate capabilities and terminal behavior.
10. Produce immutable RuntimePlan and diagnostics.

### V1 compatibility ownership

All legacy meanings move into `config/compat_compile.v`:

- implicit server listener
- site shortcuts
- executor selection
- magic route executors
- upload completion callback syntax
- OpenAI/Feishu top-level mappings

No adapter or pipeline runtime may inspect whether a plan originated from V1.

### Strict V2 behavior

- unknown fields fail decoding
- duplicate IDs fail compilation
- unresolved references fail compilation
- capability mismatch fails compilation
- invalid listener pipeline order fails compilation
- secrets are redacted in diagnostics

## Module and File Plan

### Pure dispatch module

```text
src/dispatch/
    exchange.v
    payload.v
    capability.v
    action.v
    services.v
    transformer.v
    adapter.v
    matcher.v
    pipeline.v
    compiler_validation.v
    error.v
```

Existing `dispatch/context.v` and `dispatch/kernel.v` are migrated or removed after callers use the new contracts.

### Pure plan module

```text
src/plan/
    resource_ref.v
    server.v
    listener.v
    control.v
    observability.v
    resource.v
    engine.v
    adapter.v
    transform.v
    policy.v
    pipeline.v
    relay.v
    runtime_plan.v
    diagnostic.v
```

The `plan` module imports neither config decoders nor runtime implementations.

### Configuration module

```text
src/config/
    v2_types.v
    v2_decode.v
    runtime_plan_compile.v
    compat_compile.v
    plan_diagnostics.v
```

Current config files remain during migration, but runtime assembly stops consuming `VhttpdConfig` directly.

### Runtime adapters

V module constraints may keep veb-facing code in module `main`, but ownership is split by file:

```text
src/http_ingress_runtime.v
src/http_response_runtime.v
src/http_adapter_runtime.v
src/static_adapter_runtime.v
src/upload_adapter_runtime.v
src/websocket_ingress_runtime.v
src/stream_ingress_runtime.v
src/mcp_ingress_runtime.v
```

File boundaries matter even when V requires the same module for access to `App` and `Context`.

### Transformer implementations

```text
src/transformer_registry_runtime.v
src/native_transformer_runtime.v
src/vjsx_transformer_runtime.v
src/feishu_transformer_runtime.v
```

Feishu transport/provider connection code remains in provider/adapter ownership. Only event transformation moves behind the transformer contract.

### Relay module

```text
src/relay/
    protocol.v
    frame.v
    carrier.v
    hub.v
    agent.v
    registry.v
    session.v
    channel.v
    correlation.v
    backpressure.v
    reconnect.v
```

The first carrier implementation uses WebSocket over TLS.

## `main.v` Target

`main.v` should contain only:

- `Context`
- `App` top-level composition state
- minimal veb route methods
- handoff to ingress runtimes
- small process-wide helpers that cannot live elsewhere

Target size after Phase 1: below 400 lines. No protocol session loop, route matcher, cache policy, worker outcome renderer, or provider-specific dispatch remains there.

## `App` Target

The initial target shape is intentionally small:

```v
@[heap]
pub struct App {
    veb.Middleware[Context]
    veb.StaticHandler
    DataPlaneRuntime
pub mut:
    control_plane ControlPlaneRuntime
    lifecycle     ProcessLifecycle
}
```

`DataPlaneRuntime` uses V struct embedding so existing route code and focused test fixtures can use promoted fields without duplicating state. Control-plane and process-lifecycle ownership remain explicitly named. The ownership rule, rather than pointer syntax, is authoritative.

### Closed-module checklist

A subsystem extraction is complete only if:

1. Its mutable state has left `App`.
2. Its locks protect only state owned by that subsystem.
3. Startup and shutdown are methods of the subsystem.
4. Request handling calls a narrow subsystem API.
5. Admin data comes from the subsystem snapshot API.
6. Tests can construct the subsystem without constructing the full App.
7. No provider/application-specific method was added to a generic facade.

### Initial ownership split

| Current ownership | Target owner |
|---|---|
| routes and response cache policy | `PipelineRuntime` |
| worker pools and queue state | `EngineRuntime` / worker pool runtime |
| DB and cache servers/clients | `ResourceRuntime` |
| WebSocket hub, sessions, presence | `WebSocketRuntime` |
| MCP sessions | `McpRuntime` |
| stream state | `StreamRuntime` |
| provider instances | `ProviderRuntime` |
| relay nodes/channels | `RelayRuntime` |
| admin state and snapshots | `ControlPlaneRuntime` collecting subsystem snapshots |
| process signals and shutdown ordering | `ProcessLifecycle` |

The control plane reads immutable snapshots or calls explicit control methods. It does not reach into subsystem locks or maps.

## Performance Design

### No per-stage serialization

- native V stages share the in-process Exchange
- VJSX boundary serializes once per VJSX invocation
- relay boundary encodes once per outgoing frame
- worker wire compatibility encoding remains at the worker boundary

### Compile hot-path decisions

- route regexes compile at startup
- references resolve to indexed runtime entries
- capability validation occurs at startup
- listener pipeline order is precomputed
- policies are normalized into executable plans

### Bounded concurrency

- every engine, transform queue, relay channel, and stream buffer has a bound
- VJSX reuses lane workers rather than spawning unbounded request threads
- native transformers declare parallel, serial, lane, or keyed concurrency behavior
- queue wait and execution time are observed separately

### Copy budget

The initial implementation avoids explicit `.clone()` calls between pipeline stages. Payload copies are permitted only at ownership boundaries that outlive the current callback, including queued VJSX work, relay frames, and fanout children.

### Performance acceptance

For the HTTP compatibility path:

- no more than 5% throughput regression against the pre-pipeline baseline
- no unbounded increase in allocations per request
- static response path remains independent from PHP/VJSX execution
- response cache hit does not invoke application transformers unless configured
- streaming paths never buffer the entire response

Benchmarks must record baseline numbers before the first behavior-changing phase.

## Observability

Every pipeline transition emits structured fields:

- exchange_id
- request_id
- trace_id
- pipeline_id
- ingress
- transform
- transform_backend (`native` or `vjsx`)
- egress
- relay_node/channel when present
- queue_duration_ms
- execution_duration_ms
- bytes/frames
- status
- error_class

Admin runtime views eventually expose:

- compiled plans and compatibility translations
- adapter and transform capabilities
- transform backend and queue state
- active relay nodes/channels
- per-pipeline traffic and failures

## Testing Strategy

### Pure unit tests

- Exchange identity and child/fanout semantics
- ResourceRef parsing
- V1 compatibility translation
- strict V2 unknown-field rejection
- matcher compilation and ordering
- shared-listener host matching and unknown-host behavior
- TLS certificate/SNI plan validation
- capability validation
- action validation
- error classification

### Transformer conformance suite

One fixture suite runs against native V and VJSX implementations:

- continue with header/metadata mutation
- respond
- forward target selection
- reject with error class
- deadline exceeded
- cancellation
- state/cache access
- malformed action
- trace preservation

Equivalent implementations must produce equivalent normalized actions and Exchange mutations.

### Adapter contract tests

- HTTP request/response
- event acknowledgement
- stream start/chunk/end
- WebSocket session open/message/close
- MCP session/message flow
- relay delivery and target unavailable

### Integration tests

- HTTP -> PHP worker -> HTTP response
- HTTP -> native transform -> HTTP upstream
- HTTP -> VJSX transform -> PHP CGI
- HTTP -> explicit MCP bridge -> MCP
- WebSocket -> transform -> WebSocket
- stream -> transform -> stream
- public relay HTTP ingress -> local agent -> response
- relay reconnect and bounded pending channel behavior

### Existing regression suites

The following remain release gates:

- WordPress and WooCommerce flows
- PHP worker/CGI queue behavior
- response cache behavior
- MCP tests
- OpenAI streaming tests
- WebSocket and WebSocket upstream tests
- Feishu tests
- Paseo relay tests

## Migration Phases

### Phase 0: baseline and guardrails

Deliverables:

- architecture and configuration documents
- this implementation plan
- HTTP/WordPress/Paseo baseline test commands
- baseline performance measurements

No behavior changes.

### Phase 1: remove data-plane implementation from `main.v`

Batches:

1. Move route matching and response-cache policy to dedicated runtime files.
2. Move WebSocket ingress and worker bridge/session code.
3. Move HTTP executor selection, dispatch, and response rendering.
4. Leave thin veb route methods calling ingress runtimes.
5. Introduce top-level runtime owners and move state together with extracted behavior.

Acceptance:

- `main.v` below 400 lines
- `App` contains only top-level runtime owners and veb integration fields
- extracted modules satisfy the closed-module checklist
- no config or runtime behavior change
- targeted tests plus `make build` pass after each batch

#### Phase 1 execution tasks

Progress as of 2026-06-23:

- `P1.0` baseline recorded; targeted tests and build pass, while the pre-existing host readiness probe failure remains documented
- `P1.1` complete: `HttpRoutingRuntime` owns route matching, rewrite, static-root selection, and response-cache policy
- `P1.2` complete: `WebSocketRuntime` owns hub state/context/snapshot/control behavior, `websocket_ingress_runtime.v` owns upgrade/bridge/session handling, and generic upstream sessions live in an independent `UpstreamRuntimeRegistry`
- `P1.3` complete: `EngineRuntime` owns primary and named pools, protocol dispatch, queue/socket selection, request accounting, process restart/drain behavior, warmup/shutdown, environment injection, metrics, and admin snapshots; App exposes only compatibility adapters and a narrow emit port
- `P1.4` complete: `HttpIngressRuntime` owns catch-all protocol entry, route guards, static/upload routing, cache lookup, rewrite, and engine dispatch; `HttpResponseRuntime` renders cache hits, dispatch errors, streams, upstream plans, and normal responses while veb routes remain thin adapters
- `P1.5` complete: App contains only embedded `DataPlaneRuntime`, named `ControlPlaneRuntime`, and named `ProcessLifecycle`; control-plane emission/snapshots and process start/stop ordering are owner methods, with independent owner tests

Phase 1 acceptance results on 2026-06-22:

- `main.v` is 111 lines after host built-in route isolation, and App contains only veb integration plus the three top-level runtime owners
- `make test`, `make test-inproc`, `make build`, and `php php/package/tests/wordpress_lifecycle_test.php` pass
- the host regression runner still reaches the pre-existing `/bench/health` readiness timeout recorded in P1.0; startup logs show requests entering `proxy_get`, with no new failure introduced by the ownership refactor

`P1.0 Baseline`

- run `make test src/route_rule_test.v src/server_logic_test.v`
- run `make test src/websocket_dispatch_lifecycle_test.v src/websocket_upstream_runtime_test.v`
- run `make build`
- run `VHTTPD_BENCH_RUN_K6=0 bash bench/run_host_regression.sh`
- when k6 is available, record short-request throughput and latency from `bench/k6_short.js`
- save commands and results in a dated baseline note under `tmp/` or the eventual benchmark artifact location; do not commit machine-specific absolute paths

`P1.1 HTTP routing owner`

- introduce `HttpRoutingRuntime`
- move `RuntimeRouteRule`, matcher compilation, rewrite, header/query guards, directory redirect, and response-cache policy behavior from `main.v`
- move route state and its synchronization out of App
- inject narrow cache/document-root services rather than reading unrelated App fields
- keep current route order and behavior exactly

Primary files:

- `src/main.v`
- new `src/http_routing_runtime.v`
- `src/app_runtime_builder.v`
- `src/route_rule_test.v`
- `src/server_logic_test.v`

Commit boundary: move and ownership only; no V2 syntax or Exchange types.

`P1.2 WebSocket runtime closure`

- move WebSocket upgrade detection, open, callbacks, worker bridge, dispatch session, presence/session state, and snapshots behind `WebSocketRuntime`
- consolidate current `App` methods and `transport.websocket` state under one owner
- keep live connection ownership in the WebSocket runtime
- expose explicit open/session/control/snapshot methods

Primary files:

- `src/main.v`
- `src/ws/*`
- `src/websocket_runtime.v`
- `src/websocket_dispatch_lifecycle_test.v`
- `src/websocket_upstream_runtime_test.v`

Commit boundary: no protocol wire or VJSX callback changes.

`P1.3 Engine runtime closure`

- introduce one owner for the primary engine and additional worker pools
- move worker selection, queue lifecycle, start/finish accounting, warmup, drain, and snapshot behavior out of App
- keep PHP worker, PHP CGI, and VJSX engine selection behavior unchanged
- expose capability-scoped services to compatibility executors

Primary files:

- `src/app_runtime_builder.v`
- `src/executor_bridge.v`
- `src/worker_backend_*`
- `src/server_runtime_orchestrator.v`
- `src/server_logic_test.v`

Commit boundary: ownership and facade narrowing only.

`P1.4 HTTP ingress and outcome rendering`

- move `proxy_worker_response` orchestration into `HttpIngressRuntime`
- move normal response, stream plan, upstream plan, cache response, and error rendering into focused runtime methods
- leave veb route methods as thin adapters
- preserve HEAD, static, upload, cache, trace, and error behavior

Primary files:

- `src/main.v`
- new `src/http_ingress_runtime.v`
- new `src/http_response_runtime.v`
- existing stream/upstream/upload runtime files

Commit boundary: no canonical Exchange pipeline yet.

`P1.5 Top-level App composition`

- introduce `DataPlaneRuntime`, `ControlPlaneRuntime`, and `ProcessLifecycle` ownership
- migrate remaining subsystem references out of App
- make control-plane snapshots call subsystem APIs
- verify shutdown ordering and worker cleanup

Acceptance commands:

- `make test`
- `make test-inproc`
- `make build`
- `VHTTPD_BENCH_RUN_K6=0 bash bench/run_host_regression.sh`
- targeted WordPress lifecycle tests used by the current example

Phase 1 is complete only when `main.v` and App satisfy their target sections; completing only P1.1 file moves is not enough.

### Phase 2: RuntimePlan and configuration compiler

Progress as of 2026-06-22:

- `P2.1` complete: the independent `runtime_plan` module defines the immutable top-level plan, all eleven V2 domains, typed kind-specific options, canonical resource references, and declaration-ordered pipelines without importing legacy config or runtime implementations
- `P2.2` complete: `config.V2Config` explicitly models every stable root domain, resource and policy subcategories, kind-facing specs, references, matches, TLS, tracing, and relay fields; a representative TOML decode test covers the complete root vocabulary
- `P2.3` complete: the shared compiler resolves and validates all plan references; the V1 compatibility compiler covers core HTTP resources, named engines, route policies, MCP/OpenAI ingress, Feishu/Codex adapters, plugin transforms, WebSocket concurrency, bridge relays, fixed responses, and upload-completion event pipelines; plan diagnostics expose compatibility rewrites, an independently authored V1/V2 golden produces equivalent HTTP plans, and the repository WordPress/OpenAI examples compile successfully
- `P2.4` in progress: single-site and multi-site resolution carry one immutable RuntimePlan with an explicit active listener ID; DataPlaneRuntime owns it, and request-time route rules plus referenced additional-worker discovery are now assembled from listener pipelines, adapters, transforms, and policies rather than raw V1 routes
- `P2.4` resource slice complete: DB and cache transport runtimes are selected from the active listener fallback engine resources in RuntimePlan, so multi-site listeners no longer depend on global V1 DB/cache fields during app assembly
- `P2.4` protocol slice complete: MCP and OpenAI runtime state are projected from listener adapter plans, including limits, allowed origins, endpoint toggles, backend records, and model routes
- `P2.4` plugin slice complete: plugin configs are restored from plugin engine/transform plans and existing VJSX plugin runtime construction is reused without reading V1 plugin maps during app assembly
- `P2.4` CLI overlay slice complete: executor, worker, PHP, VJSX, Feishu, and Ollama command-line overrides are folded into the active listener RuntimePlan before app assembly, preserving legacy CLI behavior while reducing raw V1 config reads
- `P2.4` provider slice complete: Feishu, Codex, Ollama, and bridge runtime settings are projected from RuntimePlan adapters/relays with the legacy provider resolver retained only as a compatibility fallback
- `P2.4` primary engine slice complete: `ServerRuntimeConfig.executor_plan` is reconstructed from the active listener fallback engine in RuntimePlan, reusing the existing executor registry and retaining legacy path-resolution fallbacks
- `P2.4` additional engine slice complete: named route and event engines such as PHP CGI and VJSX are resolved from active listener RuntimePlan references, with legacy executor specs used only as compatibility fallbacks
- `P2.4` VJSX config surface slice complete: the in-proc runtime now exposes `runtime.plan()` / `runtime.getPlan()` backed by RuntimePlan JSON while retaining the legacy `runtime.config()` / `runtime.getConfig()` surface for compatibility
- `P2.4` shell runtime slice complete: event log, pid file, admin token, and listener asset runtime settings are projected from RuntimePlan with CLI startup overrides still applied at the process boundary
- `P2.4` admin plan slice complete: the resolved RuntimePlan is available from both data-plane and dedicated admin-plane `/admin/runtime/plan` endpoints for inspection and tooling
- `P2.5` loader slice complete: startup can load a versioned RuntimePlan directly from `version = 2` TOML while retaining V1 compatibility compilation when the version is omitted; single-listener startup, multi-listener startup, and timezone resolution now use the shared RuntimePlan loader
- `P2.5` strict V2 slice complete: V2 loading rejects unknown root and kind-specific fields, preserves extension maps for options/headers/query metadata, resolves `${env.*}` and `${paths.root}` expressions, and normalizes declared path fields relative to the config file directory
- `P2.5` listener validation slice complete: the V2 compiler rejects listeners that are not consumed by a request pipeline, control plane, or relay, catching empty data-plane listener declarations before runtime startup
- `P2.5` worker runtime slice complete: primary worker read timeout, restart backoff, max requests, queue capacity, and queue timeout are projected from the active listener fallback engine options, with CLI overrides still taking precedence
- `P2.5` semantic validation slice complete: strict V2 rejects unknown engine and transform kinds, requires concrete PHP worker/VJSX entries outside compatibility plans, and requires VJSX transforms to reference an engine with a handler
- `P3.1` contract slice complete: the dispatch module now has pure Exchange identity, kind, payload, capability, transform action, runtime service, transformer, ingress descriptor, egress adapter, delivery outcome, pipeline descriptor, and pipeline dispatcher contracts that do not import executor, veb, or live transport objects
- `P3.2` HTTP normalization slice complete: the dispatch module can build a request Exchange from plain HTTP values and match it against pure method, host, path, query, and header rules while keeping veb request objects and compiled regex state at the ingress/runtime edge
- `P3.2` plan projection slice complete: listener pipelines can be projected from RuntimePlan into dispatch pipeline descriptors and basic HTTP matchers while preserving declaration order and leaving regex indexes to the runtime edge
- `P3.3` terminal adapter slice complete: fixed-response and reject now have dispatch `EgressAdapter` implementations and RuntimePlan projection helpers that return protocol-neutral delivery outcomes without importing veb or HTTP connection state
- `P3.4` terminal HTTP slice complete: existing route status, redirect, required-header, denied-query, body-limit, and `executor = "none"` block responses now flow through dispatch delivery outcomes before HTTP rendering, preserving legacy route response headers and carrying trace/error metadata through one terminal helper
- `P3.4` static file outcome slice complete: static file hits, missing files, and method rejections now produce dispatch delivery outcomes before HTTP rendering, while file existence checks and veb file sending remain owned by the HTTP runtime
- `P3.4` upload response slice complete: upload success and error responses now render through dispatch delivery outcomes while parsing, persistence, hashing, and upload completion event dispatch remain owned by the upload runtime
- `P3.4` worker response slice complete for finite responses: normal executor HTTP responses are mapped into dispatch response delivery outcomes before rendering, response-cache storage decisions read delivery outcomes directly, and delivery header rendering handles `Set-Cookie` generically across worker, MCP, and terminal outcomes while preserving response cache behavior
- `P3.4` failure response slice complete: worker/backend dispatch errors are classified into dispatch failure delivery outcomes before HTTP rendering, so trace/error headers and `http.request` observations flow through the same terminal renderer as other delivery outcomes
- `P3.4` MCP finite response slice complete: MCP POST JSON responses and MCP GET pre-stream JSON errors now render through dispatch delivery outcomes with observation metadata, while MCP validation, queueing, session state, and live SSE streaming remain owned by the MCP runtime
- `P3.4` ingress finite response slice complete: no-executor 404 responses and directory slash redirects now flow through dispatch delivery outcomes, so trace headers and request observations use the same renderer as terminal adapter responses
- `P3.4` cache-hit response slice complete: route response-cache hits now render through dispatch delivery outcomes while preserving `x-vhttpd-cache`, cache-control, content-type, route headers, and `cache=hit` observations
- `P3.4` host built-in route slice complete: `/health`, `/dispatch`, and `/events/stream` moved out of `main.v`; finite built-in responses render through dispatch delivery outcomes while the SSE endpoint keeps direct stream ownership
- `P3.4` pre-stream failure slice complete: stream dispatch open failures and upstream-plan validation failures now render finite error responses through dispatch delivery outcomes before any client connection takeover
- `P3.4` OpenAI finite response slice complete: OpenAI error responses, models responses, non-stream executor responses, non-stream HTTP proxy responses, and Responses registry reads now render through dispatch delivery outcomes while preserving `x-request-id`, backend headers, and provider observations
- `P3.4` Feishu callback error slice complete: callback validation, bridge, and worker dispatch errors now render through dispatch delivery outcomes with trace/request/provider observations while successful callback handling remains in the Feishu runtime
- `P3.4` data-plane admin response slice complete: provider and worker admin endpoints now render finite JSON/text responses through dispatch delivery outcomes while preserving admin action events
- `P3.4` admin-plane summary response slice complete: dedicated admin-plane health, workers, stats, and runtime summary endpoints now render finite text/JSON responses through dispatch delivery outcomes with admin-plane observations
- `P3.4` admin-plane finite response slice complete: dedicated admin-plane catalog, runtime snapshot, Feishu admin, and worker restart endpoints now render finite JSON/text responses through dispatch delivery outcomes while preserving worker restart action events
- `P3.4` stream boundary decision recorded: current stream and upstream-plan executor outcomes still carry live Unix connection or concrete upstream plan state, so they remain outside pure dispatch delivery outcomes until stream/upstream runtimes own those live resources behind protocol-neutral terminal plans

Batches:

1. Add pure RuntimePlan/resource/reference types for every V2 domain.
2. Add the complete V2 root decode/spec model.
3. Compile current V1 config into RuntimePlan.
4. Make runtime assembly consume RuntimePlan.
5. Add strict V2 decoder and compiler. (in progress; loader, field validation, path/env resolution, reference validation, and listener coverage are implemented)
6. Add resolved-plan admin/debug output. (complete for `/admin/runtime/plan` on both admin surfaces)

Acceptance:

- runtime behavior is identical for existing configs
- no runtime component reads raw V1 route/executor fields
- representative V1 and V2 configs compile to equivalent plans
- every current V1 field has a compatibility mapping or an explicit unsupported/deprecation diagnostic
- strict V2 rejects unknown root and kind-specific fields
- golden plan tests cover server, listeners, control, observability, resources, engines, adapters, transforms, policies, pipelines, and relays

### Phase 3: HTTP pipeline vertical slice

Batches:

1. Add Exchange, capability, action, adapter, and pipeline contracts. (contract slice complete)
2. Implement HTTP ingress normalization. (pure value-to-Exchange conversion and basic HTTP matcher complete)
3. Wrap PHP worker, PHP CGI, static, upload, fixed response, and reject as adapters. (fixed-response and reject slices complete)
4. Execute existing HTTP routes through compiled pipelines. (started with terminal fixed-response delivery outcome rendering)
5. Preserve cache and security policies through named policy plans.

Acceptance:

- WordPress traffic runs through pipeline plans
- V1 config remains compatible
- HTTP performance stays within budget
- trace ID appears on every pipeline transition

### Phase 4: interchangeable transformers

Batches:

1. Implement transformer registry and native backend.
2. Implement VJSX transformer wrapper using lane workers.
3. Add conformance suite.
4. Wrap Feishu event transformation as native V.
5. Run equivalent routing fixture through VJSX.
6. Route upload completion through a transformer pipeline.

Acceptance:

- changing only transform `kind/engine/handler` switches backend
- pipeline definitions remain unchanged
- no transport lifecycle enters transformer code
- queue limits and trace fields are visible

### Phase 5: stream, WebSocket, and MCP migration

Batches:

1. Adapt stream frames to Exchange lifecycle.
2. Adapt WebSocket session events.
3. Adapt MCP sessions/messages.
4. Add explicit protocol bridge transforms.
5. Split the broad `LogicExecutor` interface into capability interfaces.
6. Split `executor.AppFacade` into capability-scoped service interfaces.

Acceptance:

- HTTP dispatch contains no MCP/WebSocket/stream selection branches
- session and streaming cancellation/backpressure remain correct
- executors implement only capabilities they provide
- no generic facade contains provider-specific methods

### Phase 6: generic relay

Batches:

1. Version relay wire frames.
2. Implement hub registration/authentication.
3. Implement agent connection/reconnect.
4. Implement correlation and logical channels.
5. Add stream/session forwarding and bounded buffers.
6. Move generic Paseo channel/session behavior into relay runtime.
7. Keep Paseo-specific pairing/routing policy in VJSX.

Acceptance:

- public HTTP request reaches selected local vhttpd and returns a response
- trace ID crosses both nodes
- reconnect and target-unavailable behavior are deterministic
- Paseo compatibility remains green
- relay core contains no Feishu/Paseo payload logic

### Phase 7: hot plan replacement and hardening

Deliverables:

- atomic RuntimePlan replacement
- transformer backend hot switching
- drain/close lifecycle for replaced engines/adapters
- circuit breaking and health-aware target selection
- extended admin views and distributed tracing

Acceptance:

- plan replacement does not interrupt unaffected pipelines
- stateful transformers reject unsafe hot switches unless state is externalized or a migration hook is provided
- old runtime resources drain without leaks

## Commit Strategy

Each batch should be separately reviewable:

- move-only commits before behavior commits
- contract/type commits before adapter implementations
- compatibility compiler before V2 examples
- native transformer before VJSX transformer
- relay wire contract before hub/agent behavior

Do not combine WordPress compatibility changes with protocol-kernel changes unless a failing generic contract requires both.

## First Work Queue

The immediate implementation queue is:

1. Capture baseline tests and benchmark commands.
2. Extract `RuntimeRouteRule` and response-cache logic from `main.v`.
3. Extract WebSocket ingress/session bridge from `main.v`.
4. Extract HTTP dispatch/outcome rendering from `main.v`.
5. Introduce pure RuntimePlan and ResourceRef types.
6. Compile existing config into RuntimePlan without changing behavior.

Only after these six items are complete should request traffic move through the new Exchange pipeline.

## Review Checklist

Every implementation PR must answer:

- Which stable resource owns this behavior?
- Does one closed runtime module own its state, locks, lifecycle, behavior, and snapshot?
- Is this change shrinking App/global facade ownership rather than renaming it?
- Is this application protocol, carrier, transform, adapter, policy, or relay behavior?
- Does runtime code consume only compiled plan data?
- Does native V/VJSX parity matter here?
- Are queues and buffers bounded?
- Is trace ID preserved?
- Does this add provider-specific behavior to the generic core?
- Does it introduce request-time parsing or serialization that can be compiled away?
- Which existing regression and performance gates cover it?

## Related Documents

- [PROTOCOL_PIPELINE_RELAY_ARCHITECTURE.md](PROTOCOL_PIPELINE_RELAY_ARCHITECTURE.md)
- [CONFIGURATION_MODEL_V2.md](CONFIGURATION_MODEL_V2.md)
- [ARCHITECTURE_REFACTOR_BASELINE.md](ARCHITECTURE_REFACTOR_BASELINE.md)
- [PASEO_RELAY_VHTTPD_PLAN.md](PASEO_RELAY_VHTTPD_PLAN.md)
- [transport_contract.md](transport_contract.md)
