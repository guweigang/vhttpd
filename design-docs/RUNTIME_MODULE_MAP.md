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

### Feishu 首次创建授权（2026-10-20）

[创建授权状态](../src/feishu/creation.v)归 `FeishuState` 所有：在同一把 `mu` 下签发、消费、撤销和释放一次性凭证，并管理远端签发尚未完成时的临时归属。未消费凭证与临时签发记录合计最多 4096 项，300 秒过期；已消费或撤销的凭证立即移除，无需保存历史代际表。

[可信应用入口](../src/feishu_creation_runtime.v)和[请求期 Vjsx host 能力](../src/executor/inproc_vjsx_creation_api.v)负责签发；命令准入不能临时补签。流式初始 send 需要服务端代际和独立的 `creation_token`；首次 bind 还必须持有绑定该物理消息 ID 的专属凭证，与已有缓冲替换所需的 `stream_generation` CAS 分开。[原生命令入口](../src/command_handlers.v)和[桥接入口](../src/feishu_card_bridge_server_runtime.v)分别在自己的状态中消费凭证，随后沿用既有 HTTP 完成与跨注册表发布保护。

[物理消息变更](../src/feishu/initial_send.v)会撤销该 ID 尚未消费的 bind 凭证及远端签发归属，因此跨流重绑再清理也不能让旧首次 bind 重建目标。[控制撤销](../src/feishu/control_generation.v)可以在首次投递前取消凭证；[失败终结](../src/feishu/stream_command.v)也清理失去最后归属的创建授权，同时保留已准入的同代发送。TypeScript 的[流状态](../examples/codexbot-app-ts/lib/state.mjs)持久化签发结果，[命令构造器](../examples/codexbot-app-ts/lib/commands.mts)只序列化捕获的凭证；其他生产端也必须接入可信签发，旧格式首次创建会被拒绝。跨宿主撤销传播仍是独立边界。

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

### 外部与 PHP 创建凭证（2026-10-20）

[Admin 签发入口](../src/admin_feishu_creation.v)仅位于独立 admin listener，必须配置非空 token 并传入 `x-vhttpd-admin-token`；query token、浏览器 cookie 和空 token 开放模式均不能签发。GET `/admin/runtime/feishu/creation` 返回本进程的 `epoch` 和服务端 `issued_at`；POST 同一路径接收这两项、随机 64 位十六进制 `request_id`、`stream_id`、`instance`、`kind=send|bind` 和 `message_id`（bind 必填，send 为空），返回 `generation/token`。成功响应使用 `Cache-Control: no-store`。

[外部签发状态](../src/feishu/external_creation.v)在 Feishu mutex 下管理有期限的幂等记录，最多 4096 项、固定从捕获时间起 300 秒，满时拒绝而不逐出活跃记录。相同请求只能取得原凭证，消费、撤销或失败后不会补签；重用请求 ID 改 scope 会被拒绝，重启后旧 epoch 失效。POST `/admin/runtime/feishu/creation/revoke` 提交原签发请求，撤销尚未消费的凭证；即使撤销先到，也保留终结记录防止迟到 POST 创建。它不取消已准入 HTTP 或已发布资源，后者仍使用捕获代际的 `session.clear`。

[PHP 客户端](../php/package/src/VHttpd/Feishu/CreationClient.php)从 `VHTTPD_ADMIN_BASE_URL` 和 `VHTTPD_ADMIN_TOKEN` 获取显式配置，不跟随重定向、不自动重试或续签。[不可变凭证](../php/package/src/VHttpd/Feishu/CreationLease.php)校验 stream、实例、操作和物理目标，只序列化捕获值。[PHP StreamService](../examples/codexbot-app/lib/Service/StreamService.php)在新建流时获取凭证，将代际、token、原签发请求与任务一起写入 SQLite；写入失败回滚并尝试撤销，失联凭证依赖有界过期回收。取消使用已保存代际。桥接撤销按精确 token、代际与 scope 回收远端凭证；迟到结果无法在本地发布时也尝试回收。网络失败会留下有期限远端凭证，本地准入仍按原归属拒绝；一般跨宿主生命周期取消仍是独立边界。

[状态回归](../src/feishu/external_creation_test.v)、[命令集成回归](../src/feishu_external_creation_admission_test.v)、[PHP/SQLite 回归](../php/package/tests/feishu_creation_test.php)与[真实 HTTP E2E](../tests/e2e/feishu_external_creation_test.mjs)覆盖获取、持久化、传递、乱序撤销、重放及进程重启；后两者已纳入标准 E2E 入口。

### 跨宿主桥接撤销与连接租约（2026-10-20）

[桥接授权](../src/feishu/bridge_authority.v)归具体连接持有，与可复用的 `client_id` 分开。桥接签发的凭证、本地镜像、已准入发送及缓冲保留这份归属；断连、同名连接替换或租约到期会在既有 Feishu → Codex 顺序下撤销授权、初始发布资格、缓冲和对应目标。旧连接的消息不能命中新连接的等待者，也不能续活新连接。迟到签发结果在落地时再检查原连接，迟到 HTTP、rollover、finish 与 failure 完成继续受原身份及租约检查约束。可信原生重注册会清除旧桥接归属；wire bind 则保留其实际取得的桥接归属，避免首次 bind 或重绑后的资源逃过断连清理。

[连接注册和代理请求](../src/feishu_card_bridge_runtime.v)捕获原连接后发送，撤销不会改投重连后的连接。[session.clear](../src/command_handlers.v)先原子撤销本地状态及 Codex 目标，释放状态锁后通过窄能力传播到原连接；bind/rebind 后 clear 仍使用捕获的原远端 stream、实例和代际。服务端 clear 按连接及代际检查，重复或迟到 clear 不会删除其他连接或新代资源。未消费凭证撤销继续是独立操作；已消费 HTTP 和已发布资源使用 clear。代理失败或结果不确定会关闭原传输并撤销该连接上的本地资源，因此同连接其他流也需重新签发，不会保留一个可继续使用的失联授权。旧撤销重试无法关闭替代连接。

[客户端](../src/feishu_card_bridge_client_runtime.v)和[服务端](../src/feishu_card_bridge_server_runtime.v)均使用 45 秒连接租约。既有 15 秒应用心跳及当前连接上的实际响应/消息可以在到期前续租；过期后心跳不能复活授权。独立的 watchdog 每秒检查，关闭失联连接并清理资源；首次创建和异步完成在状态锁内也检查到期。服务端 watchdog 归会话持有并等待退出，客户端 watchdog 归 provider session worker 持有并随其退出。这覆盖客户端单向收不到 pong、远端仍能收到 ping 的情况。网络分区期间无法声称即时远端确认；本地先拒绝重放，远端最迟在未续租后的租约及检查间隔内终结，已发出的外部 HTTP 副作用不能撤回。

服务端为每条连接保留最多 4096 个 create 请求的结果或终结失败，重复请求不会在消费、撤销或凭证过期后重新签发；满时拒绝，不逐出重放证据，当前原生代理客户端会关闭并重连。连接退休后清空这些记录，无全局退休历史表。新连接必须显式获取新凭证。原生可信凭证通过桥接发送时在准入处取得该连接的发布归属；原生本地资源不因另一连接退休而被删除。

[状态回归](../src/feishu/bridge_authority_test.v)、[跨注册表集成回归](../src/feishu_cross_host_revocation_test.v)与[双 hub E2E](../tests/e2e/feishu_bridge_revocation_test.mjs)覆盖重连、精确清理、迟到结果、失败撤销、首次 bind/rebind 撤销归属、静默过期及真实单向丢包；双 hub 测试已加入标准 E2E。该轮只补充撤销及原发布归属；后续 bind/rebind 发布同步见下一节。

### 跨宿主 bind/rebind 发布同步（2026-10-21）

[绑定预留](../src/feishu/bridge_bind.v)把本地准入、远端发布和本地完成分开。首次 bind 在本地消费目标绑定凭证，以创建代际保留可撤销的待确认缓冲；rebind 保留旧 stream、实例和代际供 clear 使用。等待网络期间阻止新的流式命令、重绑、定时 flush 及旧身份的异步写回。请求捕获原连接和原远端 scope，释放状态锁后发送，不会改投重连后的连接。注册会撤销 stream 上的创建资格，因此准入、远端 CAS 与本地确认均检查源和目标 scope 的连接及实例归属；目标已有其他连接、原生资源或未完成签发时拒绝，避免一次目标 CAS 越权取消其他资源。

[桥接服务端](../src/feishu_card_bridge_server_runtime.v)的 `bind` 操作在状态锁内校验同一连接持有的目标、源 stream/实例与旧代际 CAS；首次创建则消费目标绑定的一次性凭证。成功后生成新的缓冲代际并返回。首次凭证已消费或旧 CAS 已失效时，迟到、重复请求均不能重新创建资源。服务端缓冲归桥接传输持有，发起端在确认后发布本地 Codex 目标。

[命令入口](../src/command_handlers.v)收到结果后，在 Feishu → Codex 锁顺序下重新验证原预留身份和原连接租约，使用远端返回的同一代际更新本地缓冲与目标，随后发送回执。若期间已撤销、替换或断连，就拒绝迟到完成，并在原连接上按返回代际补偿清理远端；清理失败、超时或缺少代际的确认会关闭原连接，沿既有租约机制收敛，不恢复旧缓冲。待确认失败后的旧资源不会自动回滚复活。

跨宿主确认存在远端已发布而本地仍待确认的短暂窗口，不提供分布式原子提交。此时本地拒绝命令；本地撤销后即使旧代际 clear 未删除远端新代际，迟到结果仍触发精确补偿，连接失效时由双方授权退休与租约回收。不能把未收到确认当作成功，也不能自动获取新凭证重放旧 bind。

[状态回归](../src/feishu/bridge_bind_test.v)、[命令发布回归](../src/feishu_bridge_bind_publication_test.v)、[生产代理回归](../src/feishu_bridge_bind_transport_test.v)覆盖成功同步、待确认准入、撤销乱序、替换、断连、异常确认和补偿；[标准双 hub E2E](../tests/e2e/feishu_bridge_revocation_test.mjs)新增真实 bind/rebind、旧 CAS 与已撤销首次凭证的重放拒绝。

## Related Docs

- [`/Users/guweigang/Source/vhttpd/docs/OVERVIEW.md`](/Users/guweigang/Source/vhttpd/docs/OVERVIEW.md)
- [`/Users/guweigang/Source/vhttpd/README.md`](/Users/guweigang/Source/vhttpd/README.md)
- [`/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md`](/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md)
- [`/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md`](/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP.md`](/Users/guweigang/Source/vhttpd/docs/MCP.md)
