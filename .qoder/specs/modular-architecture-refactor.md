# vhttpd 模块化架构重构方案

## Context

vhttpd 当前 `module main` 中有 ~65 个文件、~18,000 行运行时逻辑。`App` struct 是一个 God Object，几乎所有函数都直接操作它。虽然已有 19 个子目录模块，但它们只包含类型定义和纯函数，所有包含副作用的逻辑都留在 main 中。

本次重构目标：**将全部运行时逻辑下沉到子模块**，`module main` 只保留：
- `App` struct 定义
- veb 路由处理函数（HTTP 入口签名）
- 启动编排（`main()` / `run_server()` / `build_app_runtime()`）
- RuntimeContext 闭包构建器

## 解耦模式：闭包 RuntimeContext

每个子模块定义自己的 `RuntimeContext` struct，包含 `fn` 字段作为闭包。`module main` 构建闭包捕获 `&App`，子模块通过闭包间接访问 App 能力。此模式已在 `src/admin/context.v` 中验证。

```
// 子模块定义（如 src/worker/context.v）：
pub struct RuntimeContext {
pub:
    emit  fn (string, map[string]string) = unsafe { nil }
    // ... 子模块需要的其他能力
}

// main 中构建闭包：
fn build_worker_runtime_context(mut app App) worker.RuntimeContext {
    return worker.RuntimeContext{
        emit: fn [mut app](kind string, fields map[string]string) {
            app.emit(kind, fields)
        },
    }
}
```

`executor.AppFacade` 接口保持不变，仍用于 `LogicExecutor` 实现。新增的 RuntimeContext 是闭包 struct 而非 interface，避免了 V 接口限制（无 mut receiver 问题、无循环导入）。

## 目标模块结构

| 目录 | 模块名 | 职责 | 当前状态 |
|------|--------|------|----------|
| `src/config/` | config | TOML 配置、CLI 参数、运行时配置 | 已完成 |
| `src/transport/` | transport | 线协议类型、帧编解码、错误分类 | 已完成 |
| `src/state_store/` | state_store | 通用 TTL 键值存储 | 已完成 |
| `src/jsonutils/` | jsonutils | JSON 工具 | 已完成 |
| `src/logging/` | logging | 日志配置 | 已完成 |
| `src/stats/` | stats | HTTP 统计计数器 | 已完成 |
| `src/assets/` | assets | 静态文件服务状态 | 已完成 |
| `src/plugins/` | plugins | 插件状态类型 | 已完成 |
| `src/worker/` | worker | Worker 后端池、队列、传输、调度、生命周期 | **需扩展** |
| `src/executor/` | executor | LogicExecutor 接口、生命周期、注册表、配置 | **需扩展** |
| `src/stream/` | stream | HTTP 流：SSE、透传、调度流 | **新建** |
| `src/upstream/` | upstream | 上游计划执行、ExecState、流媒体 | **需扩展** |
| `src/provider/` | provider | Provider 接口、注册、引导、配置、实例、调度 | **需扩展** |
| `src/codex/` | codex | Codex WebSocket 上游集成 | **需扩展** |
| `src/feishu/` | feishu | 飞书 Bot 平台集成、卡片桥 | **需扩展** |
| `src/mcp_protocol/` | mcp_protocol | MCP 协议 HTTP 处理、会话管理 | **需扩展** |
| `src/openai/` | openai | OpenAI API 协议网关、路由代理 | **需扩展** |
| `src/ws/` | ws | WebSocket Hub、调度、上游客户端循环 | **需扩展** |
| `src/admin/` | admin | Admin HTTP 服务器、内部管理、Worker 管理 | **需扩展** |
| `src/command/` | command | 命令执行器、命令处理器 | **需扩展** |
| `src/dispatch/` | dispatch | 内核调度、调度上下文、故障分类 | **新建** |
| `src/server_lifecycle/` | server_lifecycle | 服务器启停、配置解析、钩子 | **新建** |
| `src/db/` | db | DB Provider 运行时（从 dbsrc/ 合并） | **新建** |
| `src/plugin/` | plugin | 插件运行时 | **新建** |

## 分阶段执行计划

每个阶段完成后必须：`make build` 编译通过 + `make test-fast` 测试通过。

---

### Phase 1: 服务器生命周期模块（最低耦合）

**目标**：提取配置解析和服务器启停的纯逻辑。

**新建模块** `src/server_lifecycle/`：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `server_runtime_config.v` | `server_lifecycle/runtime_config.v` | ~250 |
| `multi_server_runtime_config.v` | `server_lifecycle/multi_config.v` | ~100 |

**移到 executor/**：
| `executor_runtime_plan.v` | `executor/runtime_plan.v` | ~150 |
| `executor_config.v` | `executor/config.v` | ~150 |

**移到 provider/**：
| `provider_config.v` | `provider/config.v` | ~200 |

**保留在 main**（薄包装）：
- `server_runtime_orchestrator.v` — 调用子模块函数的 5 行入口
- `server_startup_hooks.v` / `server_shutdown_hooks.v` — 薄编排层
- `multi_server_runtime_orchestrator.v` — 多监听器循环

**解耦方式**：配置解析函数仅依赖 `config`、`executor`、`provider` 类型，不需要 App。直接移入即可。

**验证**：`make build && make test-fast`

---

### Phase 2: Worker 后端模块

**目标**：将 Worker 池管理、队列、传输操作提取为自包含模块。

**移到 `src/worker/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `worker_backend_pool.v` | `worker/pool.v` | ~300 |
| `worker_backend_queue.v` | `worker/queue.v` | ~200 |
| `worker_backend_runtime.v` | `worker/runtime.v` | ~250 |
| `worker_backend_transport.v` | `worker/transport_ops.v` | ~200 |
| `worker_backend_dispatch.v` | `worker/dispatch.v` | ~150 |

**新建**：`src/worker/context.v` — RuntimeContext
```
RuntimeContext 闭包字段：
- emit(kind, fields)
- on_worker_request_started(socket_path)
- on_worker_request_finished(socket_path)
```

**方法重构**：`fn (mut app App)` 方法改为 `fn (mut rt worker.WorkerBackendRuntime, ctx worker.RuntimeContext)` 或模块内自由函数。

**同步移到 transport/**：`WorkerBackendErrorClassifier` — 纯字符串匹配，无 App 依赖。

**验证**：`make build && make test-fast && make test-inproc`

---

### Phase 3: Executor 家族

**目标**：提取执行器生命周期、注册表和配置。

**移到 `src/executor/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `executor_lifecycle.v` | `executor/lifecycle.v` | ~200 |
| `executor_registry.v` | `executor/registry.v` | ~150 |
| `executor_bridge.v` | **保留在 main**（voidptr 桥接点） | — |

**新建**：`src/executor/context.v` — RuntimeContext
```
RuntimeContext 闭包字段：
- emit(kind, fields)
- worker_backend_start_pools(sockets, cmd, env, ...)
- worker_backend_stop_pools()
```

**接口变更**：`LogicExecutorLifecycle` 接口的 `start(mut app App)` 改为 `start(mut ctx RuntimeContext)`。

**验证**：`make build && make test-fast`

---

### Phase 4: Stream 和 Upstream 模块

**目标**：HTTP 流式响应层独立。

**新建 `src/stream/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `stream_runtime.v` | `stream/runtime.v` | ~600 |

**新建文件**：
- `src/stream/context.v` — RuntimeContext
- `src/stream/writer.v` — HttpStreamWriter（SSE/chunked/headers 写入器）

```
stream.RuntimeContext 闭包字段：
- emit(kind, fields)
- dispatch_open(...) -> response
- dispatch_next(...) -> response
- dispatch_close(...) -> response
- write_sse(conn, frame)
- write_chunk(conn, data)
- write_headers(ctx, status, ctype, headers, chunked)
```

**移到 `src/upstream/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `upstream_runtime.v` | `upstream/runtime.v` | ~600 |

**扩展** `src/upstream/context.v`：
```
upstream.RuntimeContext 闭包字段：
- emit(kind, fields)
- ws_hub_upstream_sessions_access()
- stat_counters_inc()
```

**验证**：`make build && make test-fast`

---

### Phase 5: Provider 系统（核心解耦）

**目标**：Provider 接口从 `App` 解耦，提取注册/引导/调度。

**接口变更**（原子操作，影响所有 4 个 provider adapter）：

```v
// 变更前（provider_spec.v in main）：
pub interface ProviderRuntime {
    start(mut app App) !
    stop(mut app App) !
    snapshot(mut app App) string
}

// 变更后（provider/spec.v in provider/）：
pub interface ProviderRuntime {
    start(mut ctx RuntimeContext) !
    stop(mut ctx RuntimeContext) !
    snapshot(mut ctx RuntimeContext) string
}
```

同理 `Provider` 接口和 `ProviderCommandHandler` 接口。

**移到 `src/provider/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `provider_registry.v` | `provider/registry.v` | ~250 |
| `provider_bootstrap.v` | `provider/bootstrap.v` | ~300 |
| `provider_spec.v` | `provider/spec.v` | ~200 |
| `provider_instance_runtime.v` | `provider/instance_runtime.v` | ~200 |
| `provider_runtime_dispatch.v` | `provider/runtime_dispatch.v` | ~350 |

**新建**：`src/provider/context.v`
```
provider.RuntimeContext 闭包字段：
- emit(kind, fields)
- provider_host_access() -> &ProviderHost
- feishu_state_access() -> &FeishuState
- codex_state_access() -> &CodexState
- db_runtime_access() -> &DbProviderRuntime
- logic_executor_kind() -> string
- provider_runtime_snapshot(name) -> ?string
- command_executor_new() -> CommandExecutor
- ws_hub_upstream_start(provider, instance)
```

**Provider adapter 迁移**：各 adapter（FeishuProvider、CodexProvider、OllamaProvider、DbProvider）的实现逻辑移入各自域模块（codex/、feishu/ 等），main 中只保留 adapter 注册调用。

**验证**：`make build && make test-fast`

---

### Phase 6: Command 模块

**移到 `src/command/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `command_executor.v` | `command/executor.v` | ~400 |
| `command_handlers.v` | `command/handlers.v` | ~400 |

**新建**：`src/command/context.v`
```
command.RuntimeContext 闭包字段：
- provider_specs_copy() -> []ProviderSpec
- provider_enabled(name) -> bool
- codex_handler() -> ProviderCommandHandler
- feishu_handler() -> ProviderCommandHandler
```

**验证**：`make build && make test-fast`

---

### Phase 7: WebSocket 运行时

**移到 `src/ws/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `websocket_runtime.v` | `ws/runtime_ops.v` | ~600 |
| `websocket_upstream_runtime.v` | `ws/upstream_runtime.v` | ~800 |

**新建**：`src/ws/context.v`
```
ws.RuntimeContext 闭包字段：
- emit(kind, fields)
- kernel_dispatch_websocket_upstream_handled(req) -> outcome
- kernel_dispatch_websocket_event(frame) -> response
- execute_websocket_dispatch_commands(cmds) -> result
- provider_runtime_pull_url(name, instance) -> string
- provider_runtime_on_connecting/connected/disconnected(...)
- feishu_provider_handle_message(...)
- codex_provider_handle_text_message(...)
```

**WebSocket Bridge State 迁移**：`WebSocketBridgeState` 和 `WebSocketDispatchBridgeState` 移入 `ws/` 模块，回调函数随之迁移。

**验证**：`make build && make test-fast`

---

### Phase 8: 域运行时（最大提取）

**Codex → `src/codex/`**：
| `codex_runtime.v` (1403行) | `codex/runtime.v` + `codex/upstream.v` |

**Feishu → `src/feishu/`**：
| `feishu_runtime.v` (1810行) | `feishu/runtime.v` |
| `feishu_card_bridge.v` (825行) | `feishu/card_bridge.v` |

**MCP → `src/mcp_protocol/`**：
| `mcp_runtime.v` (516行) | `mcp_protocol/runtime.v` |

**OpenAI → `src/openai/`**：
| `openai_runtime.v` (2430行) | `openai/runtime.v` + `openai/handler.v` |

每个域模块新增 `context.v`，包含域专属闭包。

**验证**：`make build && make test-fast && make test-inproc && make test-codexbot`

---

### Phase 9: Kernel Dispatch 模块

**新建 `src/dispatch/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `kernel_dispatch.v` | `dispatch/kernel.v` | ~350 |
| `dispatch_context.v` | `dispatch/context.v` | ~250 |

**新建**：`src/dispatch/runtime_context.v`
```
dispatch.RuntimeContext 闭包字段：
- logic_executor_dispatch_stream/mcp/websocket_upstream/websocket_event(...)
- ws_hub_rooms_snapshot/meta_snapshot/presence_snapshot(...)
- emit(kind, fields)
- execute_command_envelopes(...)
```

**验证**：`make build && make test-fast`

---

### Phase 10: Admin 完整提取

**移到 `src/admin/`**：

| 源文件 | 目标 | 行数 |
|--------|------|------|
| `admin_server.v` | `admin/server.v` | ~600 |
| `admin_workers.v` | `admin/workers.v` | ~200 |
| `admin_runtime.v` | `admin/runtime.v` | ~300 |
| `internal_admin.v` | `admin/internal.v` | ~500 |

**扩展** `src/admin/context.v` — 增加 worker admin 操作和内部 admin 调度闭包。

**验证**：`make build && make test-fast`

---

### Phase 11: DB 模块合并

**新建 `src/db/`**：

| 源文件 | 目标 |
|--------|------|
| `db_runtime.v` (main stub) | `db/runtime.v` |
| `dbsrc/db_driver.v` | `db/driver.v` |
| `dbsrc/db_runtime.v` | `db/server.v` |

使用 V 的 `$if enable_db` 条件编译。无 driver flag 时编译为 stub。

**验证**：`make build && WITH_DB=0 make build`

---

### Phase 12: Plugin 运行时

| `plugin_runtime.v` | `plugin/runtime.v` | ~200 |

**验证**：`make build && make test-fast`

---

## 重构完成后 main 中保留的文件

| 文件 | 职责 |
|------|------|
| `server.v` | `fn main()`、`run_server()`、`run_single_server()`、锁层级文档 |
| `main.v` | `App` struct、veb 路由处理函数（proxy_get/post/...、health、dispatch、events_stream） |
| `app_states.v` | 子模块类型别名桥 |
| `app_runtime_builder.v` | `build_app_runtime()` — 组合根 |
| `executor_bridge.v` | AppFacadeWrapper voidptr 桥（故意的耦合点） |
| `server_runtime_orchestrator.v` | 薄编排层（调用子模块函数） |
| `server_startup_hooks.v` | 启动钩子（薄层） |
| `server_shutdown_hooks.v` | 关闭钩子（薄层） |
| `multi_server_runtime_orchestrator.v` | 多监听器循环（薄层） |
| `*_test.v` | 测试文件 |

预计 ~10-12 个文件，~2,000 行。

## 跨切面处理

### 事件发射（app.emit）
每个 RuntimeContext 包含 `emit` 闭包字段，无需独立事件总线。

### 锁层级
锁保留在各 state struct 上（`WorkerState.mu`、`HubState.mu` 等），这些 struct 在各自子模块中。RuntimeContext 闭包捕获 state 引用，子模块锁定自己的 state。

### 错误分类
`WorkerBackendErrorClassifier` 移入 `src/transport/`（纯字符串匹配，无 App 依赖）。

### 类型别名
`app_states.v` 中的别名保留在 main，供 App struct 引用子模块类型。

## 验证策略

每个阶段完成后执行：
```bash
make build          # 编译通过
make test-fast      # 单元测试通过
```

Phase 8 完成后额外执行：
```bash
make test-inproc    # VJSX 进程内执行器测试
make test-codexbot  # Codex 集成测试
```

最终验证：
```bash
make prod           # 生产构建
WITH_DB=0 make build # 无 DB 构建
```

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 循环导入 | 每个子模块自定义 RuntimeContext，不导入其他子模块 |
| V 编译器接口 bug | RuntimeContext 使用闭包 struct 而非 interface |
| 全量破坏测试 | 每阶段独立可编译可测试，叶模块优先 |
| WebSocket 回调 voidptr | Bridge state 和回调随 ws/ 模块一起迁移 |
| Provider 接口变更波及 | Phase 5 原子变更，4 个 adapter 同步更新 |
| 条件编译标志 | 保留在特性所在模块中 |
