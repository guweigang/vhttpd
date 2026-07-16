# MCP Capability Negotiation Plan

这页讨论 `vhttpd` / `ProviderApp` 后续如何把 MCP 的能力协商做正式。

这里的“能力协商”包含两部分：

- server capability declaration
- client capability intake / gating

当前仓库里已经有了一个最小版本：

- `ProviderApp` 会根据已注册内容自动推导：
  - `tools`
  - `resources`
  - `prompts`
- `vhttpd` 会在 `initialize` 时把 `initialize.params.capabilities` 保存进 MCP session
- `/admin/runtime/mcp?details=1` 已经能看到 session 里的 `client_capabilities_json`

但还没有把这层发展成完整的 capability negotiation 模型。

## Terms

### Server Capability Declaration

server 在 `initialize` 返回里声明：

- 我支持什么能力
- 我支持哪些扩展字段
- 某些能力是否支持 `listChanged`

现在 `ProviderApp` 的 `effectiveCapabilities()` 已经在做最基础的 declaration。

### Client Capability

client 在 `initialize.params.capabilities` 里声明：

- 我支持接收什么
- 我支持哪些 client-side 功能
- 某些 request/notification 我能不能处理

这部分目前还没有被正式 intake 并参与 runtime gating。

## Why It Matters

如果没有 capability negotiation，server 很容易“想发什么就发什么”，但这不符合 MCP 的设计。

例如：

- client 没声明 `sampling`
  - server 不应该盲发 `sampling/createMessage`
- client 没声明 progress 相关能力
  - server 不应该假设进度通知一定有意义
- client 没声明某些 roots/resource 相关能力
  - server 不该基于这些能力建立工作流前提

所以 capability negotiation 的价值是：

- 更准确的协议边界
- 更好的兼容性
- 更清晰的 helper 行为

## Current State

目前这几层已经存在：

- `ProviderApp`
  - 自动声明：
    - `tools`
    - `resources`
    - `prompts`
- `initialize`
  - 已经会回 `serverInfo`
  - 已经会回 `capabilities`
- `sampling`
  - 已经有 builder / queue helper
  - 但还没有 capability gating
- `progress/log/request/notification`
  - 已经有 queue helper
  - 但也还没有 capability gating

## Recommended Split

### 1. `ProviderApp` owns server declaration

`ProviderApp` 应该继续负责：

- 自动推导 server capabilities
- 提供显式 capability 配置入口

例如后续可以增加：

- `capability(string $name, array $definition): self`
- `capabilities(array $map): self`

这样就能支持：

- 自动推导
- 显式覆盖
- 未来新能力的平滑接入

### 2. `vhttpd` owns client capability storage

client capabilities 最适合存到 `vhttpd` 的 MCP session state 里。

原因是：

- session 本来就在 `vhttpd`
- `GET /mcp` / `POST /mcp` / `DELETE /mcp` 都围绕 session 工作
- 后续 queue helper / runtime visibility / admin 也需要读这份状态

所以合理的数据位置是：

- `mcp_session.capabilities`

而不是：

- PHP worker 进程内内存

## Proposed Runtime Flow

### During `initialize`

1. client `POST /mcp` 发送 `initialize`
2. `vhttpd` 转给 `php-worker`
3. `ProviderApp` 返回：
   - `serverInfo`
   - `capabilities`
4. `vhttpd` 同时从 request 里提取：
   - `initialize.params.capabilities`
5. `vhttpd` 把 client capabilities 存入 session

也就是：

- server declaration 由 PHP 给出
- client declaration 由 `vhttpd` 保存

## Proposed Helper Gating

后续这几类 helper 应该开始和 client capability 协商挂钩：

### `queueSampling(...)`

只有当 client capability 表示支持 `sampling` 时，才推荐执行。

不一定非要在 helper 内强制抛错，但至少应该支持：

- runtime 校验
- 可选 strict mode

### `queueProgress(...)`

progress 是否需要 capability gating，取决于我们最终对 MCP 当前规范的解释和 client ecosystem 兼容经验。

建议第一步先做：

- soft gating
- warning / metrics

而不是立刻 hard fail。

### `queueRequest(...)`

某些 server -> client request 可能需要 method-specific gating。

例如：

- `sampling/createMessage`
  受 `sampling` 约束
- 未来别的 request
  可能有别的 capability 前提

所以更合适的模型是：

- `queueRequest(...)` 保持通用
- method-specific helper 负责声明自己的 capability prerequisite

## Suggested Implementation Order

### Phase N1: Session Storage

Status:

- done (minimum version)

在 `vhttpd` MCP session 里保存：

- `client_capabilities`

并把它暴露到：

- `/admin/runtime/mcp?details=1`

当前实现先使用原始 JSON 字符串快照：

- `client_capabilities_json`

这样不会过早把 nested capability schema 固化死。

### Phase N2: `ProviderApp` explicit server declaration

补：

- `capability(...)`
- `capabilities(...)`

并保留现有自动推导逻辑。

### Phase N3: Runtime helper gating

Status:

- partial
- `sampling/createMessage` 现在已经有最小 soft gating：
  - 如果 session 没声明 `sampling`
  - `vhttpd` 不会 hard fail
  - 但会记录 runtime warning metric
  - 并写一条 `mcp.capability.warning` 事件

先从最确定的一条开始：

- `sampling`

当前做法：

- soft gating only
- metric:
  - `mcp_sampling_capability_warnings_total`
- event log:
  - `mcp.capability.warning`
  - `warning_class = sampling_without_client_capability`

后续再考虑：

- 如果 session 没有 `client_capabilities.sampling`
  - strict mode: 返回错误
  - non-strict mode: 记录 warning / metric

### Phase N4: Observability

`/admin/runtime/mcp` 可继续补：

- session 是否完成 initialize
- session 保存了哪些 client capabilities
- capability gating rejections / warnings

## Practical Recommendation

现在最好的节奏不是立刻把所有 helper 都绑上 capability check，而是：

1. 先把 client capabilities 存起来
2. 先给 `sampling` 做最小 gating
3. 再看 `progress/log/request` 是否需要进一步 formalize

这样能避免过早把 helper 体系搞复杂。

## Related Docs

- [`/Users/guweigang/Source/vhttpd/docs/MCP.md`](/Users/guweigang/Source/vhttpd/docs/MCP.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_MVP_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/MCP_MVP_PLAN.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_SAMPLING_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/MCP_SAMPLING_PLAN.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md`](/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md)
