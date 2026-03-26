# VSlim Examples

## TOML 一键启动（推荐）

先编译：

```bash
cd /Users/guweigang/Source/vphpx/vslim
make build vhttpd
```

然后直接：

```bash
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/config/hello.toml
```

已提供配置：

- `/Users/guweigang/Source/vhttpd/examples/config/hello.toml`
- `/Users/guweigang/Source/vhttpd/examples/config/websocket-echo.toml`
- `/Users/guweigang/Source/vhttpd/examples/config/ai-stream.toml`
- `/Users/guweigang/Source/vhttpd/examples/config/stream-bench.toml`
- `/Users/guweigang/Source/vhttpd/examples/config/ollama-proxy.toml`
- `/Users/guweigang/Source/vhttpd/examples/config/mcp.toml`
- `/Users/guweigang/Source/vhttpd/examples/config/symfony.toml`
- `/Users/guweigang/Source/vhttpd/examples/config/laravel.toml`
- `/Users/guweigang/Source/vhttpd/examples/config/wordpress.toml`

说明：

- `symfony.toml` / `laravel.toml` 需要先安装各自 `vendor` 依赖
- `wordpress.toml` 需要把 `VSLIM_WP_ROOT=/ABS/PATH/TO/WORDPRESS` 改成真实路径
- `ollama-proxy.toml` 里 `OLLAMA_CHAT_URL / OLLAMA_MODEL / OLLAMA_API_KEY` 可按需改
- `ollama-proxy.toml` 也支持 `OLLAMA_STREAM_FIXTURE`，可离线验证 phase-3 upstream plan
- 这些变量都在 `[worker.env]`，会传给 php-worker，可在 PHP 里直接 `getenv('KEY')`

## 快速开始（VSlim 原生）

```bash
cd /Users/guweigang/Source/vphpx/vslim
VHTTPD_APP=/Users/guweigang/Source/vhttpd/examples/hello-app.php make serve
```

```bash
curl --noproxy '*' -i http://127.0.0.1:19881/hello/codex
curl --noproxy '*' -i http://127.0.0.1:19881/go/nova
curl --noproxy '*' -i -H 'Host: demo.local' http://127.0.0.1:19881/api/meta
```

一键演示（自动启动并发请求）：

```bash
make -C /Users/guweigang/Source/vhttpd demo-vslim
```

## WebSocket Echo 示例

直接启动：

```bash
cd /Users/guweigang/Source/vhttpd
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/config/websocket-echo.toml
```

然后打开：

```text
http://127.0.0.1:19888/
```

这个 demo 会：

- `GET /` 返回一个最小前端页面
- `GET /meta` 返回 demo 元信息
- `GET /ws` 走 WebSocket upgrade

前端默认连：

- `ws://127.0.0.1:19888/ws`

输入任意文本会收到：

- `echo:<your-message>`

输入 `bye` 会触发服务端主动 close。

## AI Token Streaming 示例

使用内置的流式 demo app：

```bash
cd /Users/guweigang/Source/vphpx/vslim
VHTTPD_APP=/Users/guweigang/Source/vhttpd/examples/ai-stream-app.php make serve
```

验证 text passthrough：

```bash
curl --noproxy '*' -N "http://127.0.0.1:19881/ai/stream?prompt=hello"
```

验证 SSE：

```bash
curl --noproxy '*' -N "http://127.0.0.1:19881/ai/sse?prompt=hello"
```

一键演示：

```bash
make -C /Users/guweigang/Source/vhttpd demo-ai
```

## Ollama Cloud/Local Proxy 示例

这个示例现在走的是 phase 3 upstream plan：

- PHP worker 只返回 `VPhp\\VHttpd\\Upstream\\Plan`
- `vhttpd` 自己连接 Ollama 或 fixture
- 上游流和下游流都不再长期占住 PHP worker

架构边界可参考：

- [`/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md`](/Users/guweigang/Source/vhttpd/docs/STREAM_RUNTIME_PHASES.md)
- [`/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md`](/Users/guweigang/Source/vhttpd/docs/UPSTREAM_PLAN_PHASE3.md)

```bash
cd /Users/guweigang/Source/vphpx/vslim
VHTTPD_APP=/Users/guweigang/Source/vhttpd/examples/ollama-proxy-app.php \
OLLAMA_CHAT_URL=https://<your-ollama-endpoint>/api/chat \
OLLAMA_MODEL=qwen2.5:7b-instruct \
OLLAMA_API_KEY=<your-token> \
make serve
```

text passthrough:

```bash
curl --noproxy '*' -N "http://127.0.0.1:19881/ollama/text?prompt=hello"
```

SSE:

```bash
curl --noproxy '*' -N "http://127.0.0.1:19881/ollama/sse?prompt=hello"
```

离线 fixture 验证：

```bash
cd /Users/guweigang/Source/vphpx/vslim
VHTTPD_APP=/Users/guweigang/Source/vhttpd/examples/ollama-proxy-app.php \
OLLAMA_STREAM_FIXTURE=/Users/guweigang/Source/vphpx/vslim/tests/fixtures/ollama_stream_fixture.ndjson \
make serve
```

## MCP Phase A/B 示例

这个示例现在已经覆盖 Streamable HTTP 的前两阶段：

- `POST /mcp`
- JSON-only request/response
- `GET /mcp`
- `Mcp-Session-Id` 绑定的最小 SSE/session 模式

边界说明：

- `vhttpd` 只做 MCP 的 HTTP transport/runtime
- `stdio MCP` 不进 `vhttpd`，更适合后续放到 `vshx`
- `[mcp].sampling_capability_policy` 支持：
  - `warn`
  - `drop`
  - `error`

直接启动：

```bash
cd /Users/guweigang/Source/vhttpd
./vhttpd --config /Users/guweigang/Source/vhttpd/examples/config/mcp.toml
```

初始化：

```bash
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-05","capabilities":{"sampling":{},"roots":{"listChanged":true}}}}' \
  -D /tmp/vhttpd_mcp_headers.txt \
  http://127.0.0.1:19895/mcp | jq .
```

列工具：

```bash
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  http://127.0.0.1:19895/mcp | jq .
```

列资源：

```bash
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -d '{"jsonrpc":"2.0","id":21,"method":"resources/list","params":{}}' \
  http://127.0.0.1:19895/mcp | jq .
```

读取资源：

```bash
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -d '{"jsonrpc":"2.0","id":22,"method":"resources/read","params":{"uri":"resource://demo/readme"}}' \
  http://127.0.0.1:19895/mcp | jq .
```

列 prompts：

```bash
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -d '{"jsonrpc":"2.0","id":23,"method":"prompts/list","params":{}}' \
  http://127.0.0.1:19895/mcp | jq .
```

获取 prompt：

```bash
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -d '{"jsonrpc":"2.0","id":24,"method":"prompts/get","params":{"name":"welcome","arguments":{"name":"codex"}}}' \
  http://127.0.0.1:19895/mcp | jq .
```

调用 `echo` 工具：

```bash
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello mcp"}}}' \
  http://127.0.0.1:19895/mcp | jq .
```

最小 session + SSE 验证：

```bash
SESSION_ID=$(awk '/^mcp-session-id:/ {print $2}' /tmp/vhttpd_mcp_headers.txt | tr -d '\r')
curl --noproxy '*' -N \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  http://127.0.0.1:19895/mcp
```

另开一个终端触发服务端通知：

```bash
SESSION_ID=$(awk '/^mcp-session-id:/ {print $2}' /tmp/vhttpd_mcp_headers.txt | tr -d '\r')
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{"jsonrpc":"2.0","id":4,"method":"debug/notify","params":{"text":"hello phase b"}}' \
  http://127.0.0.1:19895/mcp | jq .
```

SSE 连接里应该能看到一条 `notifications/message`。

触发 sampling 请求入队：

```bash
SESSION_ID=$(awk '/^mcp-session-id:/ {print $2}' /tmp/vhttpd_mcp_headers.txt | tr -d '\r')
curl --noproxy '*' -s \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -H 'MCP-Protocol-Version: 2025-11-05' \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  -d '{"jsonrpc":"2.0","id":5,"method":"debug/sample","params":{"topic":"runtime contract"}}' \
  http://127.0.0.1:19895/mcp | jq .
```

这时 `GET /mcp` 那条 SSE 连接里会收到一条 `sampling/createMessage`，里面会带：

- `messages`
- `systemPrompt`
- `maxTokens`

删除 session：

```bash
SESSION_ID=$(awk '/^mcp-session-id:/ {print $2}' /tmp/vhttpd_mcp_headers.txt | tr -d '\r')
curl --noproxy '*' -s -X DELETE \
  -H 'Origin: http://127.0.0.1:19895' \
  -H "Mcp-Session-Id: ${SESSION_ID}" \
  http://127.0.0.1:19895/mcp | jq .
```

MCP runtime 观测：

```bash
curl --noproxy '*' http://127.0.0.1:19995/admin/runtime | jq .
curl --noproxy '*' http://127.0.0.1:19995/admin/runtime/mcp | jq .
curl --noproxy '*' 'http://127.0.0.1:19995/admin/runtime/mcp?details=1&limit=20' | jq .
```

看当前 session 的 client capability 快照：

```bash
SESSION_ID=$(awk '/^mcp-session-id:/ {print $2}' /tmp/vhttpd_mcp_headers.txt | tr -d '\r')
curl --noproxy '*' "http://127.0.0.1:19995/admin/runtime/mcp?details=1&session_id=${SESSION_ID}" | jq .
curl --noproxy '*' "http://127.0.0.1:19995/admin/runtime/mcp?details=1&session_id=${SESSION_ID}" | jq -r '.sessions[0].client_capabilities_json'
```

如果你故意不在 `initialize` 里声明 `sampling`，但后面又触发了 `debug/sample`，可以再看：

```bash
curl --noproxy '*' http://127.0.0.1:19995/admin/runtime | jq '.stats.mcp_sampling_capability_warnings_total'
```

## Framework 示例（可独立进入目录运行）

- Symfony:
  - [examples/symfony/README.md](/Users/guweigang/Source/vhttpd/examples/symfony/README.md)
  - 文件: [examples/symfony/composer.json](/Users/guweigang/Source/vhttpd/examples/symfony/composer.json), [examples/symfony/app.php](/Users/guweigang/Source/vhttpd/examples/symfony/app.php)
- Laravel:
  - [examples/laravel/README.md](/Users/guweigang/Source/vhttpd/examples/laravel/README.md)
  - 文件: [examples/laravel/composer.json](/Users/guweigang/Source/vhttpd/examples/laravel/composer.json), [examples/laravel/app.php](/Users/guweigang/Source/vhttpd/examples/laravel/app.php)
- WordPress:
  - [examples/wordpress/README.md](/Users/guweigang/Source/vhttpd/examples/wordpress/README.md)
  - 文件: [examples/wordpress/app.php](/Users/guweigang/Source/vhttpd/examples/wordpress/app.php)

一键演示：

```bash
make -C /Users/guweigang/Source/vhttpd demo-symfony
make -C /Users/guweigang/Source/vhttpd demo-laravel
VSLIM_WP_ROOT=/abs/path/to/wordpress make -C /Users/guweigang/Source/vhttpd demo-wordpress
```
