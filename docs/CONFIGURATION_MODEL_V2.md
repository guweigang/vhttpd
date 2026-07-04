# vhttpd Configuration Model V2

Status: target configuration architecture

This document defines the configuration model that accompanies the protocol pipeline and relay architecture.

The primary goal is consistency. New features must fit an existing resource category instead of adding another unrelated top-level table or another special field to `routes`.

## Problems in the Current Configuration

The current TOML grew with the implementation and now mixes several concepts:

- `server`, `listener`, and `site` can all define host and port
- `site` combines filesystem root, application identity, listener, and executor defaults
- `executor` may mean PHP worker, PHP CGI, VJSX, static files, upload handling, or blocking
- route fields contain cache, security, upload, rewrite, response, and application compatibility behavior
- protocol/provider configuration appears in unrelated top-level tables such as `mcp`, `openai`, `feishu`, and WebSocket-specific site fields
- application examples duplicate environment values that vhttpd already knows, including scheme and service sockets

This makes each new capability look like a patch to the schema.

## Design Rules

### One concept has one home

V2 uses these top-level configuration domains:

- `server`: process-wide behavior
- `listeners`: network bind and TLS termination
- `control`: admin and internal control-plane exposure
- `observability`: logs, events, metrics, and tracing export
- `resources`: shared DB, cache, storage, secrets, and similar infrastructure
- `engines`: execution runtimes such as PHP worker, PHP CGI, and VJSX
- `adapters`: application protocol ingress/egress implementations
- `transforms`: programmable or native exchange transformations
- `policies`: reusable limits, cache, security, and response behavior
- `pipelines`: matching and ordered data flow
- `relays`: cross-node relay endpoints

Provider-specific settings live inside a named adapter, transform, or resource. They do not create new top-level categories.

## Complete Concept Inventory

The V2 schema has one metadata field and eleven stable configuration domains.

| Concept | User declares | Compiled plan | Runtime owner |
|---|---|---|---|
| `version` | schema version | decoder/compiler selection | none |
| `server` | timezone, PID, shutdown/process defaults | `ServerPlan` | `ProcessLifecycle` |
| `listeners` | protocol, transport, bind, TLS | `ListenerPlan` | ingress/data-plane runtime |
| `control` | admin/internal endpoints and authorization | `ControlPlan` | `ControlPlaneRuntime` |
| `observability` | event log, log level, metrics/tracing exporters | `ObservabilityPlan` | observability runtime |
| `resources` | DB, cache, storage, secret providers | `ResourcePlan` | `ResourceRuntime` |
| `engines` | PHP worker/CGI, VJSX, pools, queues, capabilities | `EnginePlan` | `EngineRuntime` |
| `adapters` | protocol/provider/static/upload/upstream endpoints | `AdapterPlan` | adapter/provider runtimes |
| `transforms` | native V or VJSX Exchange logic | `TransformPlan` | `TransformerRegistry` |
| `policies` | cache, limits, security, retry, concurrency | `PolicyPlan` | pipeline/protocol runtimes |
| `pipelines` | ingress match, ordered transforms, egress | `PipelinePlan` | `PipelineRuntime` |
| `relays` | hub/agent, carrier, auth, channel limits | `RelayPlan` | `RelayRuntime` |

These domains are the complete top-level vocabulary for V2. Adding another top-level domain requires an architecture decision, not a feature-local parser patch.

### What belongs in config

A concept belongs in config when operators need to deploy, select, connect, secure, limit, or tune it. Examples:

- listener address and certificate
- engine implementation and pool size
- adapter endpoint and timeout
- transformer backend selection
- pipeline ordering
- relay authentication and channel bounds
- DB/cache/storage connection details
- queue limits and retry policy
- observability exporters

### What does not belong in config

Runtime implementation objects are not TOML concepts:

- Exchange and TransformAction instances
- accepted sockets and active connections
- selected worker socket
- VJSX lane objects
- live queues, locks, counters, and maps
- active MCP/WebSocket/relay sessions
- request, trace, channel, and span IDs
- runtime snapshots and current metric values

Config defines limits and desired behavior for these objects. Runtime modules create and own the objects themselves.

### Config implements specs, not behavior

Every stable configuration domain has decoder structs, normalization, reference resolution, validation, and plan compilation in the config/plan layers. Protocol, engine, transformer, resource, and relay behavior remains in their runtime modules.

```text
TOML concept
  -> config decode spec
  -> normalized plan spec
  -> validated RuntimePlan
  -> closed runtime module instance
```

The config module must never become the runtime implementation of a concept.

### V2 root decode model

The V implementation mirrors the complete vocabulary explicitly:

```v
pub struct V2Config {
pub:
    version       int
    server        ServerSpec
    listeners     map[string]ListenerSpec
    control       ControlSpec
    observability ObservabilitySpec
    resources     ResourceSpecs
    engines       map[string]EngineSpec
    adapters      map[string]AdapterSpec
    transforms    map[string]TransformSpec
    policies      PolicySpecs
    pipelines     []PipelineSpec
    relays        map[string]RelaySpec
}
```

`ResourceSpecs` and `PolicySpecs` preserve their meaningful subcategories, for example DB/cache/storage and cache/limits/security/concurrency. Kind-specific decoders validate only fields owned by that kind.

The root model contains no `site`, provider, plugin, PHP, VJSX, OpenAI, Feishu, MCP, or WordPress field. Those are represented through stable resource kinds below the root domains.

## V1 to V2 Concept Mapping

| Current V1 concept | V2 destination |
|---|---|
| `[server].host/port/ssl` | `listeners` |
| `[server].index` | HTTP handler adapter |
| `[files].pid_file` | `server.pid_file` |
| `[files].event_log` | `observability.event_log` |
| `[runtime].timezone` | `server.timezone` |
| `[paths]` | compiler path resolution; no runtime resource |
| `[admin]` | `control` plus a listener reference |
| `[worker]` | engine pool/queue/lifecycle fields |
| `[executor]`, `[executors.*]` | `engines` plus adapters where needed |
| `[php]`, `[vjsx]` | engine-kind configuration |
| `[plugins.*]` | transform or adapter backed by an engine |
| `[assets]` | static adapter plus cache policy |
| `[db]`, `[cache]` | `resources` |
| `[mcp]` | MCP adapter and session/limit policies |
| `[feishu]`, `[feishu.apps.*]` | Feishu provider adapter/resources/transforms |
| `[feishu.bridge]`, `[bridge]` | relay plus routing/auth transforms |
| `[codex]` | Codex provider adapter and policies |
| `[openai]`, backends, model routes | OpenAI adapters and routing transforms/pipelines |
| `websocket_affinity` | concurrency/affinity policy |
| `websocket_actor` | keyed concurrency policy |
| `[site]`, `[sites.*]` | listener + adapters + pipelines; no V2 site object |
| `[[routes]]` | `[[pipelines]]` plus referenced policies/adapters/transforms |
| route `executor = "static/upload/none"` | static/upload adapter or reject transform |

The compatibility compiler owns this table in code. Runtime modules see only V2 plans.

### Configuration is compiled

The TOML decoder produces a declarative config model. A configuration compiler then resolves references and creates one immutable `RuntimePlan`.

Runtime code consumes the compiled plan. It must not repeatedly interpret raw TOML fields or infer behavior from magic strings.

### References replace duplication

Resources are named once and referenced by ID. PHP worker and PHP CGI may reference the same DB/cache resources without duplicating socket variables.

### Defaults are visible and deterministic

Defaults belong to the compiler and are inspectable through the admin plane. A generated runtime-plan view should show all resolved values.

### New examples use only V2 syntax

Legacy syntax remains supported during migration, but new examples and tests must not mix V1 and V2 concepts in one configuration.

## Versioning

V2 configurations declare their schema:

```toml
version = 2
```

Rules:

- no version means legacy/V1 during the compatibility period
- `version = 2` enables strict V2 validation
- unknown V2 fields are errors
- deprecated aliases are not accepted in strict V2
- additive fields may be introduced within V2
- semantic changes require a later version

## Resource Model

### Server

`server` contains process-level defaults only:

```toml
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "tmp/vhttpd.pid"
shutdown_timeout_ms = 10000

[observability]
event_log = "tmp/vhttpd.events.ndjson"
log_level = "info"
```

Host, port, and TLS do not belong here because they describe listeners.

### Control plane

Control-plane configuration references a listener and defines authorization. It does not duplicate bind/TLS fields:

```toml
[listeners.admin]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 20001

[control]
listener = "listener:admin"
token = "${env.VHTTPD_ADMIN_TOKEN}"
internal_socket = "tmp/vhttpd-admin.sock"
```

### Observability

Observability is process-wide configuration with optional per-pipeline overrides through policies:

```toml
[observability]
event_log = "tmp/vhttpd.events.ndjson"
log_level = "info"

[observability.tracing]
enabled = true
exporter = "otlp-http"
endpoint = "http://127.0.0.1:4318"
sample_rate = 1.0
```

### Listeners

Listeners terminate network carriers and select one or more ingress pipelines:

```toml
[listeners.public]
protocol = "http"
transport = "tcp"
host = "0.0.0.0"
port = 443

[listeners.public.tls]
cert = "server.crt"
cert_key = "server.key"
```

Another listener may expose relay traffic without creating another site abstraction:

```toml
[listeners.relay]
protocol = "http"
transport = "tcp"
host = "0.0.0.0"
port = 8443
```

### Multi-site and virtual hosts

V2 represents a site as composition, not as another runtime owner. Multiple HTTP sites can share one listener and select pipelines by host:

```toml
[listeners.web]
protocol = "http"
transport = "tcp"
host = "0.0.0.0"
port = 443

[listeners.web.tls]
certificates = [
  { hosts = ["shop.example.com"], cert = "certs/shop.crt", cert_key = "certs/shop.key" },
  { hosts = ["blog.example.com"], cert = "certs/blog.crt", cert_key = "certs/blog.key" },
]

[resources.db.shop]
kind = "mysql"
database = "shop"

[resources.db.blog]
kind = "mysql"
database = "blog"

[engines.shop_php]
kind = "php-worker"
app = "./shop/app.php"
resources = ["resource:db/shop"]

[engines.blog_php]
kind = "php-worker"
app = "./blog/app.php"
resources = ["resource:db/blog"]

[adapters.shop]
kind = "http-handler"
engine = "engine:shop_php"
document_root = "/srv/shop"

[adapters.blog]
kind = "http-handler"
engine = "engine:blog_php"
document_root = "/srv/blog"

[[pipelines]]
id = "shop"
group = "site:shop"
ingress = "listener:web"
match.hosts = ["shop.example.com"]
match.paths = ["*"]
egress = "adapter:shop"

[[pipelines]]
id = "blog"
group = "site:blog"
ingress = "listener:web"
match.hosts = ["blog.example.com"]
match.paths = ["*"]
egress = "adapter:blog"
```

Different-port sites use different listeners and reference those listeners from their pipelines. Sites may share an engine, DB, cache, transform, or policy by referencing the same resource, or isolate them with separate IDs.

`group = "site:<name>"` is an operational label used for admin views, metrics, and diagnostics. It does not create a mutable Site runtime or change dispatch semantics.

Host matching is part of the HTTP ingress match schema. Other protocols use selectors appropriate to their ingress, such as relay node, MCP endpoint, WebSocket path, or Exchange metadata.

The V1 `[sites.*]` shorthand remains supported by the compatibility compiler. It expands into listeners, adapters, engines, resources, and ordered pipelines. A future V2 authoring shorthand is acceptable only if it compiles to the same resources and does not introduce a second runtime model.

Multi-certificate SNI is a listener capability and must be validated against the selected TLS transport. Until that capability is implemented, deployments use one default/wildcard certificate per listener or separate listener addresses. The compiler must not silently accept an unsupported certificate set.

### Resources

Resources are reusable infrastructure dependencies:

```toml
[resources.db.wordpress]
kind = "mysql"
host = "127.0.0.1"
port = 3306
database = "wordpress"
username = "root"
password = "${env.WORDPRESS_DB_PASSWORD}"
pool_size = 5
idle_ping_ms = 300000
init_sql = ["SET NAMES utf8mb4"]

[resources.cache.wordpress]
kind = "memory"
socket = "/tmp/vhttpd_wp_cache.sock"

[resources.storage.uploads]
kind = "filesystem"
root = "/tmp/vhttpd-wordpress-uploads"
```

Resource kind owns its schema. MySQL-only fields cannot appear on a cache resource.

### Engines

Engines execute application logic. They do not define public routes:

```toml
[engines.wordpress]
kind = "php-worker"
entry = "./vendor/bin/vphp-worker"
app = "./app.php"
pool_size = 4
queue_capacity = 64
queue_timeout_ms = 10000
resources = ["resource:db/wordpress", "resource:cache/wordpress"]

[engines.wordpress_cgi]
kind = "php-cgi"
binary = "php-cgi"
pool_size = 4
queue_capacity = 64
queue_timeout_ms = 10000
resources = ["resource:db/wordpress", "resource:cache/wordpress"]

[engines.gateway_logic]
kind = "vjsx"
entry = "./gateway.mts"
module_root = "."
thread_count = 2
```

The compiler injects standard resource and request environment values. Users should not repeat values such as `VHTTPD_SCHEME`, DB sockets, or cache sockets unless explicitly overriding a supported setting.

### Adapters

Adapters connect application protocol semantics to engines, upstreams, static storage, uploads, or relay endpoints.

PHP application adapter:

```toml
[adapters.wordpress]
kind = "http-handler"
engine = "engine:wordpress"
document_root = "/srv/wordpress"
index = "index.php"
```

PHP CGI adapter:

```toml
[adapters.wordpress_cgi]
kind = "http-handler"
engine = "engine:wordpress_cgi"
document_root = "/srv/wordpress"
index = "index.php"
```

Static adapter:

```toml
[adapters.wordpress_assets]
kind = "static"
root = "/srv/wordpress"
```

Upload adapter:

```toml
[adapters.wordpress_uploads]
kind = "upload"
storage = "resource:storage/uploads"
max_body_bytes = 536870912
completed_pipeline = "upload_completed"
```

HTTP upstream adapter:

```toml
[adapters.backend_api]
kind = "http-upstream"
base_url = "http://127.0.0.1:9000"
timeout_ms = 30000
```

Provider-specific adapters remain namespaced resources:

```toml
[adapters.feishu_events]
kind = "feishu-events"
app_id = "${env.FEISHU_APP_ID}"
app_secret = "${env.FEISHU_APP_SECRET}"
open_base_url = "https://open.feishu.cn/open-apis"
```

```toml
[adapters.openai]
kind = "openai-http"
base_url = "https://api.openai.com/v1"
api_key = "${env.OPENAI_API_KEY}"
```

This avoids new global `[feishu]` or `[openai]` schemas.

Provider runtimes that maintain outbound/native protocol connections keep the transport protocol on the runtime spec and expose business hooks as method names on one plugin module:

```toml
[providers.feishu.runtime]
driver = "native"
protocol = "websocket"
plugin = "feishu-provider-hooks"
engine = "engine:provider-events"

[providers.feishu.hooks]
handshake = "handshake"
normalize = "normalize"
```

The native runtime owns connection lifecycle, reconnects, and frame IO. The VJSX plugin owns business-level handshakes and event normalization by exporting matching functions from the same module, for example `export function handshake(ctx)` and `export function normalize(ctx)`. Hook values are method names, not separate plugin identifiers or dotted capability names.

### Transforms

Transforms operate on Exchanges:

```toml
[transforms.feishu]
kind = "native"
handler = "feishu.events"
```

The same transform resource can select a VJSX implementation:

```toml
[transforms.feishu]
kind = "vjsx"
engine = "engine:gateway_logic"
handler = "feishu.events"
```

In both cases the pipeline remains unchanged:

```toml
[[pipelines]]
id = "feishu_events"
ingress = "adapter:feishu_events"
transforms = ["transform:feishu"]
egress = "relay:edge"
```

Another VJSX transform can use the same engine:

```toml
[transforms.gateway]
kind = "vjsx"
engine = "engine:gateway_logic"
handler = "gateway.handle"
```

Common policies should use reusable native transforms rather than adding fields to every pipeline.

Native V and VJSX are implementation backends of one transform contract. They receive the same canonical Exchange and return the same normalized action. Strict V2 validation checks that the selected backend declares every capability required by the pipeline.

Backend selection is resolved while compiling the RuntimePlan. Changing `kind = "native"` to `kind = "vjsx"` and supplying its engine is sufficient; no pipeline edit is required. A future admin-plane hot switch uses the same resource boundary and atomically replaces the compiled plan.

### Pipelines

Pipelines contain only matching, ordered processing, and terminal routing:

```toml
[[pipelines]]
id = "wordpress_assets"
ingress = "listener:public"
match.methods = ["GET", "HEAD"]
match.paths = ["*.css", "*.js", "*.png", "/wp-content/*", "/wp-includes/*"]
egress = "adapter:wordpress_assets"
policies = ["policy:cache/immutable_assets"]
```

```toml
[[pipelines]]
id = "wordpress_http"
ingress = "listener:public"
match.paths = ["*"]
transforms = ["transform:gateway"]
egress = "adapter:wordpress"
```

```toml
[[pipelines]]
id = "wordpress_compat"
ingress = "listener:public"
match.paths = ["/wp-admin/*", "/wp-login.php", "/wp-cron.php"]
egress = "adapter:wordpress_cgi"
```

Pipeline declaration order is preserved per ingress source and is the default first-match order. The compiler rejects duplicate IDs, unresolved references, impossible exchange conversions, and ambiguous terminal routes when strict matching cannot resolve them. The compiled RuntimePlan stores an ordered pipeline list plus derived lookup indexes.

Static, upload, deny, and fixed responses are adapters or transforms. They are not magic executor names.

### Policies

Frequently reused limits and HTTP behavior should be named policies:

```toml
[policies.cache.immutable_assets]
cache_control = "public, max-age=31536000, immutable"

[policies.cache.private]
cache_control = "private, no-store"

[policies.limits.api]
max_body_bytes = 1048576
timeout_ms = 30000
```

Pipelines reference policies instead of repeating groups of fields. Adapter-specific limits remain on the adapter when they are part of the adapter contract.

### Relays

Relay endpoints are first-class cross-node resources:

```toml
[relays.edge]
mode = "hub"
carrier = "websocket"
listener = "listener:public"
path = "/_vhttpd/relay"
auth = "transform:relay_auth"
max_channels = 10000
channel_buffer = 128
```

Agent configuration:

```toml
[relays.edge]
mode = "agent"
carrier = "websocket"
url = "wss://relay.example.com/_vhttpd/relay"
node_id = "office-mac"
token = "${env.VHTTPD_RELAY_TOKEN}"
reconnect_delay_ms = 3000
autostart = true
```

Pipelines use `relay:edge` as ingress or egress. WebSocket remains the carrier and does not leak into application pipeline semantics. Agent relays are inert by default; `autostart = true` opts an agent into dialing the hub during server startup.

## Complete WordPress Shape

The target WordPress configuration should read as composition rather than a long ordered patch list:

```toml
version = 2

[server]
timezone = "Asia/Shanghai"
pid_file = "tmp/wordpress.pid"

[observability]
event_log = "tmp/wordpress.events.ndjson"
log_level = "info"

[listeners.wordpress]
protocol = "http"
transport = "tcp"
host = "127.0.0.1"
port = 8080

[listeners.wordpress.tls]
cert = "server.crt"
cert_key = "server.key"

[resources.db.wordpress]
kind = "mysql"
host = "127.0.0.1"
database = "wordpress"
username = "root"
password = "${env.WORDPRESS_DB_PASSWORD}"
pool_size = 5
idle_ping_ms = 300000
init_sql = ["SET NAMES utf8mb4"]

[resources.cache.wordpress]
kind = "memory"

[resources.storage.uploads]
kind = "filesystem"
root = "/tmp/vhttpd-wordpress-uploads"

[engines.wordpress]
kind = "php-worker"
entry = "./vendor/bin/vphp-worker"
app = "./app.php"
pool_size = 4
resources = ["resource:db/wordpress", "resource:cache/wordpress"]

[engines.wordpress_cgi]
kind = "php-cgi"
binary = "php-cgi"
pool_size = 4
resources = ["resource:db/wordpress", "resource:cache/wordpress"]

[engines.wordpress_events]
kind = "vjsx"
entry = "./upload-events.mts"

[adapters.wordpress]
kind = "http-handler"
engine = "engine:wordpress"
document_root = "/srv/wordpress"
index = "index.php"

[adapters.wordpress_cgi]
kind = "http-handler"
engine = "engine:wordpress_cgi"
document_root = "/srv/wordpress"
index = "index.php"

[adapters.assets]
kind = "static"
root = "/srv/wordpress"

[adapters.uploads]
kind = "upload"
storage = "resource:storage/uploads"
completed_pipeline = "pipeline:upload_completed"

[adapters.upload_events]
kind = "event-ingress"
topic = "upload.completed"

[transforms.upload_completed]
kind = "vjsx"
engine = "engine:wordpress_events"
handler = "wordpress.upload.completed"

[transforms.rest_rewrite]
kind = "native"
handler = "http.rewrite"
target = "/index.php?rest_route=$path_remainder"
strip_prefix = "/wp-json"

[[pipelines]]
id = "uploads"
ingress = "listener:wordpress"
match.methods = ["POST", "PUT"]
match.paths = ["/vhttpd/uploads", "/vhttpd/uploads/*"]
egress = "adapter:uploads"

[[pipelines]]
id = "assets"
ingress = "listener:wordpress"
match.methods = ["GET", "HEAD"]
match.paths = ["*.css", "*.js", "*.png", "/wp-content/*", "/wp-includes/*"]
egress = "adapter:assets"
policies = ["policy:cache/immutable_assets"]

[[pipelines]]
id = "rest_api"
ingress = "listener:wordpress"
match.paths = ["/wp-json", "/wp-json/*"]
transforms = ["transform:rest_rewrite"]
egress = "adapter:wordpress_cgi"

[[pipelines]]
id = "compat"
ingress = "listener:wordpress"
match.paths = ["/wp-admin/*", "/wp-login.php", "/wp-cron.php"]
egress = "adapter:wordpress_cgi"

[[pipelines]]
id = "wordpress"
ingress = "listener:wordpress"
match.paths = ["*"]
egress = "adapter:wordpress"

[[pipelines]]
id = "upload_completed"
ingress = "adapter:upload_events"
transforms = ["transform:upload_completed"]
egress = "terminal:ack"
```

## Compatibility Compiler

Legacy configuration is isolated in one compatibility layer:

```text
V1 TOML
  -> V1 decoder
  -> compatibility compiler
  -> V2 declarative resources
  -> RuntimePlan compiler

V2 TOML
  -> V2 decoder
  -> RuntimePlan compiler
```

Translation examples:

- `[server].host/port` becomes an implicit listener
- `[site]` becomes adapter defaults plus filesystem settings
- `[executors.<id>]` becomes `[engines.<id>]` and a compatible handler adapter
- `routes.executor = "static"` becomes a static adapter reference
- `routes.executor = "upload"` becomes an upload adapter reference
- `routes.executor = "none"` becomes a reject transform
- `routes.status/body/location` becomes a fixed-response adapter
- `routes.on_completed` becomes an event pipeline
- `[openai.backends]` becomes named adapters
- `[feishu]` becomes a provider adapter and optional transforms

The compatibility compiler is the only place allowed to know these legacy meanings.

## Validation and Diagnostics

V2 startup errors include the full resource path:

```text
pipelines.wordpress_http.egress: adapter "wordpress" was not found
```

```text
pipelines.tool_gateway: ingress exchange "request" is incompatible with MCP egress; add an explicit bridge transform
```

The admin plane should expose:

- decoded config version
- compiled listeners
- compiled pipelines in evaluation order
- resolved adapter and transform references
- effective defaults and policies
- compatibility translations and deprecation warnings
- redacted resource configuration

## Migration Sequence

1. Define V2 config structs independently from current runtime structs.
2. Define `RuntimePlan` as the only runtime input.
3. Make existing V1 config compile into `RuntimePlan` without behavior changes.
4. Add strict V2 decoding and validation.
5. Convert small examples to V2 first.
6. Convert WordPress and Paseo only after adapter and relay resources exist.
7. Remove direct runtime reads of V1 config fields.
8. Keep V1 support for a documented compatibility window.

## Configuration Invariants

1. A top-level table represents one stable resource category.
2. Provider names do not become new top-level schemas.
3. Pipelines reference named resources instead of embedding runtime configuration.
4. Engines do not define public routes.
5. Adapters do not own application policy.
6. Transforms do not own sockets.
7. Relays do not interpret provider payloads.
8. Strict V2 rejects unknown fields and unresolved references.
9. Runtime code consumes only a compiled `RuntimePlan`.
10. New features extend a resource-kind schema or add a new adapter, not an unrelated route flag.
11. Native V and VJSX transforms are interchangeable implementations; pipelines never branch on implementation language.

## Related Documents

- [PROTOCOL_PIPELINE_IMPLEMENTATION_PLAN.md](PROTOCOL_PIPELINE_IMPLEMENTATION_PLAN.md)
- [PROTOCOL_PIPELINE_RELAY_ARCHITECTURE.md](PROTOCOL_PIPELINE_RELAY_ARCHITECTURE.md)
- [SITE_CONFIG_DSL.md](SITE_CONFIG_DSL.md)
- [ARCHITECTURE_REFACTOR_BASELINE.md](ARCHITECTURE_REFACTOR_BASELINE.md)
- [transport_contract.md](transport_contract.md)
