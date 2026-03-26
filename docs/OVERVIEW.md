# vhttpd Overview

这页是面向官网和文档首页的总览页。

如果只想先回答 4 个问题：

- `vhttpd` 是什么？
- 它支持哪些运行面？
- PHP worker 需要返回什么？
- 常用 data plane / admin plane path 有哪些？

先看这页就够了。

## Product Definition

结构体关系总览图请看：

- [STRUCT_RELATIONSHIP_MAP.md](/Users/guweigang/Source/vhttpd/docs/STRUCT_RELATIONSHIP_MAP.md)
- [FEISHU_RUNTIME_COMPATIBILITY_PLAN.md](/Users/guweigang/Source/vhttpd/docs/FEISHU_RUNTIME_COMPATIBILITY_PLAN.md)

`vhttpd` 不是业务框架，也不只是一个给 PHP 跑页面的 HTTP server。

更准确地说，它是一个面向 PHP 应用的 runtime gateway：

- 终止 HTTP / WebSocket / stream 连接
- 调度外部 worker
- 承载 streaming / upstream execution / MCP runtime
- 暴露 runtime state 和 admin plane

一句话定义：

- `vhttpd` = PHP 应用的 transport/runtime layer

## Runtime Model

`vhttpd` 现在统一按两层语义理解：

### 1. Surface

一级概念只表达运行面：

- `http`
- `stream`
- `websocket`
- `mcp`
- `websocket_upstream`

### 2. Surface-specific fields

二级概念表达具体怎么跑：

- `stream.strategy`
  - `direct`
  - `dispatch`
  - `upstream_plan`
- `stream.output`
  - `text`
  - `sse`
- `websocket_upstream.provider`
  - `feishu`

这套命名的意思是：

- Feishu 长连接接入是 `websocket_upstream`
- Ollama 这类上游流执行是 `stream + upstream_plan`
- MCP 保持独立一级 surface，不降成 `stream` 的一个 provider

## Capability Map

| Surface | Subtype | What it means |
|---|---|---|
| `http` | - | 普通 request/response |
| `stream` | `direct` | worker 直接持有流并输出 chunk |
| `stream` | `dispatch` | `vhttpd` 持有下游连接，worker 处理 `open/next/close` |
| `stream` | `upstream_plan` | worker 返回 plan，`vhttpd` 自己连接上游并出流 |
| `websocket` | phase 1 / dispatch | websocket handler / websocket dispatch |
| `mcp` | Streamable HTTP | `POST /mcp`、`GET /mcp`、`DELETE /mcp` |
| `websocket_upstream` | `provider=feishu` | `vhttpd` 主动连上游 websocket provider 并接收入站事件 |

## PHP Worker Bootstrap Keys

`php-worker` 当前识别的 bootstrap array key 是：

- `http`
- `websocket`
- `stream`
- `mcp`
- `websocket_upstream`

典型写法：

```php
<?php

return [
    'http' => $httpApp,
    'websocket' => $websocketApp,
    'stream' => $streamApp,
    'mcp' => $mcpApp,
    'websocket_upstream' => $upstreamApp,
];
```

如果直接返回一个 dispatchable object，`PhpWorker\Server` 也会识别：

- 扩展侧 `VSlim\*`
- pure PHP package 侧 `VPhp\VSlim\*`
- 带 `VPhp\VHttpd\Attribute\Dispatchable` 的类

## PHP Worker Request/Response Shapes

### One-shot HTTP

普通 HTTP worker response 仍然是：

- `status`
- `headers`
- `body`

### Stream

stream wire mode 统一是：

- `mode = stream`

phase 1 direct stream：

- `strategy = direct`
- `event = start|chunk|error|end`

phase 2 dispatch stream：

- `mode = stream`
- `strategy = dispatch`

phase 3 upstream plan：

- `mode = stream`
- `strategy = upstream_plan`

### MCP

MCP worker request：

- `mode = mcp`

### WebSocket Upstream

websocket upstream worker request：

- `mode = websocket_upstream`
- `provider = feishu`

更细的 wire contract 见：

- [transport_contract.md](/Users/guweigang/Source/vhttpd/docs/transport_contract.md)

## Data Plane Paths

### HTTP

普通 HTTP path 由应用自己定义。

比如：

- `/`
- `/users/:id`
- `/api/chat`

### WebSocket

WebSocket upgrade path 也由应用自己定义。

常见示例是：

- `/ws`

扩展侧通常通过：

- `VSlim\App::websocket('/ws', $handler)`

来注册。

### MCP

当前 `vhttpd` 内建 MCP Streamable HTTP path：

- `POST /mcp`
- `GET /mcp`
- `DELETE /mcp`

## Admin Plane Paths

### Runtime summary

- `GET /admin/runtime`
- `GET /admin/runtime/upstreams`
- `GET /admin/runtime/websockets`
- `GET /admin/runtime/mcp`

### Worker operations

- `GET /admin/workers`
- `GET /admin/stats`
- `POST /admin/workers/restart`
- `POST /admin/workers/restart/all`

### WebSocket upstream runtime

- `GET /admin/runtime/upstreams/websocket`
- `GET /admin/runtime/upstreams/websocket/events`
- `GET /admin/runtime/upstreams/websocket/activities`
- `POST /admin/runtime/upstreams/websocket/send`
- `POST /admin/runtime/upstreams/websocket/fixture/emit`

### Feishu runtime

- `GET /admin/runtime/feishu`
- `GET /admin/runtime/feishu/chats`
- `POST /admin/runtime/feishu/messages`

## Worker Queue

`vhttpd` 现在支持一个有上限的应用层 worker 请求队列。

对应配置：

- `worker.queue_capacity`
- `worker.queue_timeout_ms`

语义：

- 没有空闲 worker，且队列还有空间
  - 请求会在 `vhttpd` 内短暂等待
- 队列已满
  - 返回 `503`
  - `x-vhttpd-error-class: worker_queue_full`
- 队列等待超时
  - 返回 `504`
  - `x-vhttpd-error-class: worker_queue_timeout`

相关 runtime 可见性在：

- `GET /admin/runtime`

## PHP Package Entry Points

如果你用 Composer package 而不是扩展直出类，当前主要入口是：

- `VPhp\VHttpd\Manager`
- `VPhp\VHttpd\AdminClient`
- `VPhp\VHttpd\PhpWorker\Server`
- `VPhp\VHttpd\PhpWorker\Client`
- `VPhp\VHttpd\PhpWorker\StreamResponse`
- `VPhp\VSlim\WebSocket\App`
- `VPhp\VSlim\Mcp\App`
- `VPhp\VSlim\App\Feishu\BotApp`
- `VPhp\VSlim\Stream\Factory`

更细的 package 角色拆分见：

- [php/package/README.md](/Users/guweigang/Source/vhttpd/php/package/README.md)
- [php/package/PACKAGE_ROLE_MAP.md](/Users/guweigang/Source/vhttpd/php/package/PACKAGE_ROLE_MAP.md)

## Source Map

如果你要从源码理解 `vhttpd`，可以先记这张最小地图：

- `main.v`
  - 顶层 ingress / 路由 / orchestration
- `worker_transport.v`
  - worker frame / stream / websocket / mcp transport contract
- `stream_runtime.v`
  - stream `direct` / `dispatch`
- `upstream_runtime.v`
  - stream `upstream_plan`
- `websocket_runtime.v`
  - websocket room / presence / hub
- `mcp_runtime.v`
  - MCP Streamable HTTP runtime
- `websocket_upstream_runtime.v`
  - outbound websocket upstream runtime
- `admin_runtime.v`
  - runtime summary/admin plane

更完整的文件职责见：

- [RUNTIME_MODULE_MAP.md](/Users/guweigang/Source/vhttpd/docs/RUNTIME_MODULE_MAP.md)

## Recommended Reading Order

官网或首次了解：

1. 先看这页
2. 再看 [README.md](/Users/guweigang/Source/vhttpd/README.md)
3. 再看 [RUNTIME_MODULE_MAP.md](/Users/guweigang/Source/vhttpd/docs/RUNTIME_MODULE_MAP.md)

stream / upstream：

1. [STREAM_RUNTIME_PHASES.md](/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md)
2. [UPSTREAM_PLAN_PHASE3.md](/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md)

MCP：

1. [MCP.md](/Users/guweigang/Source/vhttpd/docs/MCP.md)
2. [MCP_APP_API.md](/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md)
3. [MCP_RUNBOOK.md](/Users/guweigang/Source/vhttpd/docs/MCP_RUNBOOK.md)

worker / transport：

1. [transport_contract.md](/Users/guweigang/Source/vhttpd/docs/transport_contract.md)
2. [failure_model.md](/Users/guweigang/Source/vhttpd/docs/failure_model.md)
