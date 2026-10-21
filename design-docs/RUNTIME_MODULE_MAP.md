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

### 跨宿主 append/finish/fail 完成同步（2026-10-21）

[操作预留](../src/feishu/bridge_stream_operation.v)捕获原缓冲身份、代际与连接；[逐镜像 gate](../src/feishu/bridge_stream_gate.v)在 Feishu/Codex 锁外串行处理同一物理目标的请求。等待者持有原 gate 和请求代际，醒来后重新校验；bind/rebind、clear 与连接退休不等待 gate，旧等待者不能转投替代缓冲。预留会阻止旧身份的 flush、finish 与 rollover 完成发布。

[桥接结果](../src/feishu_card_bridge_server_runtime.v)携带原 `stream_generation`、物理 `message_id` 和 `stream_state=open|sealed|removed`。append/finish 执行后检查原准入仍有效，fail 在精确清理后确认 removed。[代理传输](../src/feishu_card_bridge_runtime.v)按原请求等待者和连接交付结果，拒绝缺失或错误代际、错误目标、错误状态及失败确认，关闭原连接；不会关闭替代连接。桥接两端应同步升级，旧端缺少确认字段时不降级为仅按消息 ID 接受。

[命令完成](../src/command_handlers.v)只在原操作、身份和租约仍有效时应用状态。最终 finish 将本地准入镜像封口，preview 保持服务端确认的状态；旧确认不能把已封口的代际重新打开。fail 在 Feishu → Codex 顺序下撤销镜像和匹配目标。[原生执行器](../src/feishu_stream_command_runtime.v)也按身份撤销根缓冲及有效链接的后继链、分段目标，保留其他代际、其他平台和无关 peer。空缓冲 finish 直接原子封口，无需 HTTP。

发起端镜像只持有准入和生命周期信息，远端 provider 持有内容、分段链与外部 HTTP。生产代理要求目标已有桥接归属；原生缓冲在操作预留前拒绝，不会因代理失败被清理。初始发送、绑定确认和流式操作会标记镜像；即使宿主同时配置原生 Feishu 和桥接，本地 flusher、preview/finish 提交和直接 append 也不能把镜像旧内容写回。镜像不复制远端完整内容与分段拓扑；clear/fail 的远端精确清理由远端拥有的链处理。

撤销、重绑或断连后迟到的成功结果不能发布本地完成，并按原连接、原 scope 和代际补偿 clear；不确定结果继续采用原连接退休及租约收敛。已准入外部 HTTP 副作用不能撤回，也不提供跨宿主瞬时原子提交。[PHP 事件路由](../examples/codexbot-app/lib/Upstream/ProviderEventRouter.php)不再让 `feishu.message.updated` 更新资源绑定，避免迟到失败通知覆盖新的消息和代际；sent 的绑定发布由下节的生产端预留和原子确认处理。

[状态回归](../src/feishu/bridge_stream_operation_test.v)、[生产传输与命令回归](../src/feishu_bridge_stream_completion_test.v)、[PHP/SQLite 回归](../php/package/tests/feishu_creation_test.php)及[双 hub E2E](../tests/e2e/feishu_bridge_revocation_test.mjs)覆盖排队、重绑/撤销/断连、异常确认、原生配对清理、空 finish、rollover 后 fail，以及旧 finish/fail HTTP 在途时替代连接重建同一物理消息的场景。

### 生产端 sent 回执绑定发布（2026-10-21）

[PHP 创建服务](../examples/codexbot-app/lib/Service/StreamService.php)在返回发送命令前持久化实例和 `stream_publication_id`，初始 ID 来自可信签发请求的 `request_id`。[CreationLease](../php/package/src/VHttpd/Feishu/CreationLease.php)把该 ID 随创建凭证写入命令 metadata；它是生产端待完成任务的关联权限，不替代 hub 的一次性创建凭证或代际准入。

[原生命令](../src/command_handlers.v)和[桥接服务端](../src/feishu_card_bridge_server_runtime.v)在实际绑定提交时建立独立的 [SentPublication](../src/feishu/sent_publication.v)。每个绑定拥有计数，rollover 链共享计数；分段 finish 继续递增。回执包含 `stream_id`、物理 `message_id`、`stream_generation`、`instance`、`publication_id`、整数 `publication_sequence`，在持有 Feishu 状态锁时捕获，解锁后派发；迟到派发不再按消息 ID 读取新绑定。重新注册清除原发布归属，重绑建立新计数；桥接服务端为发起镜像的首次回执预留序号 1，远端分段从后续序号继续。

[StreamRepository](../examples/codexbot-app/lib/Repository/StreamRepository.php)只用一条 SQLite UPDATE 完成回执发布：实例及预存发布 ID 必须一致，流和任务仍可发布，序号必须递增；第一次有效确认可接收新绑定代际，后续确认还必须保持该代际。乱序、重复、旧发布 ID、终态、缺字段及不存在的行均不更新。任务取消先写终态，流终态同时清空发布 ID；即使随后只重开行状态，也不能恢复旧权限。[事件路由](../examples/codexbot-app/lib/Upstream/ProviderEventRouter.php)只允许 Feishu sent 走此确认入口，不从 trace_id 补 stream_id，也不在回执中获取凭证或创建记录。

显式重绑生产者应先调用 `prepareBindingPublication(streamId, messageId, generation, expectedPublication, instance)`，在匹配旧消息、代际、发布 ID 和活跃状态时原子换用随机新发布 ID，再把返回 metadata 放进 bind 命令。预留后旧回执立即失效，包括新代际确认尚未到达时；失败不自动恢复旧发布权限。现有 PHP 示例没有业务级重绑入口，该方法提供显式预留接口，不能由 sent 自行调用。升级时旧数据库新增发布字段的默认值为空，不根据已存消息 ID 补发权限；发布端、hub、桥接两端和 PHP 消费端需一起升级。只带旧格式回执的已存任务需要新的显式生命周期。

[状态测试](../src/feishu/sent_publication_test.v)、[命令及 V/PHP 互操作测试](../src/feishu_sent_publication_test.v)、[SQLite 回归](../tests/protocol/feishu-generation-receipt.php)和[真实 hub/worker/PHP E2E](../tests/e2e/feishu_sent_publication_test.mjs)覆盖同 ID 重绑、分段回执乱序、撤销、删除、迁移以及待确认窗口。该边界依赖生产端先撤销或替换自己的预留；它不提供独立于生产端状态的外部撤销订阅，不撤回已经完成的 HTTP 副作用，也不认证任意外部事件来源。

### 普通 provider.message.update 准入与完成（2026-10-21）

[普通 Feishu 更新命令](../src/command_handlers.v)与[桥接 update 入口](../src/feishu_card_bridge_server_runtime.v)都需要当前 `stream_id`、实例、物理消息 ID 和非空 `stream_generation`；缺失或旧代际在 HTTP 前拒绝，不按消息 ID 推导新权限。未注册的外部消息须先通过可信 first-bind 建立绑定，不能以普通 update 自行建立生命周期。[通用命令入口](../src/command_handlers.v)拒绝省略 provider 的 event-only 更新，返回 `provider_message_update_provider_required`，避免低层默认 Feishu 绕开专用准入；同时拒绝通用 fallback 中 Codex 的普通 update（包括旧别名），返回 `codex_message_update_unsupported_use_rpc`：它过去会绕过 RPC/控制入口，直接作为原始 WebSocket 发送，且没有消息替换语义。调用者需使用既有 RPC 命令；fixture 更新只记录测试计数，未知 provider 仍报错。原始 provider send 和任意 Codex RPC 的业务授权不因此被宣称覆盖。

[MessageUpdate](../src/feishu/message_update.v)保存原状态所有者、绑定身份和独立操作 token。准入在锁内暂停同一缓冲的流式准入，取消原 preview/rollover/finish 的发布资格；网络请求在锁外执行。同一绑定的普通更新沿既有门闩排队，等待后重新检查原门闩和代际；重绑、撤销不等待旧 HTTP，并可安装新门闩。HTTP 成功只有在原操作仍当前时才能提交和发出 updated 通知，错误或迟到清理不能碰新绑定。

[模板替换](../src/feishu_message_runtime.v)使用准入时捕获的内容快照（包括空内容），不在异步发送阶段按消息 ID 读取替代缓冲。桥接服务端覆盖客户端快照，使用资源所有端的内容；替换只执行一次，内容内的字面量 `{{content}}` 不再次展开。

成功的整卡替换保留绑定、代际和跨宿主归属，清空旧流式内容并标记 `message_only`：后续普通更新仍可准入，旧 append/finish/fail、flusher、preview 和分段结果不能把旧文本写回。显式重绑清除该标记并建立新流式生命周期。原生 HTTP 失败仅释放原操作，不按 ID 删除缓冲或目标；跨宿主失败或不确定确认关闭原连接，沿既有连接租约撤销该连接的资源。updated 仍是无绑定发布权的通知。

桥接请求保留原物理连接、原远端 scope 和代际。服务端还检查请求连接确实拥有该资源；成功确认包含原 `stream_generation` 与 `stream_state=message`。发起端拒绝缺失、错误代际、错误消息或错误状态的确认，不将旧确认应用于重绑后的镜像。桥接双方须同步升级。

[PHP 更新构造器](../examples/codexbot-app/lib/Service/CommandFactory.php)和[TS 更新构造器](../examples/codexbot-app-ts/lib/commands.mts)只序列化调用者传入的上下文/stream handle，不查询注册表刷新代际。PHP 的 RPC、错误和取消路径在工作开始时保存绑定上下文，任务上下文携带实例；TS RPC、通知、审批和取消路径传递已取得的 handle。ID-only 更新携带空权限并被拒绝。PHP Feishu 更新直接输出协议数组，可独立于旧示例 SDK 验证序列化；示例整体的 SDK 缺失仍单独记录。

[状态回归](../src/feishu/message_update_test.v)、[命令回归](../src/feishu_message_update_test.v)、[PHP 构造器回归](../tests/protocol/feishu-message-update.php)及[真实桥接 HTTP 回归](../tests/e2e/feishu_message_update_test.mjs)覆盖迟到包、HTTP 在途重绑/撤销/同 ID 重建、失败重试、重复更新和排队。已在 HTTP 前通过准入的外部 PATCH 可能在撤销后完成，Feishu API 不支持本地代际条件提交；本轮阻止其运行时完成发布、缓冲写回及新生命周期接管，不保证撤回已准入的外部副作用。外部通知的来源认证和跨事件业务授权仍为独立边界。

### 原始 provider.message.send 准入与完成（2026-10-21）

[Feishu 发送准入](../src/feishu/creation.v)不再给空白 scope 提供匿名 InitialSend。原始命令（含旧 Feishu 别名）必须先取得可信签发的非空 `stream_id`、`stream_generation` 和一次性 `creation_token`；删掉 scope、凭证或 provider 不能从已撤销命令恢复权限。[通用命令入口](../src/command_handlers.v)拒绝省略 provider 的 event-only send，并拒绝把 Codex 普通 send 转为原始 WebSocket 发送，调用者使用既有 RPC/控制入口。fixture 保持测试计数语义，未知 provider 仍报错。

[桥接入口](../src/feishu_card_bridge_server_runtime.v)只能执行 Feishu 请求，其他 provider 在消耗凭证前拒绝；不能用 Feishu 创建凭证转投 Codex 或 fixture。空 scope 不发送到远端。原生及桥接 HTTP 完成只在原 InitialSend 仍有效时发布，结果代际必须等于准入时的签发代际。[桥接传输](../src/feishu_card_bridge_runtime.v)还要求成功、非空消息 ID 和原代际；缺字段、错误代际及失败确认均退休原连接。服务端也不能把空消息 ID 报告为成功提交。原有同 ID 冲突记录、重绑/撤销检查及不可变 sent 回执仍保护缓冲与目标的配对发布。

这是 wire 命令的兼容性收紧：包括一次性回复在内的旧无 scope 或无凭证 send 均被拒绝，生产者应先显式取得创建上下文；不在入站命令中补签，不查询新代际来刷新旧权限。桥接两端需同步升级。受认证 admin 和宿主内部低层发送 API 维持其独立可信入口，不能把这些 API 的直接发送能力解释为 worker 命令权限。Codex RPC 的业务授权仍为独立边界。

[状态回归](../src/feishu/raw_send_admission_test.v)、[真实执行器与桥接完成回归](../src/feishu_raw_send_boundary_test.v)及[真实 HTTP E2E](../tests/e2e/feishu_message_update_test.mjs)覆盖删 scope 重放、旧凭证、错误确认、空消息 ID、provider 转投及 HTTP 在途时连接替换和同 ID 重建。已在撤销前准入的外部 POST 仍可能完成并创建外部消息；本轮保证其迟到结果不能接管运行时新资源，不保证撤回外部副作用。

### PHP/TS 一次性回复可信创建上下文（2026-10-21）

[PHP OneShotReplyService](../examples/codexbot-app/lib/Service/OneShotReplyService.php)和[TS 回复上下文](../examples/codexbot-app-ts/lib/state.mjs)在构造新业务回复时各自分配独立临时 scope，并分别通过显式 admin HTTP 客户端和可信 host 签发一次性创建凭证。PHP 的普通文本、卡片、帮助和恢复提醒，以及 TS 的帮助、查询、选择和 busy/idle 等默认回复均接入此路径；长期任务与审批继续使用已捕获的流上下文。PHP 入站请求和 TS frame 的 Feishu 实例被捕获后随发送、清理传递，不再默认为其他实例。

[PHP 回复出口](../examples/codexbot-app/lib/Upstream/BotResponseHelper.php)与[TS 回复出口](../examples/codexbot-app-ts/lib/feishu-session-helpers.mjs)把一次性回复展开为 send 后紧跟同 scope、代际和实例的 clear，移除仅生产端使用的标记。临时回复不创建数据库任务。`feishu:reply:` 是保留的一次性回复命名空间：原生与桥接发送仍先消费凭证，并在原归属锁内校验完成时的 scope、代际、消息 ID 冲突及桥接连接；成功后直接结束该次发送，不注册流缓冲、Codex 目标或 sent 绑定发布。因此执行在 send 与 clear 之间中断、回执丢失或 clear 失败都不留下需后续命令回收的绑定。已经完成的一次性回复 clear 可以是无副作用的幂等空操作；旧清理不作用于其他代际或其他回复。纯序列化/展开不签发、不查询新代际；PHP 构造服务也拒绝把已带资源/凭证的命令当成新回复重新签发。签发失败直接失败，不回退为无 scope 发送。PHP 签发 POST 失败、响应丢失或解析/凭证校验失败时，用原始签发请求身份撤销，不重试签发，也不让撤销错误覆盖原错误；服务端撤销意图可先于迟到的签发到达。PHP/TS 的不可序列化回复内容在签发前失败。无法交付或无法撤销的未消费凭证最多保留原有 300 秒有效期；服务端容量限制与后续签发时过期清理限制保留量，重启更换 epoch，序列化不续期。不保证撤回已经准入的外部 HTTP 副作用。

真实 HTTP 回归发现独立 control listener 原先构造了第二个 App，导致 admin 签发和数据端消费处于不同 Feishu 注册表。[App owner 查询](../src/runtime_plan/query.v)现在仅在 control listener 没有业务 pipeline、且可用非 WebSocket 数据 App 唯一时借用其 App；executor、注册表、撤销和关闭归属随同共享。control 自有业务 pipeline、数据 owner 不可用或多个独立数据 App 时保持隔离，不自动选取或合并。本轮不增加跨 App 签发路由。

[PHP 协议/适配器检查](../tests/protocol/feishu-one-shot-reply.php)、[TS 协议检查](../tests/protocol/feishu-one-shot-reply.test.mjs)、[真实 TS 应用回归](../src/feishu_one_shot_producer_test.v)、[实例回归](../src/feishu_one_shot_instance_test.v)及[真实 PHP/TS E2E](../tests/e2e/feishu_one_shot_reply_test.mjs)覆盖捕获凭证、同代际清理、未发送撤销、消费后重放、删除 scope 重放和独立回复互不撤销；[查询测试](../src/runtime_plan/app_owner_query_test.v)与[App 生命周期测试](../src/multi_app_owner_test.v)覆盖 admin/data 共用注册表及只启动、关闭一次。

## Related Docs

- [`/Users/guweigang/Source/vhttpd/docs/OVERVIEW.md`](/Users/guweigang/Source/vhttpd/docs/OVERVIEW.md)
- [`/Users/guweigang/Source/vhttpd/README.md`](/Users/guweigang/Source/vhttpd/README.md)
- [`/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md`](/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md)
- [`/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md`](/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP.md`](/Users/guweigang/Source/vhttpd/docs/MCP.md)
