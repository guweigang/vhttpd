# MCP vs Codex：可复用性深度分析

## 结论：部分复用，但角色完全不同

MCP 和 Codex 虽然都用 JSON-RPC 2.0，但在 vhttpd 中的**角色恰好相反**：

| 维度 | MCP | Codex |
|------|-----|-------|
| vhttpd 的角色 | **Server**（接收来自 MCP client 的请求） | **Client**（主动连接 Codex app-server） |
| 连接方向 | 外部 client → vhttpd | vhttpd → Codex app-server |
| 传输方式 | HTTP Streamable (POST+GET SSE) | WebSocket (persistent) |
| JSON-RPC 消息流 | 接收 request → dispatch 给 PHP → 返回 response | **发送** request → **接收** streaming notifications |
| session 模型 | client 创建 session，vhttpd 维护 | vhttpd 创建 turn，codex 管理 session |
| streaming 方向 | vhttpd → MCP client (SSE 推送) | Codex → vhttpd (WebSocket 推送) |

一句话：**MCP 里 vhttpd 是 JSON-RPC server，Codex 里 vhttpd 是 JSON-RPC client。**

## 可以复用的部分

### ✅ 1. JSON-RPC 消息格式（结构体定义）

可以抽一个通用的 JSON-RPC envelope：

```v
struct JsonRpcRequest {
    jsonrpc string = '2.0'   // 固定
    method  string
    params  string           // raw JSON
    id      string           // 非空 = request，空 = notification
}

struct JsonRpcResponse {
    jsonrpc string
    result  string           // raw JSON
    error   string           // raw JSON
    id      string
}

struct JsonRpcNotification {
    jsonrpc string
    method  string
    params  string           // raw JSON
}
```

但实际上 MCP runtime 根本没有定义 these 通用结构——它直接把 raw JSON string 透传给 PHP worker，PHP 解析后再返回。MCP 在 vhttpd 层面**几乎不解析 JSON-RPC content**。

> **结论**：JSON-RPC envelope 结构可以新建为通用 helper，但 MCP 现有代码里没有可直接复用的解析逻辑。

### ✅ 2. WebSocket 连接管理模式

Codex 需要 WebSocket 长连接到 app-server，这和 **Feishu Gateway 的 WebSocket upstream** 模式非常接近：

```
Feishu Gateway: vhttpd → WebSocket → Feishu cloud
Codex:          vhttpd → WebSocket → Codex app-server
```

已有的 `websocket_upstream_runtime.v` 里的 provider 模式（`feishu` / `fixture`）是最佳复用点：

- `websocket_upstream_provider_pull_url()` — 获取连接 URL
- `websocket_upstream_provider_on_connected()` — 连接成功回调
- `websocket_upstream_provider_on_disconnected()` — 断连回调
- `websocket_upstream_provider_reconnect_delay_ms()` — 重连延迟
- `websocket_upstream_message_cb()` — 消息回调

**这才是真正应该复用的核心**——不是 MCP，而是 WebSocket upstream provider 框架。

### ✅ 3. Command 执行引擎

MCP 和 Codex 场景都走 `execute_websocket_upstream_commands()`：

```v
// mcp_runtime.v:648
command_snapshots, command_error := app.execute_websocket_upstream_commands('mcp-${req_id}',
    response.commands)
```

这个引擎已经支持 `send` / `update` 事件，Codex 的 `feishu.stream.patch` 也是通过 `update` 事件走同一条路径。**完全复用，无需修改。**

### ✅ 4. Worker Dispatch 模式

MCP 的 `dispatch_mcp()` 和 Codex 渲染的 dispatch 模式相同：

```
dispatch_mcp:               write frame → PHP → read response
dispatch_websocket_upstream: write frame → PHP → read response (用于 render_stream)
```

Codex 的 `render_stream` 阶段就可以直接用 `dispatch_websocket_upstream()`。

### ✅ 5. Event/Stat 模式

```v
app.emit('codex.turn.started', {...})
app.emit('codex.turn.completed', {...})
```

和 `app.emit('mcp.commands', {...})` 完全一致的模式。

## 不能复用的部分

### ❌ 1. MCP Session 管理

MCP Session 模型（`mcp_ensure_session`, `mcp_session_bind_conn`, `mcp_session_flush`）是**面向外部 client 的**：
- client 创建 session
- vhttpd 维护 pending queue
- GET /mcp SSE 长轮询 flush

Codex 不需要这些。Codex 的 "session" 是 vhttpd 主动创建的 turn state，生命周期由 turn 驱动，不是由外部 client 驱动。

### ❌ 2. MCP SSE 推送

MCP 的 SSE 推送（`handle_mcp_session_stream`）是 vhttpd → MCP client 方向，Codex 的 streaming 是 Codex → vhttpd 方向。方向完全相反。

### ❌ 3. MCP 的 HTTP 路由

`POST /mcp`, `GET /mcp`, `DELETE /mcp` 这些路由对 Codex 没有意义。

## 最终建议：复用什么

```
┌─────────────────────────────────────────────────┐
│              复用矩阵                            │
├─────────────────────────┬───────────────────────┤
│ 组件                     │ 复用来源               │
├─────────────────────────┼───────────────────────┤
│ WebSocket 连接管理        │ websocket_upstream ✅  │
│ Provider 注册模式         │ websocket_upstream ✅  │
│ Command 执行引擎          │ websocket_upstream ✅  │
│ Worker dispatch (render) │ worker_transport ✅    │
│ Event/Stat 模式           │ 通用 emit() ✅        │
│ Admin snapshot           │ admin_runtime 模式 ✅  │
├─────────────────────────┼───────────────────────┤
│ JSON-RPC 解析            │ 新建 (MCP 不解析) ❌   │
│ Session/Turn 管理        │ 新建 ❌               │
│ Delta buffer + flush     │ 新建 ❌               │
│ stream_id → message_id   │ 新建 ❌               │
│ TOML config              │ 参考 feishu config ✅  │
└─────────────────────────┴───────────────────────┘
```

## 对 Phase 的影响

既然 MCP 的 JSON-RPC 部分不可复用，但 **WebSocket upstream provider 框架高度可复用**，
建议修正 Phase 1 的重心：

**不是** "从 MCP 复用 JSON-RPC"，
**建是** "从 WebSocket upstream provider 框架扩展 codex provider"。

具体就是在 `websocket_upstream_runtime.v` 现有的 provider match 链中，
新增 `websocket_upstream_provider_codex` 分支——和 feishu/fixture 并列。
vhttpd 只需要在接收到 Codex WebSocket 的 text frame 时，做 JSON-RPC notification 解析即可。
