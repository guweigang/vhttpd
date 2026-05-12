# vhttpd Article Series

This directory collects public-facing articles for introducing and promoting
`vhttpd`.

The core positioning:

> vhttpd is a lightweight transport runtime for PHP, TypeScript, AI streaming,
> WebSocket, SSE, and MCP applications.

In Chinese:

> vhttpd 是面向 PHP / TypeScript / AI 应用的高性能 transport runtime。

## Narrative

The series should avoid presenting `vhttpd` as "just another HTTP server".
The stronger message is that modern applications are no longer only classic
request/response systems. They often need HTTP, WebSocket, SSE, upstream token
streams, MCP Streamable HTTP, bot integrations, PHP business logic, and
TypeScript protocol glue code in the same product surface.

`vhttpd` sits between protocol ingress and application logic:

- It terminates HTTP, WebSocket, stream, and MCP-facing connections.
- It runs PHP applications through external workers.
- It runs TypeScript/JavaScript logic through embedded `vjsx` executors.
- It can be used as a plugin-oriented gateway layer for fast-changing protocol
  and AI integration logic.
- It exposes admin/runtime surfaces for worker state, queue state, active
  upstreams, MCP sessions, and related runtime counters.

## Series Plan

1. `01-overview.md`
   - Introduce the product definition.
   - Explain why `vhttpd` is a transport runtime instead of only an HTTP server.
   - Introduce PHP workers, `vjsx` plugins, WebSocket/stream/MCP surfaces, and
     runtime observability.

2. `02-v-runtime-foundation.md`
   - Focus on V, `veb`, single binary deployment, worker pool, queue, timeout,
     restart/backoff, DB support, admin stats, config, and production operations.
   - This article should include benchmark data once available.

3. `03-php-runtime.md`
   - Explain how `vhttpd` complements PHP instead of replacing it.
   - Cover Laravel, Symfony, WordPress, Feishu PHP examples, streaming, worker
     lifecycle, and PHP-FPM limitations around long-lived streams.

4. `04-vjsx-plugin-layer.md`
   - Present `vjsx` as both an embedded executor and a TypeScript/JavaScript
     plugin layer.
   - Cover gateway logic, bot adapters, OpenAI-compatible plugins, Ollama proxy,
     DashScope coding plugin, and Paseo relay style use cases.

5. `05-websocket-stream-mcp.md`
   - Explain the common runtime model for WebSocket, SSE, text stream, upstream
     token stream, MCP Streamable HTTP, Feishu WebSocket upstream, OpenAI gateway,
     Ollama proxy, and Paseo relay.

6. `06-market-positioning.md`
   - Compare with adjacent products without pretending the market is empty.
   - Main references: FrankenPHP, RoadRunner, Swoole/OpenSwoole, Laravel Octane,
     LiteLLM Proxy, Envoy AI Gateway.

## Positioning Against Existing Products

There are already mature adjacent products:

- FrankenPHP: modern PHP application server built on Caddy, with worker mode,
  Laravel/Symfony integrations, real-time features, metrics, HTTP/2, HTTP/3,
  and automatic HTTPS.
- RoadRunner: Go-based PHP application server and process manager with worker
  pools and a plugin ecosystem.
- Swoole/OpenSwoole: PHP extension-based async/coroutine networking runtime.
- Laravel Octane: Laravel integration layer for high-performance app servers
  such as FrankenPHP, RoadRunner, Swoole, and OpenSwoole.
- LiteLLM Proxy: OpenAI-compatible LLM gateway for many model providers.
- Envoy AI Gateway: cloud-native AI/MCP gateway built around Envoy and
  Kubernetes-style production traffic management.

The safer and stronger claim is not "nobody else does this".

The better claim:

> Existing products solve PHP worker runtimes, WebSocket, AI gateways, and MCP
> gateways separately. vhttpd's opportunity is to combine PHP workers,
> TypeScript plugins, WebSocket upstreams, SSE/MCP/AI streams, and runtime
> observability into one lightweight transport runtime.

## Proof Points To Add

Before publishing performance-heavy claims, collect real data:

- Plain HTTP RPS and latency.
- PHP worker RPS and latency.
- First-token latency for SSE or text streaming.
- WebSocket concurrent connection count.
- Worker pool queue behavior under pressure.
- Memory footprint.
- Binary size and startup time.

Prefer concrete tables over vague claims such as "very fast".
