# Phase 6: Command Module Extraction

## Context

vhttpd 模块化重构中，Phase 5 (Provider 接口解耦) 已完成。Phase 6 目标是将 `CommandExecutor` 从 `module main` 提取到 `src/command/` 子模块，使用 RuntimeContext 闭包模式替代直接的 `&App` 指针依赖。

`command_handlers.v` (3 个 handler struct) 因耦合 29+ 个 App 方法，本阶段保留在 main 中，待 Phase 8 域运行时提取时一并迁移。

## 核心约束：循环依赖

`provider/spec.v` 已导入 `command` (用于 `NormalizedCommand`)，因此 `command/` **不能**导入 `provider/`。

但 `CommandExecutor` 当前使用 `provider.ProviderRouteKind`、`provider.CommandMatcher` 等类型。

**解决方案：类型反转** — 将路由类型从 `provider/types.v` 移到 `command/routing.v`，`provider/types.v` 改用 type alias 指向 `command/`。V 的 type alias 是透明的，现有调用点零改动。

## 实现步骤

### Step A: 类型迁移（前置条件，零行为变化）

**1. 新建 `src/command/routing.v`**

从 `src/provider/types.v` (lines 5-44) 移入以下类型：

```v
module command

pub enum ProviderRouteKind {
    codex
    feishu
    openai
    ollama
    generic
}

pub fn (route_kind ProviderRouteKind) snapshot_value() string { ... }

pub enum CommandMatcherKind {
    prefix
    exact
}

pub struct CommandMatcher {
pub:
    kind  CommandMatcherKind
    value string
}

pub fn (m CommandMatcher) matches(command_type string) bool { ... }
```

无需额外 import（类型自包含）。

**2. 修改 `src/provider/types.v`**

- 删除 `ProviderRouteKind`、`CommandMatcherKind`、`CommandMatcher` 定义及其方法
- 添加 `import command`
- 添加 type alias：
  ```v
  pub type ProviderRouteKind = command.ProviderRouteKind
  pub type CommandMatcherKind = command.CommandMatcherKind
  pub type CommandMatcher = command.CommandMatcher
  ```
- 其余内容（`AdminProviderSpecSnapshot`、`ProviderInstanceSpec` 等）不变

**验证**: `make build && make test-fast` — 所有现有引用通过 type alias 透明解析。

---

### Step B: Command 模块核心（新建文件）

**1. 新建 `src/command/context.v`**

```v
module command

import transport
import executor

// HandlerFn replaces provider.ProviderCommandHandler interface within command/
pub type HandlerFn = fn (transport.WorkerWebSocketUpstreamCommand, NormalizedCommand, mut executor.WebSocketUpstreamCommandActivity) (bool, string)

// InstanceOutcome is a lightweight result for instance operations
pub struct InstanceOutcome {
pub:
    provider string
    instance string
}

// RuntimeContext carries closures that bridge command/ to App in main
pub struct RuntimeContext {
pub:
    route_resolver      fn (NormalizedCommand) ProviderRouteKind = unsafe { nil }
    route_handler       fn (ProviderRouteKind) ?HandlerFn = unsafe { nil }
    instance_upsert_apply fn (string, string, string, string) !InstanceOutcome = unsafe { nil }
    instance_ensure     fn (string, string) !InstanceOutcome = unsafe { nil }
}
```

**2. 新建 `src/command/executor.v`**

核心结构（~220 行，从 `command_executor.v` 迁入）：

```v
module command

import transport
import executor
import time
import log

pub struct CommandExecutor {
    ctx             RuntimeContext
    codex_enabled   bool
    feishu_enabled  bool
    ollama_enabled  bool
}

pub fn CommandExecutor.new(ctx RuntimeContext) CommandExecutor { ... }
pub fn CommandExecutor.codex_route_enabled() bool { $if no_codex_routes ... }
pub fn CommandExecutor.feishu_route_enabled() bool { ... }
pub fn CommandExecutor.ollama_route_enabled() bool { ... }

pub fn (mut exec CommandExecutor) execute(source_activity_id string, ctx executor.DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) ([]executor.WebSocketUpstreamCommandActivity, string)
fn (exec CommandExecutor) new_snapshot(...) executor.WebSocketUpstreamCommandActivity
pub fn (mut exec CommandExecutor) execute_commands(source_activity_id string, commands []transport.WorkerWebSocketUpstreamCommand) ([]executor.WebSocketUpstreamCommandActivity, string)
fn (mut exec CommandExecutor) route_from_normalized(normalized NormalizedCommand) ProviderRouteKind
fn (mut exec CommandExecutor) route_from_specs(command transport.WorkerWebSocketUpstreamCommand) ProviderRouteKind
fn (mut exec CommandExecutor) execute_instance_command(normalized NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string)
fn (mut exec CommandExecutor) execute_routed_command(route ProviderRouteKind, command transport.WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string)
```

关键变化：
- `route_from_normalized` → 一行委托 `exec.ctx.route_resolver(normalized)`
- `execute_instance_command` → 使用 `ctx.instance_upsert_apply` / `ctx.instance_ensure` 闭包
- `execute_routed_command` → 使用 `ctx.route_handler(route)` 查找 HandlerFn
- 无 `&App` 字段，无 `provider` 模块导入

---

### Step C: 切换（原子操作，必须一起完成）

**1. 重写 `src/command_executor.v`** — 精简为 thin wrapper（~70 行）

保留内容：
- `pub fn (mut app App) execute_command_envelopes(...)` — 构建 context + 委托
- `fn (mut app App) execute_command_envelopes_with_snapshots(...)` — 同上

新增：
- `fn (mut app App) build_command_context() command.RuntimeContext` — 闭包构建器

删除：
- `CommandExecutor` struct 定义和所有方法（已移入 `command/executor.v`）

**`build_command_context()` 闭包映射**：

| 闭包 | 捕获 | 逻辑 |
|------|------|------|
| `route_resolver` | `[mut app]` | `is_codex_control()` + `provider_specs_copy()` 遍历 + matcher 匹配 → `ProviderRouteKind` |
| `route_handler` | `[mut app]` | match route → `app.get_provider_spec(name)` 获取 handler → 包装为 `HandlerFn` |
| `instance_upsert_apply` | `[mut app]` | `provider_instance_upsert()` + `provider_instance_apply()` 组合 |
| `instance_ensure` | `[mut app]` | `provider_instance_ensure()` |

**2. 修改 `src/websocket_upstream_runtime.v` (line 164)**

```v
// 前:
mut exec := CommandExecutor.new(mut app)
// 后:
mut exec := command.CommandExecutor.new(app.build_command_context())
```

**3. 修改 `src/command_executor_test.v`**

10+ 个调用点：
```v
// 前:
mut exec := CommandExecutor.new(mut app)
// 后:
ctx := app.build_command_context()
mut exec := command.CommandExecutor.new(ctx)
```

handler 直接测试（CodexCommandHandler, FeishuCommandHandler, GenericUpstreamCommandHandler）不变 — 它们仍在 main 中。

**验证**: `make build && make test-fast`

---

## 关键文件清单

| 文件 | 操作 | 行数变化 |
|------|------|---------|
| `src/command/routing.v` | 新建 | +40 |
| `src/command/context.v` | 新建 | +30 |
| `src/command/executor.v` | 新建 | +220 |
| `src/command_executor.v` | 重写 | -195 (265→70) |
| `src/provider/types.v` | 修改 | -5 (删除定义，加 alias) |
| `src/command_executor_test.v` | 修改 | +20 |
| `src/websocket_upstream_runtime.v` | 修改 | +1 |

## 不变文件

| 文件 | 原因 |
|------|------|
| `src/command_handlers.v` | 保留在 main（Phase 8 域迁移） |
| `src/command_test.v` | 测试 NormalizedCommand 纯函数 |
| `src/provider_bootstrap.v` | type alias 透明 |
| `src/provider_spec.v` | type alias 链仍有效 |
| `src/provider/spec.v` | 已导入 command，无变化 |

## 验证

```bash
make build          # 编译通过
make test-fast      # 全部 18+ 测试通过
```

确认 `command/` 模块不导入 `provider/`：
```bash
grep -r 'import provider' src/command/  # 应无结果
```
