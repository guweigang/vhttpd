# MCP in `vhttpd`

这页是 `vhttpd` 的 MCP 总览页。

当前定位很明确：

- `vhttpd` 只做 MCP 的 transport/runtime
- PHP worker 负责 MCP method handling
- `stdio` 不进 `vhttpd`
  - 更适合后续放到 `vshx`

## Current Scope

现在已经落地的是 `Streamable HTTP` 方向：

- `POST /mcp`
- `GET /mcp`
- `DELETE /mcp`
- `Mcp-Session-Id`
- `text/event-stream`
- `/admin/runtime/mcp`

不在 `vhttpd` 当前范围内的：

- MCP `stdio`
- OAuth / Registry / provider-specific application logic
- 把 `vhttpd` 做成 MCP 业务框架

## Runtime Boundary

职责分层：

- `vhttpd`
  - 持有 HTTP/SSE transport
  - 管理 MCP session
  - 校验 `MCP-Protocol-Version`
  - 校验 `Origin`
  - 执行 `DELETE /mcp`
  - 暴露 `/admin/runtime/mcp`
- php-worker
  - 处理 `mode = mcp`
  - 返回 JSON-RPC body / queued notifications / session metadata
- PHP userland
  - 使用 `VSlim\Mcp\App`
  - 注册 tools / resources / prompts

## What `sampling` Means Here

在 MCP 里，`sampling` 不是普通 notification。

它更接近：

- server -> client 的 request
- server 请求 client 侧的模型能力

也就是：

- `tools/call`
  更像 client 问 server 要能力
- `sampling/createMessage`
  更像 server 问 client 要模型生成能力

在 `vhttpd` 当前实现里，`sampling` 的支持边界是：

- 可以由 PHP userland 通过 `VSlim\Mcp\App::samplingRequest(...)` / `queueSampling(...)` 构造
- 可以进入 MCP session queue
- 可以通过 `GET /mcp` 的 SSE stream 发送给 client
- 可以记录 client 是否在 `initialize.params.capabilities` 里声明了 `sampling`
- 当前只做 transport/runtime relay，不在 `vhttpd` 内部执行模型推理

## Implemented Phases

### Phase A

- `POST /mcp`
- JSON-only request/response
- `initialize`
- basic JSON-RPC dispatch

### Phase B

- `GET /mcp`
- `Mcp-Session-Id`
- SSE session stream
- queued server notifications

### Phase C

- `/admin/runtime/mcp`
- session TTL / max_sessions / max_pending_messages
- `sampling_capability_policy = warn|drop|error`
- `Origin` allowlist
- `DELETE /mcp`
- pressure metrics
- client capabilities snapshot in MCP session details
- soft warning metric for `sampling` without declared client capability

## PHP Helper API

当前高层 helper 在：

- [`/Users/guweigang/Source/vhttpd/php/package/src/VSlim/Mcp/App.php`](/Users/guweigang/Source/vhttpd/php/package/src/VSlim/Mcp/App.php)

可直接注册：

- `tool(...)`
- `resource(...)`
- `prompt(...)`
- `register(...)`
  - 用于完全自定义 method

现在 `VSlim\Mcp\App` 已经内建支持：

- `initialize`
- `ping`
- `tools/list`
- `tools/call`
- `resources/list`
- `resources/read`
- `prompts/list`
- `prompts/get`

## Example Entry

完整示例在：

- [`/Users/guweigang/Source/vhttpd/examples/mcp-app.php`](/Users/guweigang/Source/vhttpd/examples/mcp-app.php)
- [`/Users/guweigang/Source/vhttpd/examples/config/mcp.toml`](/Users/guweigang/Source/vhttpd/examples/config/mcp.toml)
- [`/Users/guweigang/Source/vhttpd/examples/README.md`](/Users/guweigang/Source/vhttpd/examples/README.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_RUNBOOK.md`](/Users/guweigang/Source/vhttpd/docs/MCP_RUNBOOK.md)

它现在已经覆盖：

- `tools`
- `resources`
- `prompts`
- session SSE notification
- sampling / progress / log / queued request helpers
- `/admin/runtime/mcp`

## Test Entry

focused helper regression:

- [`/Users/guweigang/Source/vphpx/vslim/tests/test_php_worker_mcp_dispatch.phpt`](/Users/guweigang/Source/vphpx/vslim/tests/test_php_worker_mcp_dispatch.phpt)

phase A e2e skeleton:

- [`/Users/guweigang/Source/vphpx/vslim/tests/test_vhttpd_mcp_phase_a.phpt`](/Users/guweigang/Source/vphpx/vslim/tests/test_vhttpd_mcp_phase_a.phpt)

phase B SSE/session skeleton:

- [`/Users/guweigang/Source/vphpx/vslim/tests/test_vhttpd_mcp_phase_b_sse.phpt`](/Users/guweigang/Source/vphpx/vslim/tests/test_vhttpd_mcp_phase_b_sse.phpt)

phase C admin/runtime:

- [`/Users/guweigang/Source/vphpx/vslim/tests/test_httpd_admin_runtime_mcp.phpt`](/Users/guweigang/Source/vphpx/vslim/tests/test_httpd_admin_runtime_mcp.phpt)
- [`/Users/guweigang/Source/vphpx/vslim/tests/test_vhttpd_mcp_origin_delete.phpt`](/Users/guweigang/Source/vphpx/vslim/tests/test_vhttpd_mcp_origin_delete.phpt)

## Related Docs

设计与实施细节：

- [`/Users/guweigang/Source/vhttpd/docs/MCP_MVP_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/MCP_MVP_PLAN.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_SAMPLING_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/MCP_SAMPLING_PLAN.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md`](/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_CAPABILITY_NEGOTIATION_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/MCP_CAPABILITY_NEGOTIATION_PLAN.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_RUNBOOK.md`](/Users/guweigang/Source/vhttpd/docs/MCP_RUNBOOK.md)

stream/runtime 背景：

- [`/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md`](/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md)
- [`/Users/guweigang/Source/vhttpd/docs/STREAM_PHASE2_IMPLEMENTATION_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/STREAM_PHASE2_IMPLEMENTATION_PLAN.md)
- [`/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md`](/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md)

## Recommendation

如果你是第一次接触这套 MCP 支持，推荐阅读顺序：

1. 先看这页
2. 先跑 [`/Users/guweigang/Source/vhttpd/docs/MCP_RUNBOOK.md`](/Users/guweigang/Source/vhttpd/docs/MCP_RUNBOOK.md)
3. 再看 [`/Users/guweigang/Source/vhttpd/examples/README.md`](/Users/guweigang/Source/vhttpd/examples/README.md) 里的 MCP 示例
4. 再看 [`/Users/guweigang/Source/vhttpd/php/package/README.md`](/Users/guweigang/Source/vhttpd/php/package/README.md) 里的 `VSlim\Mcp\App` helper
5. 最后再看 [`/Users/guweigang/Source/vhttpd/docs/MCP_MVP_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/MCP_MVP_PLAN.md) 深入 transport/runtime 设计
