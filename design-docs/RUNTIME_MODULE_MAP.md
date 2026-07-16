# Runtime Module Map

这页不讲单个 feature 的详细设计，而是回答一个更基础的问题：

- 现在 `vhttpd/src/*.v` 这些运行时模块分别负责什么？
- 它们在整体架构里的分层关系是什么？
- 维护时应该先看哪个文件？

## Overall Shape

可以把 `vhttpd` 看成 4 层：

1. 协议入口层
   - HTTP
   - WebSocket
   - stream
2. transport / orchestration 层
   - worker frame
   - worker dispatch
   - upstream dispatch
   - MCP session / websocket hub
3. runtime state / admin 层
   - worker pool state
   - websocket runtime state
   - upstream runtime state
   - MCP runtime state
   - `/admin/*`
4. PHP worker bridge 层
   - `php-worker`
   - package helper
   - VSlim / framework adapter

## Current Runtime Files

### [`/Users/guweigang/Source/vhttpd/src/main.v`](/Users/guweigang/Source/vhttpd/src/main.v)

角色：

- 主入口
- 通用 HTTP route 入口
- 高层 proxy orchestration
- 不适合再塞 feature-specific state machine

现在它更像：

- request ingress
- protocol routing
- 组合其它 runtime module

如果你要改：

- 顶层路由走向
- 普通 HTTP proxy 主路径
- 通用 request normalization

优先看这个文件。

### [`/Users/guweigang/Source/vhttpd/src/worker_transport.v`](/Users/guweigang/Source/vhttpd/src/worker_transport.v)

角色：

- worker frame 读写
- stream/websocket/MCP dispatch helper
- HTTP chunk/SSE 写出 helper
- transport error classification

这里负责的是“怎么和 worker 说话”，不是“业务 feature 怎么工作”。

如果你要改：

- frame 编码
- read/write timeout 行为
- `dispatch_stream(...)`
- `dispatch_mcp(...)`
- SSE/text chunk 写出

优先看这个文件。

### [`/Users/guweigang/Source/vhttpd/src/worker_pool.v`](/Users/guweigang/Source/vhttpd/src/worker_pool.v)

角色：

- worker pool lifecycle
- socket 解析和生成
- autostart / restart / drain
- inflight request accounting
- worker admin snapshot

这里负责的是“worker 进程怎么活着”，不是协议层。

如果你要改：

- worker 选择
- pool size
- restart policy
- draining semantics

优先看这个文件。

### [`/Users/guweigang/Source/vhttpd/src/stream_runtime.v`](/Users/guweigang/Source/vhttpd/src/stream_runtime.v)

角色：

- stream phase 1
- stream dispatch strategy
- downstream-only stream lifecycle

这里不再负责 upstream plan 执行，那部分已经拆到单独模块。

如果你要改：

- `StreamResponse`
- `stream`
- SSE/text synthetic stream

优先看这个文件。

### [`/Users/guweigang/Source/vhttpd/src/upstream_runtime.v`](/Users/guweigang/Source/vhttpd/src/upstream_runtime.v)

角色：

- stream phase 3 (`UpstreamPlan`)
- 上游 HTTP streaming 执行
- NDJSON 解码
- mapper 应用
- upstream runtime registry
- `/admin/runtime/upstreams` snapshot

一句话：

- `stream_runtime.v` 关心“下游怎么流”
- `upstream_runtime.v` 关心“上游怎么接”

如果你要改：

- upstream HTTP 执行
- `ndjson_text_field`
- `ndjson_sse_field`
- upstream runtime admin 可见性

优先看这个文件。

### [`/Users/guweigang/Source/vhttpd/src/websocket_runtime.v`](/Users/guweigang/Source/vhttpd/src/websocket_runtime.v)

角色：

- websocket hub
- room membership
- broadcast / send_to
- presence snapshot
- websocket admin snapshot

这里主要是 websocket 的本机 runtime state。

如果你要改：

- room fanout
- metadata / presence
- `/admin/runtime/websockets`

优先看这个文件。

### [`/Users/guweigang/Source/vhttpd/src/mcp_runtime.v`](/Users/guweigang/Source/vhttpd/src/mcp_runtime.v)

角色：

- MCP Streamable HTTP runtime
- MCP session
- SSE queue / flush
- capability snapshot
- sampling policy runtime
- `/admin/runtime/mcp`

这里是 MCP transport/runtime 的核心，不是 MCP 业务框架。

如果你要改：

- `POST /mcp`
- `GET /mcp`
- `DELETE /mcp`
- session limits
- capability negotiation runtime

优先看这个文件。

### [`/Users/guweigang/Source/vhttpd/src/admin_runtime.v`](/Users/guweigang/Source/vhttpd/src/admin_runtime.v)

角色：

- `/admin/runtime`
- `/admin/runtime/upstreams`
- `/admin/runtime/websockets`
- `/admin/runtime/mcp`
- runtime summary / query parsing helper

这是“面向运行时总览”的 admin 层。

### [`/Users/guweigang/Source/vhttpd/src/admin_workers.v`](/Users/guweigang/Source/vhttpd/src/admin_workers.v)

角色：

- `/admin/workers`
- `/admin/stats`
- `/admin/workers/restart`
- `/admin/workers/restart/all`

这是“面向 worker 运维”的 admin 层。

### [`/Users/guweigang/Source/vhttpd/src/admin_server.v`](/Users/guweigang/Source/vhttpd/src/admin_server.v)

角色：

- 独立 admin plane
- token gate
- admin-only host/port

如果 data plane 和 control plane 分开，这个文件很重要。

### [`/Users/guweigang/Source/vhttpd/src/feishu_runtime.v`](/Users/guweigang/Source/vhttpd/src/feishu_runtime.v)

角色：

- Feishu provider adapter（应用层）
- WebSocket upstream 的 Feishu 协议编解码
- Feishu tenant token 鉴权与刷新
- Feishu REST send/update/upload API
- Feishu 事件回调签名验证与解密
- Feishu 管理面快照（chats / events）

这里是 Feishu 作为 websocket upstream provider 的全部业务协议实现。

如果你要改：

- Feishu frame encode/decode
- Feishu tenant access token
- Feishu send/update message
- Feishu callback 签名/解密
- `/admin/runtime/feishu` 数据源

优先看这个文件。

### [`/Users/guweigang/Source/vhttpd/src/feishu_runtime_test.v`](/Users/guweigang/Source/vhttpd/src/feishu_runtime_test.v)

角色：

- Feishu provider 的单元测试
- 覆盖协议编解码、URL 生成、事件摘要等

### [`/Users/guweigang/Source/vhttpd/src/codex_runtime.v`](/Users/guweigang/Source/vhttpd/src/codex_runtime.v)

角色：

- Codex provider adapter（应用层）
- WebSocket upstream 的 Codex JSON-RPC 2.0 协议编解码
- Codex provider runtime 状态封装（`CodexProviderRuntime`）
- 连接生命周期管理（connect / disconnect / reconnect）
- initialize / initialized / thread/start 握手流程
- turn/start 发起与 RPC 响应路由
- 通知（notification）分发与 item/agentMessage/delta 流式拦截
- 错误聚合与批量 flush（err_bursts）
- 管理面快照（admin_codex_snapshot）

`CodexProviderRuntime` 封装了 Codex 相关的全部状态，分三层：

- **config**：`enabled`, `url`, `model`, `effort`, `cwd`, `approval_policy`, `sandbox`, `reconnect_delay_ms`, `flush_interval_ms`
- **connection state**：`connected`, `ws_url`, `conn`, `thread_id`, `initialized`, `active_stream_id`, 连接计数等
- **runtime state**：`stream_map`, `rpc_id_counter`, `pending_rpcs`, `err_bursts`, `err_pending_flushes`, `thread_stream_map`

`App` 仅保留 `codex_mu sync.Mutex` 和 `codex_runtime CodexProviderRuntime`。

如果你要改：

- Codex JSON-RPC encode/decode
- Codex 连接握手（initialize / thread/start）
- Codex turn 发起与 RPC 响应处理
- Codex 通知分发与 delta 流拦截
- `/admin/runtime/codex` 数据源

优先看这个文件。

## Phase Mapping

### WebSocket

- phase 1 / phase 2 主逻辑：
  [`/Users/guweigang/Source/vhttpd/src/main.v`](/Users/guweigang/Source/vhttpd/src/main.v)
  +
  [`/Users/guweigang/Source/vhttpd/src/websocket_runtime.v`](/Users/guweigang/Source/vhttpd/src/websocket_runtime.v)
  +
  [`/Users/guweigang/Source/vhttpd/src/worker_transport.v`](/Users/guweigang/Source/vhttpd/src/worker_transport.v)

### Stream

- phase 1 / phase 2：
  [`/Users/guweigang/Source/vhttpd/src/stream_runtime.v`](/Users/guweigang/Source/vhttpd/src/stream_runtime.v)
- phase 3：
  [`/Users/guweigang/Source/vhttpd/src/upstream_runtime.v`](/Users/guweigang/Source/vhttpd/src/upstream_runtime.v)

### MCP

- transport/runtime：
  [`/Users/guweigang/Source/vhttpd/src/mcp_runtime.v`](/Users/guweigang/Source/vhttpd/src/mcp_runtime.v)
- worker dispatch：
  [`/Users/guweigang/Source/vhttpd/src/worker_transport.v`](/Users/guweigang/Source/vhttpd/src/worker_transport.v)

## Maintenance Rule of Thumb

如果你不确定一个修改该放哪：

- 改协议入口和顶层路由：`main.v`
- 改 worker socket/frame：`worker_transport.v`
- 改 worker 生命周期：`worker_pool.v`
- 改 stream phase 1/2：`stream_runtime.v`
- 改 upstream phase 3：`upstream_runtime.v`
- 改 websocket room/presence：`websocket_runtime.v`
- 改 MCP session/runtime：`mcp_runtime.v`
- 改 runtime admin：`admin_runtime.v`
- 改 worker admin：`admin_workers.v`
- 改 Feishu provider 协议/鉴权/发送：`feishu_runtime.v`
- 改 Codex provider 协议/RPC/turn/连接：`codex_runtime.v`

## Related Docs

- [`/Users/guweigang/Source/vhttpd/docs/OVERVIEW.md`](/Users/guweigang/Source/vhttpd/docs/OVERVIEW.md)
- [`/Users/guweigang/Source/vhttpd/README.md`](/Users/guweigang/Source/vhttpd/README.md)
- [`/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md`](/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md)
- [`/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md`](/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP.md`](/Users/guweigang/Source/vhttpd/docs/MCP.md)
