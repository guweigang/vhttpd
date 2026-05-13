# 构建你的专属 AI Gateway：Ollama 代理实战

在上一篇文章中，我们了解了 AI 流式应用的基础。现在，让我们深入探讨一个非常实用的场景：**构建 AI Gateway**。通过 vhttpd 的 upstream plan 架构，我们可以轻松创建一个 Ollama 代理，实现本地和云端 AI 模型的无缝切换。

---

## 为什么需要 AI Gateway？

在 AI 应用开发中，我们经常面临以下挑战：

1. **模型切换** - 开发环境用本地模型，生产环境用云端模型
2. **统一接口** - 不同 AI 提供商的 API 格式不同
3. **离线能力** - 需要在无网络环境下运行
4. **成本控制** - 灵活切换不同性价比的模型
5. **流量控制** - 需要限制调用频率和并发

AI Gateway 解决了这些问题，它位于你的应用和 AI 提供商之间，提供：
- **统一接口** - 无论后端用哪个模型，前端接口保持一致
- **灵活路由** - 根据请求特征路由到不同模型
- **缓存和限流** - 减少重复请求，控制成本
- **监控和日志** - 完整的请求追踪和统计

---

## vhttpd 的 Upstream Plan 架构

vhttpd 支持三种流式架构：

| Phase | 架构 | 特点 |
|-------|------|------|
| Phase 1 | Direct Stream | Worker 直接持有连接，简单但不灵活 |
| Phase 2 | Dispatch Stream | vhttpd 持有连接，Worker 处理事件 |
| Phase 3 | Upstream Plan | Worker 返回计划，vhttpd 执行，最灵活 |

**Phase 3: Upstream Plan** 是最适合 AI Gateway 的架构：

```
用户请求 -> vhttpd -> Worker 返回执行计划 -> vhttpd 执行计划连接到上游
```

Worker 不需要处理复杂的流式逻辑，只需返回"我要连接到哪里"的信息，vhttpd 会负责：
- 建立到上游的连接
- 处理流式响应
- 管理连接生命周期
- 处理错误和重试

---

## Ollama 简介

Ollama 是一个强大的本地 AI 模型运行工具：

- **开源免费** - 无 API 调用费用
- **隐私友好** - 数据不离开本地
- **多模型支持** - Llama 2、Mistral、CodeLlama 等
- **OpenAI 兼容** - 提供 OpenAI 格式的 API
- **跨平台** - 支持 macOS、Linux、Windows

---

## 第一步：安装和配置 Ollama

### macOS / Linux

```bash
# 安装 Ollama
curl -fsSL https://ollama.com/install.sh | sh

# 启动 Ollama 服务
ollama serve

# 下载模型
ollama pull llama2
ollama pull mistral
ollama pull codellama
```

### Windows

从 [ollama.com](https://ollama.com) 下载安装包，然后：

```powershell
# 启动服务
ollama serve

# 下载模型
ollama pull llama2
```

### 验证安装

```bash
# 测试 Ollama
curl http://localhost:11434/api/generate -d '{
  "model": "llama2",
  "prompt": "Why is the sky blue?",
  "stream": false
}'
```

---

## 第二步：运行 Ollama 代理示例

vhttpd 提供了完整的 Ollama 代理示例。查看配置文件 [`ollama-proxy.toml`](file:///workspace/examples/config/ollama-proxy.toml)：

```toml
[server]
host = "127.0.0.1"
port = 19884

[files]
pid_file = "/tmp/vhttpd_ollama_proxy.pid"
event_log = "/tmp/vhttpd_ollama_proxy.events.ndjson"

[worker]
autostart = true
read_timeout_ms = 60000  # AI 生成需要更长时间
socket = "/tmp/vslim_ollama_proxy.sock"
cmd = "php /path/to/php-worker"

[worker.env]
VHTTPD_APP = "/path/to/examples/ollama-proxy-app.php"
OLLAMA_CHAT_URL = "http://localhost:11434/api/chat"
OLLAMA_MODEL = "minimax-m2:cloud"
OLLAMA_API_KEY = ""

[admin]
host = "127.0.0.1"
port = 19984
token = ""
```

关键配置说明：
- `read_timeout_ms = 60000` - AI 生成可能需要更长时间
- `OLLAMA_CHAT_URL` - Ollama API 地址
- `OLLAMA_MODEL` - 默认使用的模型
- `OLLAMA_API_KEY` - 如果使用云端 Ollama，需要 API Key

---

## 第三步：理解代理代码

查看 [`ollama-proxy-app.php`](file:///workspace/examples/ollama-proxy-app.php)：

```php
<?php
declare(strict_types=1);

use VPhp\VSlim\Stream\OllamaClient;

return static function (mixed $request, array $envelope = []): array|\VPhp\VHttpd\Upstream\Plan {
    $src = is_array($request) ? $request : $envelope;
    $method = strtoupper((string) ($src['method'] ?? 'GET'));
    $pathWithQuery = (string) ($src['path'] ?? '/');
    $path = (string) (parse_url($pathWithQuery, PHP_URL_PATH) ?? '/');

    if ($path === '/ollama/health') {
        return [
            'status' => 200,
            'content_type' => 'text/plain; charset=utf-8',
            'body' => 'OK',
        ];
    }

    if (!in_array($method, ['GET', 'POST'], true)) {
        return [
            'status' => 405,
            'content_type' => 'text/plain; charset=utf-8',
            'body' => 'Method Not Allowed',
        ];
    }

    $normalized = [
        'method' => $method,
        'path' => $path,
        'query' => is_array($src['query'] ?? null) ? $src['query'] : [],
        'body' => (string) ($src['body'] ?? ''),
    ];

    $client = OllamaClient::fromEnv();
    $payload = $client->payload($normalized);

    if ($path === '/ollama/text') {
        return $client->upstreamPlan($payload, 'text');
    }
    if ($path === '/ollama/sse') {
        return $client->upstreamPlan($payload, 'sse');
    }

    return [
        'status' => 404,
        'content_type' => 'application/json; charset=utf-8',
        'body' => json_encode([
            'error' => 'Not Found',
            'hint' => 'Use /ollama/text or /ollama/sse',
            'mode' => 'stream',
            'strategy' => 'upstream_plan',
        ], JSON_UNESCAPED_UNICODE),
    ];
};
```

这个代码展示了 Phase 3 upstream plan 的核心模式：

1. **接收请求** - 获取方法、路径、查询参数、请求体
2. **构建 payload** - 使用 `OllamaClient::payload()` 标准化请求
3. **返回执行计划** - 使用 `upstreamPlan()` 返回计划
4. **vhttpd 执行** - vhttpd 读取计划，连接到上游，返回流式响应

---

## 第四步：启动和测试

### 启动 vhttpd

```bash
./vhttpd --config examples/config/ollama-proxy.toml
```

你应该会看到：

```
vhttpd starting...
listening on 127.0.0.1:19884
worker pool started (4 workers)
```

### 测试文本流

```bash
curl --noproxy '*' -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama2",
    "messages": [
      {"role": "user", "content": "Hello! What is vhttpd?"}
    ]
  }' \
  http://127.0.0.1:19884/ollama/text
```

你会看到流式输出，每个 token 逐个显示。

### 测试 SSE

```bash
curl --noproxy '*' -N \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama2",
    "messages": [
      {"role": "user", "content": "Explain AI in one sentence"}
    ]
  }' \
  http://127.0.0.1:19884/ollama/sse
```

你会看到 SSE 格式的流式响应：

```
id: 1
event: message
data: {"model":"llama2","message":{"role":"assistant","content":"AI"}

id: 2
event: message
data: {"model":"llama2","message":{"role":"assistant","content":" is"}

...
```

---

## 第五步：构建多模型路由

在实际项目中，我们可能需要根据请求路由到不同的模型。让我创建一个高级示例。

创建 `ollama-multi-model-app.php`：

```php
<?php
declare(strict_types=1);

use VPhp\VSlim\Stream\OllamaClient;

return static function (mixed $request, array $envelope = []): array|\VPhp\VHttpd\Upstream\Plan {
    $src = is_array($request) ? $request : $envelope;
    $path = (string) ($src['path'] ?? '/');
    $body = json_decode((string) ($src['body'] ?? '{}'), true);

    // 路由配置
    $routes = [
        '/chat/code' => [
            'url' => 'http://localhost:11434/api/chat',
            'model' => 'codellama',
        ],
        '/chat/writing' => [
            'url' => 'http://localhost:11434/api/chat',
            'model' => 'llama2',
        ],
        '/chat/fast' => [
            'url' => 'http://localhost:11434/api/chat',
            'model' => 'mistral',
        ],
    ];

    // 查找路由
    $route = $routes[$path] ?? $routes['/chat/writing'];

    // 如果请求中指定了模型，优先使用
    if (!empty($body['model'])) {
        $route['model'] = $body['model'];
    }

    // 构建上游计划
    $payload = [
        'url' => $route['url'],
        'body' => [
            'model' => $route['model'],
            'messages' => $body['messages'] ?? [],
            'stream' => true,
        ],
    ];

    // 返回执行计划
    return [
        'mode' => 'stream',
        'strategy' => 'upstream_plan',
        'upstream' => $payload,
        'output' => 'sse',
    ];
};
```

这个示例展示了：
- **路由规则** - 不同路径路由到不同模型
- **模型覆盖** - 请求中可以指定模型
- **灵活配置** - 易于扩展新的路由规则

---

## 第六步：连接云端 Ollama

除了本地模型，Ollama 还支持云端服务（如 MiniMax、Fireworks 等）。

### 配置云端

修改配置：

```toml
[worker.env]
VHTTPD_APP = "/path/to/examples/ollama-proxy-app.php"
OLLAMA_CHAT_URL = "https://api.minimax.chat/v1/text/chatcompletion_v2"
OLLAMA_MODEL = "MiniMax-Text-01"
OLLAMA_API_KEY = "your-api-key-here"
```

### 支持离线测试

使用 fixture 文件进行离线测试：

```toml
[worker.env]
# 使用 fixture 文件代替真实 API
OLLAMA_STREAM_FIXTURE = "/path/to/fixtures/ollama_stream_fixture.ndjson"
```

fixture 文件格式（NDJSON）：

```json
{"content": "Hello", "done": false}
{"content": " world", "done": false}
{"content": "!", "done": true}
```

---

## 第七步：监控和调试

### Admin Plane

```bash
# 查看运行时状态
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19984/admin/runtime

# 查看活跃的上游连接
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19984/admin/runtime/upstreams

# 查看事件日志
tail -f /tmp/vhttpd_ollama_proxy.events.ndjson
```

### 事件日志格式

每个事件都是 NDJSON 格式：

```json
{"ts":"2024-01-15T10:30:00Z","kind":"upstream.connect","url":"http://localhost:11434/api/chat"}
{"ts":"2024-01-15T10:30:01Z","kind":"upstream.chunk","size":45}
{"ts":"2024-01-15T10:30:05Z","kind":"upstream.close","duration_ms":5000}
```

---

## 最佳实践

### 1. 合理的超时设置

```toml
[worker]
read_timeout_ms = 60000  # AI 生成可能需要一分钟
```

### 2. 连接池配置

```toml
[worker]
pool_size = 4  # 根据并发需求调整
socket_prefix = "/tmp/vslim_ollama"
```

### 3. 错误处理

```php
// 总是返回友好的错误消息
if ($client === null) {
    return [
        'status' => 503,
        'content_type' => 'application/json; charset=utf-8',
        'body' => json_encode([
            'error' => 'Service Unavailable',
            'message' => 'Ollama service is not available',
            'hint' => 'Please ensure Ollama is running',
        ]),
    ];
}
```

### 4. 日志和追踪

```php
// 记录请求
$requestId = uniqid('req_');
error_log("[{$requestId}] Starting request: {$path}");

// 在事件中包含 requestId
$client->upstreamPlan($payload, 'sse', [
    'request_id' => $requestId,
]);
```

---

## 扩展：OpenAI 兼容网关

vhttpd 还支持 OpenAI 格式的网关。查看 [`openai-gateway.toml`](file:///workspace/examples/config/openai-gateway.toml)：

```toml
[worker.env]
VHTTPD_APP = "/path/to/examples/openai-gateway-app.php"
OPENAI_API_KEY = "sk-..."
OPENAI_BASE_URL = "https://api.openai.com/v1"
```

这让你可以：
- 使用 OpenAI SDK 访问本地模型
- 轻松切换不同提供商
- 保持代码兼容性

---

## 下一步

恭喜你！你已经掌握了构建 AI Gateway 的核心技能。在后续文章中，我们将探讨：
- **MCP (Model Context Protocol)** - 构建可扩展的 AI 工具平台
- **飞书机器人集成** - 将 AI 能力带入企业沟通
- **高级路由和负载均衡** - 构建生产级 AI 网关

如果你想继续探索，可以：
- 查看 [`openai-gateway-app.php`](file:///workspace/examples/openai-gateway-app.php) 了解 OpenAI 兼容网关
- 探索 [`dashscope-coding-plugin`](file:///workspace/examples/openai-dashscope-coding-plugin.mts) 了解其他 AI 提供商
- 阅读 vhttpd 源码中的 `Upstream` 相关实现

---

## 常见问题

**Q: Ollama 和 vhttpd 必须在同一台机器吗？**
A: 不需要！只要网络可达，vhttpd 可以连接到任何 Ollama 实例。

**Q: 如何处理 Ollama 模型下载？**
A: 在首次使用前运行 `ollama pull <model>`。也可以在应用启动时检查并下载。

**Q: 如何支持 WebSocket？**
A: 当前 vhttpd 的 upstream plan 主要支持 HTTP 流式。WebSocket 需要不同的架构。

**Q: 如何实现认证和限流？**
A: 在 Worker 层添加认证中间件，检查 API Key 或 JWT token。

---

## 相关资源

- [Ollama 代理示例](file:///workspace/examples/ollama-proxy-app.php)
- [Ollama 代理配置](file:///workspace/examples/config/ollama-proxy.toml)
- [OpenAI 网关配置](file:///workspace/examples/config/openai-gateway.toml)
- [DashScope 编码插件](file:///workspace/examples/openai-dashscope-coding-plugin.mts)
- [Ollama 官方文档](https://ollama.com/docs)
