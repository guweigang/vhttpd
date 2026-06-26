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
- `P3.3` runtime adapter descriptor slice complete: static, upload, HTTP handler, MCP, WebSocket, and other runtime-owned adapters now project into pure dispatch adapter descriptors with capabilities while remaining outside pure terminal delivery until their runtime owners provide IO
- `P3.3` pipeline capability projection slice complete: pipeline descriptors can now inherit required capabilities from their egress adapter descriptors, giving later pipeline execution a pure compatibility check surface before runtime IO is introduced
- `P3.3` pipeline capability validation slice complete: dispatch can now compare listener ingress capabilities against projected pipeline egress requirements and report stable mismatch codes without coupling the config compiler to dispatch
- `P3.3` event-ingress capability slice complete: upload-completion event pipelines that use `event-ingress` adapters are now represented as ingress descriptors and participate in the same pure capability validation surface
- `P3.3` transform and terminal descriptor slice complete: native/VJSX transforms and `terminal:ack|response|reject` egress references now project into pure descriptors, so pipeline validation can distinguish transform-supported exchange capabilities from terminal egress requirements
- `P3.3` pipeline capability diagnostics slice complete: capability validation now emits typed issues plus RuntimePlan-style diagnostics while preserving stable string messages for compatibility
- `P3.3` runtime plan projection validation slice complete: projected pipeline capability issues and RuntimePlan diagnostics now have a reusable dispatch validation facade for startup/admin/config surfaces without coupling the config compiler to dispatch
- `P3.3` runtime-visible projection diagnostics slice complete: app runtime assembly now appends projection diagnostics to the plan exposed through `app.plan`, `/admin/runtime/plan`, and VJSX host config lookup while leaving compile-time config diagnostics owned by the config layer
- `P3.4` terminal HTTP slice complete: existing route status, redirect, required-header, denied-query, body-limit, and `executor = "none"` block responses now flow through dispatch delivery outcomes before HTTP rendering, preserving legacy route response headers and carrying trace/error metadata through one terminal helper
- `P3.4` static file outcome slice complete: static file hits, missing files, and method rejections now produce dispatch delivery outcomes before HTTP rendering, while file existence checks and veb file sending remain owned by the HTTP runtime
- `P3.4` upload response slice complete: upload success and error responses now render through dispatch delivery outcomes while parsing, persistence, hashing, and upload completion event dispatch remain owned by the upload runtime
- `P3.4` worker response slice complete for finite responses: normal executor HTTP responses are mapped into dispatch response delivery outcomes before rendering, response-cache storage decisions read delivery outcomes directly, and delivery header rendering handles `Set-Cookie` generically across worker, MCP, and terminal outcomes while preserving response cache behavior
- `P3.4` failure response slice complete: worker/backend dispatch errors are classified into dispatch failure delivery outcomes before HTTP rendering, so trace/error headers and `http.request` observations flow through the same terminal renderer as other delivery outcomes
- `P3.4` MCP finite response slice complete: MCP POST JSON responses and MCP GET pre-stream JSON errors now render through dispatch delivery outcomes with observation metadata, while MCP validation, queueing, session state, and live SSE streaming remain owned by the MCP runtime
- `P3.4` MCP lifecycle response slice complete: MCP DELETE session success, missing-session, unknown-session, and forbidden-origin responses now reuse the MCP delivery outcome renderer while session deletion remains owned by the MCP runtime
- `P3.4` ingress finite response slice complete: no-executor 404 responses and directory slash redirects now flow through dispatch delivery outcomes, so trace headers and request observations use the same renderer as terminal adapter responses
- `P3.4` cache-hit response slice complete: route response-cache hits now render through dispatch delivery outcomes while preserving `x-vhttpd-cache`, cache-control, content-type, route headers, and `cache=hit` observations
- `P3.4` host built-in route slice complete: `/health`, `/dispatch`, and `/events/stream` moved out of `main.v`; finite built-in responses render through dispatch delivery outcomes while the SSE endpoint keeps direct stream ownership
- `P3.4` pre-stream failure slice complete: stream dispatch open failures and upstream-plan validation failures now render finite error responses through dispatch delivery outcomes before any client connection takeover
- `P3.4` OpenAI finite response slice complete: OpenAI error responses, models responses, non-stream executor responses, non-stream HTTP proxy responses, and Responses registry reads now render through dispatch delivery outcomes while preserving `x-request-id`, backend headers, and provider observations
- `P3.4` Feishu callback error slice complete: callback validation, bridge, and worker dispatch errors now render through dispatch delivery outcomes with trace/request/provider observations while successful callback handling remains in the Feishu runtime
- `P3.4` Feishu callback success slice complete: challenge, normal ACK, and card-bridge callback responses now render through dispatch delivery outcomes while preserving callback/provider metadata and bridge response headers
- `P3.4` Feishu bridge pre-upgrade response slice complete: `/bridge/ws` not-found, upgrade-required, and forbidden responses now render through dispatch delivery outcomes while successful WebSocket takeover remains owned by the bridge server runtime
- `P3.4` WebSocket open failure slice complete: worker-backed and dispatch-backed WebSocket upgrade/open rejection paths now render finite responses through dispatch delivery outcomes while accepted sessions still take over the client connection
- `P3.4` data-plane admin response slice complete: provider and worker admin endpoints now render finite JSON/text responses through dispatch delivery outcomes while preserving admin action events
- `P3.4` data-plane runtime admin slice complete: data-plane runtime summary, runtime plan, upstream, websocket, MCP, provider-instance, provider specs, and provider runtime endpoints now share the data-plane delivery outcome helper for success and disabled-admin 404 responses
- `P3.4` admin-plane summary response slice complete: dedicated admin-plane health, workers, stats, and runtime summary endpoints now render finite text/JSON responses through dispatch delivery outcomes with admin-plane observations
- `P3.4` admin-plane finite response slice complete: dedicated admin-plane catalog, runtime snapshot, Feishu admin, and worker restart endpoints now render finite JSON/text responses through dispatch delivery outcomes while preserving worker restart action events
- `P3.4` live outcome constructor slice complete: dispatch now exposes protocol-neutral constructors for stream plans, session plans, and relay deliveries, allowing live runtimes to project intent without embedding HTTP/WebSocket connection ownership in dispatch
- `P3.4` upstream-plan projection slice complete: worker upstream-plan frames now project to protocol-neutral stream-plan delivery outcomes for shared target/header/metadata derivation while upstream runtime keeps connection takeover and IO ownership
- `P3.4` direct worker stream projection slice complete: worker stream start frames now project to protocol-neutral stream-plan delivery outcomes for shared status/header/content-type/metadata derivation while direct stream runtime keeps socket takeover and chunk IO ownership
- `P3.4` stream-dispatch projection slice complete: stream-dispatch open responses now project to protocol-neutral stream-plan delivery outcomes for shared target/header/content-type/metadata derivation while the dispatch stream runtime keeps session close and chunk IO ownership
- `P3.4` MCP session projection slice complete: MCP GET session streams now project to protocol-neutral session-plan delivery outcomes for shared status/header/protocol metadata derivation while the MCP runtime keeps SSE connection ownership and keepalive delivery
- `P3.4` WebSocket session projection slice complete: worker-backed and dispatch-backed accepted WebSocket opens now project to protocol-neutral session-plan delivery outcomes for shared target/status/session metadata derivation while WebSocket runtimes keep handshake, callbacks, and live connection ownership
- `P3.4` Feishu bridge relay projection slice complete: card callback dispatches and proxy requests now project to protocol-neutral relay-delivery outcomes for shared relay target/carrier/direction metadata while the Feishu bridge runtime keeps WebSocket send, pending response, and timeout ownership
- `P3.4` Feishu bridge session projection slice complete: `/bridge/ws` accepted relay clients now project to protocol-neutral session-plan delivery outcomes for shared relay target/client/session metadata while the bridge server runtime keeps WebSocket handshake and client registry ownership
- `P3.4` Feishu bridge context slice complete: low-level bridge client/server send, registry, and pending-response state moved off App helper methods and behind a provider-owned bridge context while the remaining App-facing bridge dispatch API stays as a compatibility facade for executor/VJSX callers
- `P3.4` provider bridge port slice complete: high-level Feishu bridge dispatch/proxy/fallback behavior moved onto `ProviderRuntimeHub`, executor/VJSX callers now use a generic provider bridge dispatch port, and App no longer exposes Feishu bridge send/proxy/dispatch helper methods
- `P3.4` provider catalog port slice complete: provider registry, provider specs, provider instance registry, and bootstrap/runtime catalog helpers now resolve through `ProviderRuntimeHub`, leaving App as the locking/coordination facade while runtime-triggering apply/ensure behavior remains at the orchestration boundary
- `P3.4` Feishu provider state port slice complete: Feishu readiness, source classification, callback token validation, bridge-proxy-only checks, and runtime snapshots now resolve through `ProviderRuntimeHub`, with App retaining only compatibility facades for existing tests and call sites
- `P3.4` Codex provider state port slice complete: Codex enabled checks, known instance catalog, config/state views, and admin runtime snapshots now resolve through `ProviderRuntimeHub`, while state-mutating runtime operations remain at the provider orchestration boundary
- `P3.4` provider dispatch context slice complete: `ProviderRuntimeHub` now builds the provider runtime dispatch context for capabilities, gateway counts, upstream launches, and upstream enabled checks, while App only supplies external pull-url/db transport inputs
- `P3.4` provider upstream lifecycle port slice complete: reconnect delay and provider connection lifecycle state transitions now dispatch through `ProviderRuntimeHub`, including Codex instance materialization from provider-instance specs, while App retains the external pull-url boundary
- `P3.4` provider observation port slice complete: provider upstream snapshots, upstream event projections, and runtime metrics now resolve through `ProviderRuntimeHub`, keeping App as the HTTP/admin-facing compatibility entrypoint
- `P3.4` compiled HTTP route selection slice complete: request-time HTTP route selection now builds a dispatch `Exchange` and matches compiled RuntimePlan pipeline identity, host/header/query/path/method rules, carrying pipeline/ingress/policy refs into runtime observations and `x-vhttpd-pipeline`
- `P3.4` matched HTTP pipeline execution slice complete: `HttpPipelineRuntime` now owns matched pipeline guard execution plus terminal/static/upload egress pre-dispatch handling, leaving HTTP ingress responsible for protocol entry and dynamic engine dispatch
- `P3.4` protocol HTTP ingress slice complete on 2026-06-25: `ProtocolRuntimeHub` now owns the HTTP protocol entry, shared protocol request normalization, and OpenAI/MCP ingress port dispatch, keeping protocol-specific route decisions out of `HttpIngressRuntime`
- `P3.4` delivery header audit complete: OpenAI `x-request-id` now flows through delivery outcome headers; the remaining direct header/status writes are the HTTP delivery renderer itself, route/startup header policy injection, and the host SSE live stream boundary
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
3. Wrap PHP worker, PHP CGI, static, upload, fixed response, and reject as adapters. (fixed-response and reject terminal slices complete; runtime-owned adapters now have pure descriptors and capability projection)
4. Execute existing HTTP routes through compiled pipelines. (compiled route selection and matched pipeline execution are active for static, upload, fixed response, reject, and dynamic worker dispatch)
5. Preserve cache and security policies through named policy plans. (cache TTL/bypass, response headers, body limits, required headers, and denied query checks project into runtime routes)
6. Move HTTP pipeline state under `PipelineRuntime`. (ownership slice active: `DataPlaneRuntime.pipelines.http` owns HTTP routing state, dispatch plan derivation, rewrite targets, slash redirects, and response cache hit/store policy)
7. Keep WordPress as the HTTP vertical validation case. (strict V2 example added with resource, engine, adapter, policy, transform, and pipeline declarations)

Acceptance:

- WordPress traffic runs through pipeline plans
- V1 config remains compatible
- HTTP performance stays within budget
- trace ID appears on every pipeline transition

### Phase 4: interchangeable transformers

Progress as of 2026-06-25:

- `P4.1` transformer runtime registry slice complete: `DataPlaneRuntime` owns a `TransformerRuntimeHub` assembled from `RuntimePlan.transforms`, native transforms are registered as executable backend instances, and non-native transforms remain visible but unavailable until their backend wrappers are attached
- `P4.1` transformer chain runner slice complete: runtime code can execute ordered transform references through the registry with protocol-neutral `dispatch.Exchange` and `dispatch.RuntimeServices`, halting on non-continue actions while preserving trace-capable service emission
- `P4.2` VJSX transformer wrapper slice complete: VJSX transforms reuse the existing VJSX event dispatch path and engine/lane workers through an App-facing runtime wrapper instead of allocating a second lane pool
- `P4.3` transformer conformance slice complete: native and in-process VJSX backends both execute the same event exchange shape through transform refs and return `continue_pipeline`, with VJSX verified through a real lane worker
- `P4.4` Feishu native transform slice complete: `feishu.event.summary` parses Feishu event payloads into standardized exchange metadata for message and card-action events without taking ownership of Feishu callback transport, bridge, or upstream dispatch state
- `P4.5` VJSX fixture slice complete: the same Feishu event exchange shape is routed through an in-process VJSX transformer fixture and verified by the JS handler before returning `continue_pipeline`
- `P4.6` upload completion transformer slice complete: upload adapters project completed-event pipeline transform refs into runtime routes, dispatch upload completion as a `dispatch.Exchange`, prefer transformer execution, and fall back to legacy direct VJSX event dispatch during the transition
- `P4` observability slice complete: transformer runtime snapshots expose registered transforms, backend kind, handler, engine, availability, and capabilities through `/admin/runtime/transformers` on data-plane/admin-plane surfaces plus internal admin `/runtime/transformers`

Batches:

1. Implement transformer registry and native backend. (registry, native no-op backend, and transform chain runner complete)
2. Implement VJSX transformer wrapper using lane workers. (complete for event exchanges via existing VJSX dispatch)
3. Add conformance suite. (native and VJSX event-exchange conformance complete)
4. Wrap Feishu event transformation as native V. (complete for event summary projection)
5. Run equivalent routing fixture through VJSX. (complete for Feishu event exchange fixture)
6. Route upload completion through a transformer pipeline. (complete with legacy fallback)

Acceptance:

- changing only transform `kind/engine/handler` switches backend (validated by native/VJSX conformance fixtures)
- pipeline definitions remain unchanged (upload completion reads the configured completed pipeline transform refs)
- no transport lifecycle enters transformer code (VJSX uses the existing engine/lane dispatch port; native operates on `dispatch.Exchange`)
- queue limits and trace fields are visible (VJSX uses existing engine/lane queueing and transformer snapshots expose backend/capability state; event payloads carry request/trace IDs)

### Phase 5: stream, WebSocket, and MCP migration

Progress as of 2026-06-26:

- `P5.1` stream exchange projection slice complete: worker direct stream open/chunk/end frames and dispatch stream open/chunk/end frames can be projected into protocol-neutral `dispatch.Exchange` lifecycle values without moving TCP/Unix connection ownership out of their current stream runtimes
- `P5.2` WebSocket exchange projection slice complete: worker session open/message/close frames and runtime message/close events can be projected into protocol-neutral `dispatch.Exchange` session lifecycle values while the current WebSocket bridge still owns live socket IO
- `P5.3` MCP exchange projection slice complete: MCP POST dispatch requests/responses, session SSE opens, queued runtime messages, and session closes can be projected into protocol-neutral `dispatch.Exchange` request/response/stream/session lifecycle values while current MCP HTTP/SSE handlers still own live IO
- `P5.4` protocol bridge transform slice complete: native `protocol.bridge` transforms annotate exchanges with bridge metadata and return explicit `forward` actions to configured or exchange-provided targets without embedding provider-specific forwarding logic
- `P5.5` logic executor capability interface slice complete: executor identity/lifecycle, HTTP, stream, MCP, WebSocket session, WebSocket upstream, and WebSocket event capabilities are available as separate interfaces while the legacy aggregate `LogicExecutor` remains for compatibility
- `P5.6` AppFacade capability interface slice complete: runtime config, worker backend config, worker socket, stream/MCP/WebSocket dispatch, platform/admin, provider bridge, and command dispatch ports are available as separate interfaces while the legacy aggregate `AppFacade` remains for compatibility
- `P5.7` aggregate interface composition complete: legacy `LogicExecutor` and `AppFacade` now compose their capability interfaces instead of duplicating method lists; V currently does not narrow an aggregate interface value back to a capability interface, so call-site migration should use concrete construction-time capabilities or explicit wrapper ports
- `P5.8` HTTP executor port migration slice complete: `EngineDispatchSelection` now holds an explicit `LogicExecutorHttpPort` wrapper instead of the aggregate executor, giving HTTP routing a capability-scoped dependency while preserving legacy executor storage
- `P5.9` protocol executor port migration slice complete: EngineRuntime stream, MCP, WebSocket session, WebSocket upstream, and WebSocket event dispatch now route through explicit capability ports instead of directly invoking the aggregate executor
- `P5.10` worker dispatch facade port migration slice complete: SocketWorkerExecutor stream, MCP, WebSocket upstream, and WebSocket event backend calls now go through explicit AppFacade worker dispatch ports instead of directly invoking the aggregate facade
- `P5.11` worker socket/config facade port migration slice complete: SocketWorkerExecutor HTTP/WebSocket open and PhpCgiExecutor HTTP dispatch now use explicit worker socket and backend config ports for socket selection, inflight accounting, read timeouts, and per-pool environment lookup
- `P5.12` capability port module split complete: AppFacade ports and LogicExecutor ports now live in dedicated executor module files, keeping aggregate interfaces and concrete executor implementations smaller and more reviewable
- `P5.13` logic executor module split complete: capability interfaces, disabled executor, socket worker executor, and PHP-CGI executor now live in dedicated executor module files instead of sharing one broad implementation file
- `P5.14` in-process VJSX WebSocket type split complete: queued WebSocket task/frame payloads now live in a dedicated executor module, and WebSocket actor decisions sit beside affinity policy decisions
- `P5.15` in-process VJSX lane type split complete: lane wakeups, worker channels, and snapshot/warmup/pump/affinity task payloads now live in a dedicated executor module
- `P5.16` in-process VJSX lane host ownership slice complete: `VjsxLaneHost` now lives beside its host lifecycle facade instead of the broad executor type file
- `P5.17` in-process VJSX runtime/context type split complete: runtime payload metadata and active lane request context now live beside their runtime payload and lane context modules
- `P5.18` in-process VJSX constant split complete: lane, dispatch, startup, signature, and host facade constants now live in a dedicated executor module
- `P5.19` in-process VJSX plugin runtime split complete: plugin call and plugin stream dispatch now live in a focused executor module instead of the broad dispatch runtime
- `P5.20` in-process VJSX WebSocket upstream split complete: upstream dispatch and retry flow now live in a focused executor module, leaving the broad dispatch runtime closer to HTTP plus WebSocket event dispatch
- `P5.21` in-process VJSX WebSocket event split complete: event dispatch, lane callback entry, task enqueue, and response finalization now live in a focused executor module
- `P5.22` in-process VJSX host session-store API split complete: `vhttpdHost.sessionStore` request handling now lives in a focused host API module
- `P5.23` in-process VJSX host HTTP fetch API split complete: `vhttpdHost.httpFetch` request handling now lives in a focused host API module
- `P5.24` in-process VJSX host dispatch API split complete: `vhttpdHost.bridgeDispatch` and `vhttpdHost.websocketDispatch` request handling now live in a focused host API module
- `P5.25` in-process VJSX host config API split complete: `vhttpdHost.config` lookup and path traversal now live in a focused host API module
- `P5.26` in-process VJSX host filesystem API split complete: `vhttpdHost.readTextFile` and `vhttpdHost.findCodexSessionPath` now live in a focused host API module

Batches:

1. Adapt stream frames to Exchange lifecycle. (projection complete; runtime IO adoption pending)
2. Adapt WebSocket session events. (projection complete; runtime IO adoption pending)
3. Adapt MCP sessions/messages. (projection complete; runtime IO adoption pending)
4. Add explicit protocol bridge transforms. (native forward boundary complete; relay/adapter delivery adoption pending)
5. Split the broad `LogicExecutor` interface into capability interfaces. (capability interface definitions complete; call-site migration pending)
6. Split `executor.AppFacade` into capability-scoped service interfaces. (capability interface definitions complete; call-site migration pending)
7. Compose legacy aggregate interfaces from capability interfaces. (complete; call-site migration requires wrapper/construction changes)
8. Migrate HTTP dispatch selection to a capability-scoped executor port. (complete)
9. Migrate protocol dispatch methods to capability-scoped executor ports. (complete)
10. Migrate worker dispatch facade calls to capability-scoped facade ports. (complete)
11. Migrate worker socket/config facade calls to capability-scoped facade ports. (complete)
12. Move capability port wrappers into dedicated executor modules. (complete)
13. Move concrete logic executor implementations into dedicated executor modules. (complete)
14. Move in-process VJSX WebSocket task and policy decision types into focused modules. (complete)
15. Move in-process VJSX lane worker task and wakeup types into a focused module. (complete)
16. Move in-process VJSX lane host state next to its host facade methods. (complete)
17. Move in-process VJSX runtime metadata and lane request context types next to their runtime modules. (complete)
18. Move in-process VJSX runtime constants into a focused module. (complete)
19. Move in-process VJSX plugin call and stream dispatch into a focused module. (complete)
20. Move in-process VJSX WebSocket upstream dispatch into a focused module. (complete)
21. Move in-process VJSX WebSocket event dispatch into a focused module. (complete)
22. Move in-process VJSX host session-store API handling into a focused module. (complete)
23. Move in-process VJSX host HTTP fetch API handling into a focused module. (complete)
24. Move in-process VJSX host bridge and WebSocket dispatch API handling into a focused module. (complete)
25. Move in-process VJSX host config API handling into a focused module. (complete)
26. Move in-process VJSX host filesystem API handling into a focused module. (complete)

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
