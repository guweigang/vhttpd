# vhttpd Protocol Pipeline and Relay Architecture

Status: target architecture

This document defines the direction for the next vhttpd architecture iteration. It unifies two goals:

1. A single vhttpd instance can be configured as a gateway between HTTP, stream, WebSocket, MCP, and future protocols.
2. Multiple vhttpd instances can form a relay across network boundaries, such as a public relay forwarding Feishu traffic to a local server over an outbound long-lived connection.

WordPress/WooCommerce and Feishu/Paseo remain validation cases. They do not define special behavior in the vhttpd core.

## Product Direction

vhttpd is a general-purpose programmable runtime gateway.

It should be able to:

- accept traffic through different application protocols
- normalize traffic into a stable internal exchange contract
- optionally run VJSX logic
- forward the exchange through a different protocol or relay
- preserve streaming, duplex sessions, cancellation, backpressure, and observability
- expose the complete path under one trace ID

The target data path is:

```text
Ingress Adapter
    -> Canonical Exchange
    -> zero or more Transforms
    -> Egress Adapter
```

For cross-network deployments:

```text
Public Ingress
    -> Pipeline
    -> Relay Egress
    -> Relay Carrier
    -> Relay Ingress on local vhttpd
    -> Local Pipeline
    -> Local Egress or application runtime
```

## Architectural Principles

### Protocols are peers

HTTP, stream, WebSocket, and MCP must be implemented as peer adapters. HTTP must not remain the implicit center with the other protocols implemented as branches inside an HTTP handler.

### Application protocol and carrier are different concepts

WebSocket may be:

- an application-facing duplex protocol
- a carrier for the vhttpd relay protocol
- a connection to an upstream provider

These roles must not share one ambiguous `websocket` abstraction.

### VJSX is a transform, not a transport

VJSX can authenticate, rewrite, route, aggregate, reject, respond, or emit a forwarding plan. It does not own sockets, connection pools, relay reconnects, or protocol framing.

### Core behavior is generic

Application-specific behavior belongs in:

- configuration
- VJSX transforms
- framework packages such as `VHttpd\WordPress`

The vhttpd core must not identify WordPress, WooCommerce, Feishu, or Paseo unless implementing an explicit provider adapter outside the generic pipeline core.

### Capability validation is explicit

Not every protocol combination is meaningful. Adapters declare capabilities and the configuration compiler rejects incompatible pipelines before the server starts.

### Existing configuration remains valid

Current route fields such as `executor = "php"` remain supported. They are compiled into the new pipeline model during migration.

### Modules own complete runtime boundaries

Splitting files is not sufficient. Each runtime module owns its resolved plan, mutable state, locks, lifecycle, dispatch entrypoints, observability snapshot, and tests. `App` is a composition root required by veb, not the shared owner of every subsystem field.

Modules communicate through Exchange contracts, capability-scoped service interfaces, and events. They do not mutate another module's internal maps, queues, counters, or locks.

## Core Concepts

### 1. Surface

A surface is an externally visible application protocol:

- `http`
- `stream`
- `websocket`
- `mcp`
- future protocols and provider surfaces

A surface describes semantics, not the underlying socket implementation.

### 2. Carrier

A carrier moves bytes or frames between endpoints:

- TCP
- TLS
- WebSocket
- Unix socket
- HTTP/2 or HTTP/3 in the future

Carrier lifecycle belongs to transport implementations. Application adapters should not depend on a concrete carrier unless their protocol requires it.

### 3. Canonical Exchange

All ingress adapters produce a canonical Exchange. An Exchange carries common identity and lifecycle fields while allowing protocol-specific payloads.

Required common fields:

- exchange ID
- request ID
- trace ID
- parent trace/span information
- ingress adapter and endpoint
- route and pipeline ID
- timestamps and deadline
- headers and metadata
- authenticated principal
- payload or frame
- cancellation state
- session ID when applicable

Exchange kinds:

- `request`
- `response`
- `event`
- `stream_open`
- `stream_chunk`
- `stream_end`
- `session_open`
- `session_message`
- `session_close`
- `error`

Protocol-specific information is stored in a typed payload or namespaced metadata. The common envelope must not accumulate fields for every provider.

### 4. Adapter

Adapters connect protocol semantics to the Exchange contract.

Adapter roles:

- ingress adapter: protocol input to Exchange
- egress adapter: Exchange to protocol output
- bridge adapter: explicit semantic conversion between incompatible exchange kinds
- relay adapter: Exchange transport between vhttpd nodes

An adapter declares capabilities such as:

- request/response
- one-way events
- streaming input
- streaming output
- full duplex
- persistent sessions
- multiplexing
- cancellation
- backpressure
- replay or resume

### 5. Transform

A transform receives an Exchange and returns an action.

Transforms share one runtime contract regardless of implementation language. The initial backends are native V transformers registered by the vhttpd binary and VJSX transformers loaded by a VJSX engine. Pipelines reference transform resources and do not know which backend implements them.

Supported actions should include:

- `continue`: pass the updated exchange to the next stage
- `respond`: terminate the pipeline with a response
- `forward`: select or replace the egress target
- `fanout`: send to multiple targets under explicit aggregation policy
- `reject`: terminate with a classified error
- `drop`: acknowledge and intentionally discard a one-way event

VJSX is the primary programmable transform runtime. Native transforms may implement common gateway policies such as authentication, limits, cache, compression, and header normalization.

Both backends receive the same canonical Exchange, deadline, cancellation state, trace identity, scoped resource handles, and session/state facade. Both return the same normalized action contract. Switching an equivalent transform between native V and VJSX must not require changes to its pipeline, ingress, egress, or relay.

Native and VJSX process globals are not portable state. A transform intended to be interchangeable keeps shared or durable state in named resources such as session stores, caches, or databases.

Interchangeability applies to transformation logic, not transport ownership. For example:

- the Feishu long-lived connection and provider frame decoding belong to an adapter; Feishu event routing can be a native V transform
- the Paseo WebSocket carrier and relay channel lifecycle belong to the relay runtime; pairing and routing policy can be a VJSX transform

The initial switch mechanism is configuration plus an atomic RuntimePlan selection at startup. Runtime hot switching can be added later through atomic plan replacement, but only transforms whose state is externalized can switch without state loss.

### 6. Pipeline

A pipeline is a compiled route plan:

```text
match -> ingress -> transforms -> egress -> response mapping
```

The compiled plan owns no socket. It references registered adapters and transforms by ID.

Pipeline compilation validates:

- adapter existence
- exchange-kind compatibility
- required capabilities
- timeout and body/frame limits
- response mapping
- relay target existence
- transform availability

### 7. Relay

Relay is a logical protocol between vhttpd nodes. It is not synonymous with WebSocket.

Relay roles:

- hub: publicly reachable node accepting agent registrations and external ingress
- agent: usually private/local node maintaining an outbound connection to a hub

The first carrier can be WebSocket over TLS. The relay contract must remain independent enough to support another multiplexed carrier later.

Relay responsibilities:

- node registration and authentication
- target addressing
- logical channel multiplexing
- request/response correlation
- stream and duplex forwarding
- deadlines and cancellation
- bounded buffering and backpressure
- reconnect and session recovery policy
- affinity
- trace propagation
- lifecycle and traffic observation

Business routing and payload transformation remain outside the relay transport core.

## Target Configuration Model

The following syntax is directional. Exact field names may evolve while the configuration compiler is implemented.

### Local protocol pipeline

```toml
[adapters.backend_api]
kind = "http-upstream"
base_url = "http://127.0.0.1:9000"

[listeners.public]
protocol = "http"
transport = "tcp"
host = "0.0.0.0"
port = 8080

[transforms.api_policy]
kind = "vjsx"
handler = "gateway.api"

[[pipelines]]
id = "public_api"
match.path = ["/api/*"]
ingress = "listener:public"
transforms = ["transform:api_policy"]
egress = "adapter:backend_api"
```

### HTTP to MCP

```toml
[adapters.tools]
kind = "mcp"
endpoint = "internal:tools"

[listeners.public]
protocol = "http"
transport = "tcp"
host = "0.0.0.0"
port = 8080

[transforms.tools_translate]
kind = "vjsx"
handler = "tools.translate"

[[pipelines]]
id = "tool_gateway"
match.path = ["/tools/*"]
ingress = "listener:public"
transforms = ["transform:tools_translate"]
egress = "adapter:tools"
```

The VJSX transform performs the explicit HTTP-to-MCP semantic mapping. The core does not assume that every HTTP request can be forwarded to MCP.

### Public relay hub

```toml
[relays.edge]
mode = "hub"
carrier = "websocket"
path = "/_vhttpd/relay"

[listeners.public]
protocol = "http"
transport = "tcp"
host = "0.0.0.0"
port = 443

[transforms.feishu_route]
kind = "vjsx"
handler = "feishu.route"

[[pipelines]]
id = "feishu_public_callback"
match.path = ["/callbacks/feishu"]
ingress = "listener:public"
transforms = ["transform:feishu_route"]
egress = "relay:edge"
```

### Local relay agent

```toml
[relays.edge]
mode = "agent"
carrier = "websocket"
url = "wss://relay.example.com/_vhttpd/relay"
node_id = "office-mac"

[transforms.feishu_handle]
kind = "vjsx"
handler = "feishu.handle"

[[pipelines]]
id = "feishu_local_handler"
ingress = "relay:edge"
transforms = ["transform:feishu_handle"]
egress = "terminal:response"
```

## Paseo and Feishu Mapping

The existing Paseo relay validates the relay model:

- public vhttpd acts as hub
- local daemon/server acts as agent
- WebSocket is the carrier
- control and data sockets form logical relay channels
- `serverId` and `connectionId` provide addressing and affinity
- payloads remain opaque to the relay

Today, much of the relay session protocol lives in `examples/paseo-relay/app.mts`. During migration:

- registration, channels, correlation, reconnect, buffering, and backpressure move into the generic relay runtime
- VJSX keeps authorization, target selection, provider-specific routing, and optional payload transformation
- existing Paseo protocol compatibility remains covered by its current tests

Feishu is one ingress/provider using this relay. The relay core must not depend on Feishu message formats.

## Runtime Ownership

### `main.v`

Target responsibilities:

- App and veb Context declaration
- minimal veb route methods
- handoff to ingress adapter registry

It must not own:

- route matching implementation
- protocol dispatch policy
- WebSocket session bridge logic
- stream execution
- response cache policy
- relay session behavior
- provider-specific behavior

### `App`

The target `App` contains only veb integration and references to a small number of top-level runtime owners:

- data plane
- control plane
- process lifecycle

It must not expose every worker, provider, relay, cache, DB, WebSocket, and engine field directly. Moving the same state into nested `Hub` structs without moving lifecycle and behavior does not satisfy this boundary.

A runtime module is considered closed only when it owns:

- its compiled plan/spec
- mutable state and synchronization
- startup, warmup, drain, and close lifecycle
- public dispatch/capability interface
- metrics and admin snapshot
- focused tests

Cross-module access uses narrow capability interfaces. A transformer that needs state access receives state services; it does not receive the full App or a facade containing worker, Feishu, WebSocket, and admin methods.

### Protocol runtime

Suggested ownership:

```text
src/protocol/
    exchange.v
    capability.v
    adapter.v
    registry.v
    pipeline.v
    compiler.v
    error.v

src/protocol/http/
src/protocol/stream/
src/protocol/websocket/
src/protocol/mcp/

src/relay/
    protocol.v
    hub.v
    agent.v
    session.v
    channel.v
    carrier.v
```

The exact folders should follow V module constraints. The ownership boundaries are normative; directory names are not.

### Executor migration

The current `LogicExecutor` interface requires one implementation to expose HTTP, stream, MCP, WebSocket session, WebSocket event, and WebSocket upstream methods. This is too broad.

It should evolve into capability interfaces or registered handlers:

- HTTP handler
- stream handler
- session handler
- event handler
- MCP handler
- transform handler

PHP worker, PHP CGI, and VJSX then register only the capabilities they implement.

## Cross-Cutting Requirements

### Observability

Every log, event, adapter transition, worker call, upstream request, relay frame, and database operation must carry `trace_id` when associated with an exchange.

Required dimensions:

- exchange ID
- request ID
- trace ID
- pipeline ID
- ingress adapter
- transform IDs
- egress adapter
- relay node and channel IDs
- queue and execution durations
- byte/frame counts
- terminal status and error class

### Backpressure

Queues and buffers are bounded. Each pipeline declares or inherits limits for:

- body size
- frame size
- pending exchanges
- pending stream chunks
- relay channel buffer
- execution deadline

The runtime must reject, pause, or cancel according to adapter capability. It must not silently grow memory.

### Security

The runtime must support:

- TLS at public carriers
- relay node authentication
- route-level authentication transforms
- target allowlists
- bounded payloads
- metadata namespace isolation
- protection against trace/header spoofing
- secret redaction in logs and admin snapshots

### Failure model

Errors remain classified across adapter boundaries:

- configuration error
- authentication error
- route not found
- capability mismatch
- queue timeout
- execution timeout
- transport error
- upstream error
- relay unavailable
- relay target unavailable
- cancellation
- protocol violation

Adapters map classified errors to their protocol without losing the internal error class.

## Migration Plan

### Phase 1: establish boundaries without behavior changes

- move HTTP route matching and response cache policy out of `main.v`
- move WebSocket ingress/session handling out of `main.v`
- move HTTP dispatch and outcome rendering out of `main.v`
- keep existing tests and configuration behavior unchanged

Acceptance:

- `main.v` is limited to App/Context assembly and thin ingress methods
- WordPress, WebSocket, MCP, stream, OpenAI, and Paseo tests remain green

### Phase 2: introduce Exchange and capabilities

- add canonical Exchange types
- add adapter capability declarations
- add adapter registry
- adapt existing HTTP dispatch through the registry
- preserve current transport envelopes at worker boundaries

Acceptance:

- HTTP ingress and HTTP/PHP egress run through a compiled pipeline
- invalid adapter combinations fail during startup
- every transition preserves trace ID

### Phase 3: make VJSX a transform

- define the common transformer interface and action contract
- add native V and VJSX transformer backends
- expose Exchange to VJSX
- support continue/respond/forward/reject actions
- compile legacy VJSX executors into transform-plus-terminal-handler pipelines
- route upload completion events through the same transform queue model

Acceptance:

- VJSX can modify routing without owning transport lifecycle
- VJSX lane queues remain bounded and observable
- a pipeline can switch between equivalent native V and VJSX transforms without changing its definition
- shared conformance fixtures validate Exchange and action semantics across both backends

### Phase 4: migrate session and stream protocols

- implement stream adapter
- implement WebSocket session adapter
- implement MCP adapter
- add explicit bridge adapters where semantic conversion is required

Acceptance:

- no HTTP-specific branch is required to select MCP, WebSocket, or stream execution
- cancellation and backpressure work across the full pipeline

### Phase 5: generic relay runtime

- define relay wire contract and versioning
- implement hub and agent roles
- implement multiplexed logical channels
- add registration, authentication, correlation, deadlines, and reconnect policy
- migrate generic behavior out of Paseo VJSX code

Acceptance:

- public vhttpd can route an HTTP request to a selected local vhttpd and return the response
- stream and duplex exchange forwarding are covered by tests
- relay reconnects do not leak channels or lose terminal state silently
- Paseo compatibility tests remain green

### Phase 6: hardening and optimization

- zero-copy or bounded-copy paths where supported
- per-adapter queue tuning
- circuit breaking and health-aware target selection
- distributed trace export
- admin views for pipelines, adapters, relays, channels, and failures

## Validation Cases

### WordPress/WooCommerce

Validates:

- HTTP and HTTPS ingress
- static and dynamic route selection
- PHP worker and PHP CGI adapters
- cache and authentication-aware policies
- upload events
- database/cache runtime integration
- loopback concurrency

No WordPress-specific rule belongs in the pipeline core.

### Feishu through public relay

Validates:

- public HTTP or WebSocket ingress
- outbound-only local connectivity
- relay registration and target selection
- request/response correlation
- long-lived carrier recovery
- trace propagation across nodes

### Paseo

Validates:

- opaque bidirectional payload forwarding
- control and data channels
- multiplexing and affinity
- bounded pending frames
- reconnect semantics

### MCP and AI streaming

Validates:

- semantic bridge transforms
- stream lifecycle and cancellation
- upstream selection
- backpressure
- long-running exchange observation

## Architectural Invariants

The refactor must preserve these rules:

1. Protocol-specific code does not enter the pipeline core.
2. Carrier code does not interpret application payloads.
3. Relay code does not depend on Feishu, Paseo, WordPress, or PHP.
4. VJSX does not own network connection lifecycle.
5. Every exchange has a trace ID before leaving ingress.
6. Every queue and buffer is bounded.
7. Legacy configuration is translated at one compatibility boundary.
8. Unsupported protocol combinations fail at startup, not during traffic.
9. `main.v` remains a thin adapter to veb rather than the data-plane implementation.
10. New application integrations extend configuration, transforms, or adapters instead of adding route-specific branches to the core.
11. Native V and VJSX transforms implement the same Exchange-to-action contract and are interchangeable at the pipeline boundary.
12. `App` remains a composition root; every subsystem owns its state, lifecycle, synchronization, behavior, and snapshot as one closed module.

## Related Documents

- [PROTOCOL_PIPELINE_IMPLEMENTATION_PLAN.md](PROTOCOL_PIPELINE_IMPLEMENTATION_PLAN.md)
- [CONFIGURATION_MODEL_V2.md](CONFIGURATION_MODEL_V2.md)
- [ARCHITECTURE_REFACTOR_BASELINE.md](ARCHITECTURE_REFACTOR_BASELINE.md)
- [PASEO_RELAY_VHTTPD_PLAN.md](PASEO_RELAY_VHTTPD_PLAN.md)
- [transport_contract.md](transport_contract.md)
- [OVERVIEW.md](OVERVIEW.md)
- [EXECUTOR_MODES.md](EXECUTOR_MODES.md)
- [STREAM_RUNTIME_PHASES.md](STREAM_RUNTIME_PHASES.md)
- [MCP.md](MCP.md)
