# MCP Runbook

这页是 `vhttpd` 的 MCP 手工验证 runbook。

目标不是覆盖 MCP 全规范，而是快速验证这条主链是否正常：

- `initialize`
- `Mcp-Session-Id`
- `GET /mcp` SSE session
- queued notification
- queued `sampling/createMessage`
- `/admin/runtime/mcp`
- client capability snapshot
- `sampling` soft warning metric

## Start

启动示例：

```bash
cd /Users/guweigang/Source/vhttpd
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/config/mcp.toml
```

默认端口：

- data plane: `http://127.0.0.1:19895`
- admin plane: `http://127.0.0.1:19995`

## Step 1: Initialize With Client Capabilities

```bash
curl --noproxy '*' -s \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -D /tmp/vhttpd_mcp_headers.txt \
  --data-binary '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-05","capabilities":{"sampling":{},"roots":{"listChanged":true}}}}' \
  http://127.0.0.1:19895/mcp | jq .
```

预期：

- 返回 `200`
- `result.capabilities` 至少包含：
  - `logging`
  - `sampling`
  - `tools`
  - `resources`
  - `prompts`

## Step 2: Extract `Mcp-Session-Id`

注意：头文件里当前实际写出的是小写 `mcp-session-id:`，提取时按实际输出匹配最稳。

```bash
SESSION_ID=$(awk '/^mcp-session-id:/ {print $2}' /tmp/vhttpd_mcp_headers.txt | tr -d '\r')
echo "$SESSION_ID"
```

## Step 3: Verify Client Capability Snapshot

```bash
curl --noproxy '*' \
  "http://127.0.0.1:19995/admin/runtime/mcp?details=1&session_id=${SESSION_ID}" | jq .
```

只看 capability 快照：

```bash
curl --noproxy '*' \
  "http://127.0.0.1:19995/admin/runtime/mcp?details=1&session_id=${SESSION_ID}" \
  | jq -r '.sessions[0].client_capabilities_json'
```

预期类似：

```json
{"sampling":{},"roots":{"listChanged":true}}
```

## Step 4: Open SSE Session

另开一个终端：

```bash
curl --noproxy '*' -N \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  http://127.0.0.1:19895/mcp
```

预期先看到：

```text
: connected
```

## Step 5: Verify Queued Notification

```bash
curl --noproxy '*' -s \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  --data-binary '{"jsonrpc":"2.0","id":2,"method":"debug/notify","params":{"text":"hello mcp"}}' \
  http://127.0.0.1:19895/mcp | jq .
```

预期：

- 这条 `POST` 会立刻返回
- body 里是 `{ "queued": true }`
- SSE 终端会收到：

```text
event: message
data: {"jsonrpc":"2.0","method":"notifications/message",...}
```

## Step 6: Verify Queued Sampling Request

```bash
curl --noproxy '*' -s \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  --data-binary '{"jsonrpc":"2.0","id":3,"method":"debug/sample","params":{"topic":"runtime contract"}}' \
  http://127.0.0.1:19895/mcp | jq .
```

预期：

- `POST` 立刻返回 `{ "queued": true }`
- SSE 终端收到：

```text
event: message
data: {"jsonrpc":"2.0","id":"sample-3","method":"sampling/createMessage",...}
```

## Step 7: Verify Soft Warning For Missing Client Sampling Capability

先创建一个不声明 `sampling` 的 session：

```bash
curl --noproxy '*' -s \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -D /tmp/vhttpd_mcp_headers_no_sampling.txt \
  --data-binary '{"jsonrpc":"2.0","id":11,"method":"initialize","params":{"protocolVersion":"2025-11-05","capabilities":{"roots":{"listChanged":true}}}}' \
  http://127.0.0.1:19895/mcp | jq .
```

```bash
SESSION_ID_NO_SAMPLING=$(awk '/^mcp-session-id:/ {print $2}' /tmp/vhttpd_mcp_headers_no_sampling.txt | tr -d '\r')
echo "$SESSION_ID_NO_SAMPLING"
```

先看 warning 值：

```bash
curl --noproxy '*' http://127.0.0.1:19995/admin/runtime | jq '.stats.mcp_sampling_capability_warnings_total'
```

再触发一次 `debug/sample`：

```bash
curl --noproxy '*' -s \
  -X POST \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID_NO_SAMPLING}" \
  --data-binary '{"jsonrpc":"2.0","id":12,"method":"debug/sample","params":{"topic":"warning path"}}' \
  http://127.0.0.1:19895/mcp | jq .
```

再看一次：

```bash
curl --noproxy '*' http://127.0.0.1:19995/admin/runtime | jq '.stats.mcp_sampling_capability_warnings_total'
```

预期：

- 第一次是 `0`
- 第二次变成 `1`

## Step 8: Delete Session

```bash
curl --noproxy '*' -s \
  -X DELETE \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  http://127.0.0.1:19895/mcp | jq .
```

预期：

```json
{"deleted":true}
```

## Common Pitfalls

### 1. `mcp-session-id` 提取错了

头文件当前实际写出的是小写：

```text
mcp-session-id: mcp_xxx
```

所以推荐：

```bash
awk '/^mcp-session-id:/ {print $2}'
```

### 2. `GET /mcp` 用了空 session id

如果 SSE 这条请求没带上正确的 `Mcp-Session-Id`，会看到：

- `400 Missing Mcp-Session-Id`
- 或 `404 Unknown Mcp-Session-Id`

### 3. 改了代码但没重启 `vhttpd`

MCP 这条线最近修过几次真实 runtime bug。改完代码后一定重启：

```bash
kill $(cat /tmp/vhttpd_mcp.pid) 2>/dev/null || true
rm -f /tmp/vhttpd_mcp.pid
rm -f /tmp/vhttpd_mcp_worker*.sock
```

再重新启动示例。

### 4. 看错 warning 字段路径

warning 字段在：

```bash
.stats.mcp_sampling_capability_warnings_total
```

不是顶层字段。

### 5. `sampling` policy 会影响行为

`mcp.toml` 现在支持：

```toml
[mcp]
sampling_capability_policy = "warn"
```

可选值：

- `warn`
  - 允许入队
  - 增加 `mcp_sampling_capability_warnings_total`
- `drop`
  - 不入队
  - 增加 `mcp_sampling_capability_dropped_total`
- `error`
  - 直接拒绝本次 `POST /mcp`
  - 返回 `409`
  - 增加 `mcp_sampling_capability_errors_total`

## Related Docs

- [`/Users/guweigang/Source/vhttpd/docs/MCP.md`](/Users/guweigang/Source/vhttpd/docs/MCP.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md`](/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md)
- [`/Users/guweigang/Source/vhttpd/docs/MCP_CAPABILITY_NEGOTIATION_PLAN.md`](/Users/guweigang/Source/vhttpd/docs/MCP_CAPABILITY_NEGOTIATION_PLAN.md)
- [`/Users/guweigang/Source/vhttpd/examples/README.md`](/Users/guweigang/Source/vhttpd/examples/README.md)
