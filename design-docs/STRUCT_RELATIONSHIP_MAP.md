# vhttpd Major Struct Relationship Map

这页聚焦你最关心的内容：**主要结构体之间的关系图**（不是功能说明书）。

目标：快速回答

- 哪些 struct 是内核（transport + workpool）
- 哪些 struct 是应用层可插拔（provider / command handler）
- 命令从哪里进入、在哪里分发、如何执行
- 编译期开关（`no_*_routes`）会影响哪些结构

---

## 1) Core Runtime Struct Graph (Kernel-first)

```mermaid
flowchart TB
    Client["Client / Browser / Upstream"]

    subgraph Kernel["vhttpd Kernel"]
      App["App\n(main runtime state root)"]
      Server["server.v\nrun_server/bootstrap"]
      Pool["worker_pool\nmanaged_workers"]
      Transport["worker_transport\nframe/chunk/sse"]
      Upstream["upstream_runtime\nUpstreamRuntimeSession"]
      WsUp["websocket_upstream_runtime\nupstream ingress"]
      Admin["admin_runtime/admin_server\nruntime snapshots"]
    end

    subgraph Pluggable["Application Layer (Pluggable)"]
      ProviderIF["Provider interface\n(init/start/stop/snapshot)"]
      FeishuP["FeishuProvider\n→ FeishuProviderRuntime"]
      CodexP["CodexProvider\n→ CodexProviderRuntime"]
      OllamaP["OllamaProvider"]
    end

    Client --> Server
    Server --> App
    App --> Pool
    App --> Transport
    App --> Upstream
    App --> WsUp
    App --> Admin

    Server --> ProviderIF
    ProviderIF --> FeishuP
    ProviderIF --> CodexP
    ProviderIF --> OllamaP
    App --> ProviderIF
```

说明：

- `App` 是 runtime 根结构体，统一持有 transport/workpool/session/provider 状态。
- provider 是应用层适配，不反向定义 kernel 行为。
- provider 状态封装在各自的 runtime struct 中（如 `FeishuProviderRuntime`、`CodexProviderRuntime`），不再散落在 `App` 上。
- `App` 仅保留 provider 级别的 mutex（`feishu_mu`、`codex_mu`）和对应的 runtime 实例。

---

## 2) Command Execution Struct Graph (Object + Static Method Style)

```mermaid
flowchart LR
    WReq["WorkerWebSocketUpstreamCommand[]"] --> CE["CommandExecutor\n(new + execute)"]

    CE --> Spec["ProviderSpec\n(route_kind + command_matchers)"]

    CE --> CH["CodexCommandHandler\n(object method execute)"]
    CE --> FH["FeishuCommandHandler\n(object method execute)"]
    CE --> OH["ollama handler\n(GenericUpstreamCommandHandler instance)"]
    CE --> GH["GenericUpstreamCommandHandler\n(object method execute)"]

    CE --> Snap["WebSocketUpstreamCommandActivity\n(snapshot)"]
```

说明：

- 构造/路由决策使用静态方法（`TypeName.method()`）。
- 执行行为使用对象方法（`fn (mut x T) ...`）。

---

## 3) Provider Bootstrap + Compile-time Gate Graph

```mermaid
flowchart TB
    Boot["bootstrap_providers(mut app)"] --> FGate{"!no_feishu_routes ?"}
    Boot --> CGate{"!no_codex_routes ?"}
    Boot --> OGate{"!no_ollama_routes ?"}

    FGate -->|true| FReg["register feishu provider"]
    CGate -->|true| CReg["register codex provider"]
    OGate -->|true| OReg["register ollama provider"]

    FGate -->|false| FSkip["skip at compile-time"]
    CGate -->|false| CSkip["skip at compile-time"]
    OGate -->|false| OSkip["skip at compile-time"]
```

对应结构关系：

- `CommandExecutor.feishu_route_enabled/codex_route_enabled/ollama_route_enabled`
- `ProviderSpec.route_kind` + `ProviderSpec.command_matchers`
- `provider_bootstrap.v` 的 provider 注册 gate

---

## 4) Runtime Session / Observability Struct Graph

```mermaid
flowchart LR
    App["App"] --> URS["upstream_sessions\nmap[string]UpstreamRuntimeSession"]
    URS --> Sess["UpstreamRuntimeSession\n(id/request_id/trace_id/role/provider/...)"]

    AdminUp["/admin/runtime/upstreams"] --> Snap["admin_upstreams_snapshot(...)"]
    Snap --> Sess

    Filters["query filters\nrole/provider"] --> Snap
```

说明：

- 现在 `UpstreamRuntimeSession` 已有 `role/provider`，用于明确语义边界。
- admin 查询支持按 `role/provider` 过滤，利于多 provider 并存时排障。

---

## 5) Provider Runtime Encapsulation Pattern

```mermaid
flowchart TB
    App["App"]

    subgraph FeishuEncap["Feishu (encapsulated)"]
      FMu["feishu_mu sync.Mutex"]
      FRT["feishu_runtime map[string]FeishuProviderRuntime"]
    end

    subgraph CodexEncap["Codex (encapsulated)"]
      CMu["codex_mu sync.Mutex"]
      CRT["codex_runtime CodexProviderRuntime"]
    end

    subgraph CodexRTFields["CodexProviderRuntime"]
      CConf["config:\nenabled, url, model, effort,\ncwd, approval_policy, sandbox,\nreconnect_delay_ms, flush_interval_ms"]
      CConn["connection state:\nconnected, ws_url, conn, thread_id,\ninitialized, active_stream_id,\nconnect_attempts, received_frames, ..."]
      CState["runtime state:\nstream_map, rpc_id_counter,\npending_rpcs, err_bursts,\nerr_pending_flushes, thread_stream_map"]
    end

    App --> FMu
    App --> FRT
    App --> CMu
    App --> CRT
    CRT --> CConf
    CRT --> CConn
    CRT --> CState
```

说明：

- 每个 provider 的运行时状态收敛到一个专属 struct（如 `CodexProviderRuntime`），不再在 `App` 上散列字段。
- `sync.Mutex` 保留在 `App` 上（`feishu_mu`、`codex_mu`），不嵌入 runtime struct 内部，避免 V 语言对嵌套 mutex 的潜在限制。
- `CodexProviderRuntime` 内部分三层：config（TOML/CLI 来源）、connection state（WebSocket 生命周期）、runtime state（maps/counters/error 聚合）。
- `ollama_enabled` 目前仍是 `App` 上的独立字段，未来可按相同模式封装。

---

## 6) Practical Reading Order

建议按这个顺序读源码：

1. `src/main.v`（`App` / runtime root structs）
2. `src/server.v` + `src/provider_bootstrap.v`（启动与 provider 挂载）
3. `src/command_executor.v` + `src/command_handlers.v`（命令分发与执行）
4. `src/upstream_runtime.v` + `src/websocket_upstream_runtime.v`（session 与 upstream ingress）
5. `src/feishu_runtime.v` + `src/codex_runtime.v`（provider runtime 封装）
6. `src/admin_runtime.v` + `src/admin_server.v`（可观测输出）
