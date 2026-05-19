# 深入理解 vhttpd 架构：从协议层到运行时

在前面的文章中，我们已经了解了 vhttpd 的各种应用场景。现在，让我们深入探讨 vhttpd 的内部架构，理解它是如何将各种协议和应用整合在一起的。

---

## 一句话定义

> vhttpd = PHP 应用的 transport/runtime layer

更准确地说，vhttpd 是一个 **runtime gateway**，它：
- 终止 HTTP / WebSocket / stream 连接
- 调度外部 worker
- 承载 streaming / upstream execution / MCP runtime
- 暴露 runtime state 和 admin plane

---

## 核心架构概览

### 整体结构图

```
┌─────────────────────────────────────────────────────────┐
│                      Client / Browser / Upstream         │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│                    vhttpd Kernel                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │                    App                            │   │
│  │  (main runtime state root)                       │   │
│  │                                                 │   │
│  │  ├── worker_pool (managed_workers)              │   │
│  │  ├── worker_transport (frame/chunk/sse)         │   │
│  │  ├── upstream_runtime (UpstreamRuntimeSession)   │   │
│  │  ├── websocket_upstream_runtime (ingress)        │   │
│  │  └── admin_runtime / admin_server               │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────┐
│              Application Layer (Pluggable)              │
│  ┌─────────────────────────────────────────────────┐   │
│  │              Provider Interface                  │   │
│  │  (init / start / stop / snapshot)              │   │
│  │                                                 │   │
│  │  ├── FeishuProvider → FeishuProviderRuntime    │   │
│  │  ├── CodexProvider → CodexProviderRuntime       │   │
│  │  └── OllamaProvider                            │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## 运行时模型（Runtime Model）

vhttpd 使用两层语义理解运行时：

### 1. Surface（运行面）

一级概念只表达**运行面**：

| Surface | 说明 |
|---------|------|
| `http` | 普通请求/响应 |
| `stream` | 流式响应（SSE、文本流） |
| `websocket` | WebSocket 连接 |
| `mcp` | MCP (Model Context Protocol) |
| `websocket_upstream` | 主动连接上游（如飞书长连接） |

### 2. Surface-specific Fields（运行面特定字段）

二级概念表达**具体怎么跑**：

#### Stream 策略

| 策略 | 说明 |
|------|------|
| `direct` | Worker 直接持有流并输出 chunk |
| `dispatch` | vhttpd 持有下游连接，Worker 处理 open/next/close |
| `upstream_plan` | Worker 返回 plan，vhttpd 自己连接上游并出流 |

#### Stream 输出格式

| 格式 | 说明 |
|------|------|
| `text` | 纯文本分块 |
| `sse` | Server-Sent Events |

#### WebSocket Upstream Provider

| Provider | 说明 |
|----------|------|
| `feishu` | 飞书长连接 |

---

## 内核组件详解

### 1. App（应用根结构体）

`App` 是 runtime 的根结构体，统一持有所有状态：

```v
struct App {
    mut:
    // Worker 池
    worker_pool WorkerPool

    // Worker 传输层
    worker_transport WorkerTransport

    // 上游运行时
    upstream_runtime UpstreamRuntime
    upstream_sessions map[string]UpstreamRuntimeSession

    // WebSocket 上游运行时
    websocket_upstream_runtime WebsocketUpstreamRuntime

    // Admin 运行时
    admin_runtime AdminRuntime

    // Provider 实例
    feishu_mu sync.Mutex
    feishu_runtime map[string]FeishuProviderRuntime

    codex_mu sync.Mutex
    codex_runtime ?CodexProviderRuntime
}
```

**关键设计原则**：
- Provider 状态封装在各自的 runtime struct 中
- App 仅保留 provider 级别的 mutex 和对应的 runtime 实例
- 清晰的职责分离

### 2. Worker Pool（Worker 池）

Worker 池负责管理外部 PHP Worker 进程：

```v
struct WorkerPool {
    mut:
    workers []Worker
    available chan Worker
    queue []chan WorkerRequest
    size int
    socket_prefix string
}

struct Worker {
    pid int
    socket string
    status WorkerStatus
    request_count int
}
```

**核心功能**：
- 进程管理（启动、停止、重启）
- 请求队列
- 负载均衡
- 心跳检测

### 3. Worker Transport（Worker 传输层）

负责 vhttpd 与 Worker 之间的通信：

```v
struct WorkerTransport {
    mut:
    socket string
    connection net.Conn
    encoder JSONEncoder
    decoder JSONDecoder
}
```

**传输内容**：
- 请求帧（Request Frame）
- 响应帧（Response Frame）
- Chunk 帧（流式响应）
- SSE 帧（Server-Sent Events）

### 4. Upstream Runtime（上游泳行时）

处理到上游服务的连接（如 Ollama）：

```v
struct UpstreamRuntime {
    mut:
    sessions map[string]UpstreamRuntimeSession
}

struct UpstreamRuntimeSession {
    id string
    request_id string
    trace_id string
    role string
    provider string
    // 连接状态
    connected bool
    ws_url string
    // ...
}
```

**关键能力**：
- 多会话管理
- 连接生命周期
- 事件分发

### 5. WebSocket Upstream Runtime

处理主动连接到上游的 WebSocket（如飞书）：

```v
struct WebsocketUpstreamRuntime {
    mut:
    connections map[string]WebsocketConnection
    reconnect_delay_ms int
}
```

**Provider 接口**：

```v
interface Provider {
    fn init(mut app &App) !
    fn start(mut app &App) !
    fn stop(mut app &App) !
    fn snapshot(app &App) ProviderSnapshot
}
```

---

## Surface 能力映射

| Surface | Subtype | 实现说明 |
|---------|---------|----------|
| `http` | - | 普通 request/response |
| `stream` | `direct` | Worker 直接持有流并输出 chunk |
| `stream` | `dispatch` | vhttpd 持有下游连接，Worker 处理 open/next/close |
| `stream` | `upstream_plan` | Worker 返回 plan，vhttpd 自己连接上游并出流 |
| `websocket` | phase 1 / dispatch | WebSocket handler / WebSocket dispatch |
| `mcp` | Streamable HTTP | POST /mcp、GET /mcp、DELETE /mcp |
| `websocket_upstream` | `provider=feishu` | vhttpd 主动连上游 websocket provider 并接收入站事件 |

---

## Worker Bootstrap 模型

### PHP Worker 入口

PHP Worker 识别的 bootstrap array key：

```php
<?php

return [
    'http' => $httpApp,           // HTTP 请求处理器
    'websocket' => $websocketApp, // WebSocket 处理器
    'stream' => $streamApp,       // 流式响应处理器
    'mcp' => $mcpApp,             // MCP 处理器
    'websocket_upstream' => $upstreamApp, // 上游 WebSocket 处理器
];
```

### 请求/响应形状

#### One-shot HTTP

```php
return [
    'status' => 200,
    'content_type' => 'application/json; charset=utf-8',
    'body' => json_encode(['data' => 'value']),
];
```

#### Stream（流式响应）

```php
// Mode 1: Direct Stream
return vhttpd_stream_text($chunks, 200, 'text/plain');

// Mode 2: Dispatch Stream
return [
    'mode' => 'stream',
    'strategy' => 'dispatch',
    // Worker 处理 open/next/close 事件
];

// Mode 3: Upstream Plan
return [
    'mode' => 'stream',
    'strategy' => 'upstream_plan',
    'upstream' => [
        'url' => 'http://localhost:11434/api/chat',
        'body' => $payload,
    ],
    'output' => 'sse',
];
```

---

## 命令执行架构

### 命令执行流程

```
Client Request
    ↓
Command Dispatcher
    ↓
┌─────────────────────────────────────────┐
│         CommandExecutor                  │
│  ├── FeishuCommandHandler              │
│  ├── CodexCommandHandler               │
│  ├── OllamaHandler                     │
│  └── GenericUpstreamCommandHandler      │
└─────────────────────────────────────────┘
    ↓
Provider Runtime
    ↓
External Service (Feishu / Codex / Ollama)
```

### 命令处理器

```v
struct CommandExecutor {
    feishu_route_enabled bool
    codex_route_enabled bool
    ollama_route_enabled bool
}

interface CommandHandler {
    fn execute(mut cmd WorkerWebSocketUpstreamCommand) !
}
```

---

## Provider 架构

### Provider 生命周期

```
1. Bootstrap (注册)
   ↓
2. Init (初始化配置)
   ↓
3. Start (启动服务)
   ↓
4. Runtime (运行时)
   ↓
5. Stop (停止服务)
```

### Feishu Provider

```v
struct FeishuProviderRuntime {
    mut:
    config FeishuConfig
    connection_state FeishuConnectionState
    runtime_state FeishuRuntimeState
}

struct FeishuConfig {
    enabled bool
    open_base_url string
    reconnect_delay_ms int
    token_refresh_skew_seconds int
}

struct FeishuConnectionState {
    connected bool
    ws_url string
    conn &websocket.Conn
    initialized bool
}
```

### Codex Provider

```v
struct CodexProviderRuntime {
    mut:
    config CodexConfig
    connection_state CodexConnectionState
    runtime_state CodexRuntimeState
}

struct CodexConfig {
    enabled bool
    url string
    model string
    effort string
    cwd string
    approval_policy string
    reconnect_delay_ms int
    flush_interval_ms int
}
```

---

## Admin Plane（管理平面）

### Admin API 端点

#### 运行时摘要

```
GET /admin/runtime
GET /admin/runtime/upstreams
GET /admin/runtime/websockets
GET /admin/runtime/mcp
```

#### Worker 操作

```
GET  /admin/workers
GET  /admin/stats
POST /admin/workers/restart
POST /admin/workers/restart/all
```

#### WebSocket 上游运行时

```
GET  /admin/runtime/upstreams/websocket
GET  /admin/runtime/upstreams/websocket/events
GET  /admin/runtime/upstreams/websocket/activities
POST /admin/runtime/upstreams/websocket/send
```

#### Feishu 运行时

```
GET  /admin/runtime/feishu
GET  /admin/runtime/feishu/chats
POST /admin/runtime/feishu/messages
```

---

## Worker 队列机制

vhttpd 支持有上限的应用层 worker 请求队列：

### 配置

```toml
[worker]
queue_capacity = 100      # 队列容量
queue_timeout_ms = 5000  # 等待超时
```

### 队列语义

| 情况 | 行为 |
|------|------|
| 没有空闲 worker，队列有空间 | 请求在 vhttpd 内短暂等待 |
| 队列已满 | 返回 503，`x-vhttpd-error-class: worker_queue_full` |
| 队列等待超时 | 返回 504，`x-vhttpd-error-class: worker_queue_timeout` |

### 运行时可见性

```bash
curl http://127.0.0.1:19981/admin/runtime | jq .
```

```json
{
  "worker_pool_size": 4,
  "worker_available": 3,
  "worker_queue_length": 0,
  "worker_queue_capacity": 100,
  "http_requests_total": 1523,
  "stream_requests_total": 45,
  "websocket_connections": 2,
  "active_upstreams": 1
}
```

---

## 编译期开关

vhttpd 支持编译期禁用不需要的路由，减少二进制大小：

### 可用开关

| 开关 | 说明 |
|------|------|
| `no_feishu_routes` | 禁用飞书相关路由 |
| `no_codex_routes` | 禁用 Codex 相关路由 |
| `no_ollama_routes` | 禁用 Ollama 相关路由 |

### 编译示例

```bash
# 完整版本
v .

# 轻量版本（无 Feishu）
v -d no_feishu_routes .

# 仅 HTTP 版本
v -d no_feishu_routes -d no_codex_routes -d no_ollama_routes .
```

---

## 事件日志

### 日志格式

每个事件都是 NDJSON 格式：

```json
{"ts":"2024-01-15T10:30:00Z","kind":"upstream.connect","url":"http://localhost:11434"}
{"ts":"2024-01-15T10:30:01Z","kind":"upstream.chunk","size":45}
{"ts":"2024-01-15T10:30:05Z","kind":"upstream.close","duration_ms":5000}
{"ts":"2024-01-15T10:31:00Z","kind":"feishu.message.receive","chat_id":"xxx"}
```

### 配置

```toml
[files]
event_log = "tmp/vhttpd.events.ndjson"
```

### 查看日志

```bash
# 实时查看
tail -f tmp/vhttpd.events.ndjson

# 统计错误
cat tmp/vhttpd.events.ndjson | jq 'select(.kind | startswith("error"))' | wc -l

# 分析请求
cat tmp/vhttpd.events.ndjson | jq 'select(.kind == "http.request")' | jq -r '.path' | sort | uniq -c
```

---

## 数据流示例

### HTTP 请求流程

```
Client
  ↓ HTTP GET /api/users
vhttpd Server
  ↓
Worker Transport (Unix Socket)
  ↓
PHP Worker
  ↓ 处理请求
PHP Worker
  ↓ Response
Worker Transport
  ↓
vhttpd Server
  ↓ HTTP 200
Client
```

### Stream 请求流程（Phase 3: Upstream Plan）

```
Client
  ↓ HTTP GET /chat (SSE)
vhttpd Server
  ↓
PHP Worker
  ↓ Plan Response { mode: 'stream', strategy: 'upstream_plan', upstream: {...} }
PHP Worker
  ↓
vhttpd Server
  ↓ Connect to Upstream (e.g., Ollama)
Ollama Server
  ↓ SSE Stream
vhttpd Server
  ↓ Transform (if needed)
vhttpd Server
  ↓ SSE Stream
Client
```

### WebSocket Upstream 流程

```
vhttpd Server
  ↓ Connect (WebSocket)
Feishu Server
  ↓ Event (message receive)
vhttpd WebsocketUpstreamRuntime
  ↓ Dispatch
PHP Worker (websocket_upstream handler)
  ↓ Commands (e.g., send message)
vhttpd WebsocketUpstreamRuntime
  ↓ Send
Feishu Server
```

---

## 性能考量

### Worker 池大小

```toml
[worker]
pool_size = 4  # 推荐：CPU 核心数 * 2
```

### 连接管理

- Worker 使用 Unix Socket，零拷贝
- 上游连接复用
- Keep-alive 支持

### 内存管理

- Worker 进程定期重启（`max_requests`）
- 会话数据定期清理
- 事件日志轮转

---

## 扩展 vhttpd

### 添加新 Provider

1. 实现 Provider 接口

```v
struct MyProviderRuntime {
    mut:
    config MyProviderConfig
    // ...
}

fn (mut p MyProviderRuntime) init(mut app &App) ! {
    // 初始化逻辑
}

fn (mut p MyProviderRuntime) start(mut app &App) ! {
    // 启动逻辑
}

fn (mut p MyProviderRuntime) stop(mut app &App) ! {
    // 停止逻辑
}

fn (p MyProviderRuntime) snapshot(app &App) ProviderSnapshot {
    // 返回快照
}
```

2. 注册 Provider

```v
fn bootstrap_providers(mut app &App) ! {
    if !app.no_myprovider_routes {
        app.myprovider_runtime = MyProviderRuntime{}
        app.myprovider_runtime.init(mut app)!
        app.myprovider_runtime.start(mut app)!
    }
}
```

---

## 下一步

在下一篇文章中，我们将探讨 **可观测性实战**，包括：
- Admin Plane 深入使用
- Runtime stats 和 metrics
- Event log 和故障排查
- 生产运维最佳实践

如果你想继续探索，可以：
- 阅读 [`STRUCT_RELATIONSHIP_MAP.md`](file:///workspace/docs/STRUCT_RELATIONSHIP_MAP.md) 了解详细的结构体关系
- 阅读 [`OVERVIEW.md`](file:///workspace/docs/OVERVIEW.md) 了解运行时模型
- 查看源码中的 `app.v`、`worker_pool.v`、`provider.v` 等核心文件

---

## 相关资源

- [架构总览](file:///workspace/docs/OVERVIEW.md)
- [结构体关系图](file:///workspace/docs/STRUCT_RELATIONSHIP_MAP.md)
- [执行器模式文档](file:///workspace/docs/EXECUTOR_MODES.md)
- [运行时配置参考](file:///workspace/config/vhttpd.example.toml)
