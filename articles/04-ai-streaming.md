# AI 流式应用入门：从简单 SSE 到智能对话

在前几篇文章中，我们学会了如何快速上手 vhttpd，以及如何在它上面运行 PHP 应用。现在，让我们探索 vhttpd 最令人兴奋的能力之一：**AI 流式应用**。在 AI 时代，能够高效处理 Token 流是构建智能应用的关键。

---

## 为什么 AI 流式应用很重要？

传统的 HTTP 请求/响应模式在 AI 场景下有几个问题：

1. **等待时间长** - 用户必须等待整个响应生成完成才能看到任何内容
2. **体验差** - 对于长时间生成的响应，用户不知道系统是否在工作
3. **资源浪费** - 如果用户中断请求，已经生成的 token 无法返回

流式响应解决了这些问题：
- **即时反馈** - 用户立刻看到首个 token
- **更好的感知** - 打字效果让 AI 看起来更像在"思考"
- **可中断** - 用户可以随时停止，获取部分结果

---

## vhttpd 的流式能力概览

vhttpd 支持三种流式模式：

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| **text stream** | 纯文本分块传输 | 简单场景、调试 |
| **SSE** (Server-Sent Events) | 标准事件流格式 | Web 前端、AI 对话 |
| **upstream plan** | 连接外部 AI 服务 | 生产环境 |

我们先从最简单的开始。

---

## 第一步：运行文本流示例

项目已经为我们准备好了 AI 流式应用示例。让我查看配置和代码：

### 配置文件

查看 [`ai-stream.toml`](file:///workspace/examples/config/ai-stream.toml)：

```toml
[server]
host = "127.0.0.1"
port = 19882

[files]
pid_file = "/tmp/vhttpd_ai_stream.pid"
event_log = "/tmp/vhttpd_ai_stream.events.ndjson"

[worker]
autostart = true
read_timeout_ms = 3000
socket = "/tmp/vslim_ai_stream.sock"
cmd = "php -d extension=/path/to/vslim/vslim.so /path/to/php-worker"

[worker.env]
VHTTPD_APP = "/path/to/examples/ai-stream-app.php"

[admin]
host = "127.0.0.1"
port = 19982
token = ""
```

注意：这个配置使用的是 PHP executor，因为流式功能目前需要 PHP worker 来实现。

### 应用代码

查看 [`ai-stream-app.php`](file:///workspace/examples/ai-stream-app.php)：

```php
<?php
declare(strict_types=1);

/**
 * AI token streaming demo for vhttpd/php-worker.
 *
 * Endpoints:
 * - GET /ai/stream?prompt=...
 *   passthrough text chunks (stream_type=text)
 * - GET /ai/sse?prompt=...
 *   SSE chunks (stream_type=sse)
 */
return static function (mixed $request, array $envelope = []): array|\VPhp\VHttpd\PhpWorker\StreamResponse {
    $req = is_array($request) ? $request : $envelope;
    $method = strtoupper((string) ($req['method'] ?? 'GET'));
    $target = (string) ($req['path'] ?? '/');
    $path = (string) (parse_url($target, PHP_URL_PATH) ?? '/');
    $query = is_array($req['query'] ?? null) ? $req['query'] : [];
    $prompt = trim((string) ($query['prompt'] ?? 'Explain vhttpd streaming'));

    if ($path === '/health') {
        return [
            'status' => 200,
            'content_type' => 'text/plain; charset=utf-8',
            'body' => 'OK',
        ];
    }

    if ($method !== 'GET') {
        return [
            'status' => 405,
            'content_type' => 'text/plain; charset=utf-8',
            'body' => 'Method Not Allowed',
        ];
    }

    if ($path === '/ai/stream') {
        // 文本流模式
        $chunks = (function () use ($prompt): Generator {
            yield "AI ";
            usleep(30000);
            yield "token ";
            usleep(30000);
            yield "stream ";
            usleep(30000);
            yield "for: ";
            usleep(30000);
            yield $prompt . "\n";
        })();

        return vhttpd_stream_text(
            $chunks,
            200,
            'text/plain; charset=utf-8',
            ['x-demo' => 'ai-stream-text']
        );
    }

    if ($path === '/ai/sse') {
        // SSE 模式
        $events = (function () use ($prompt): Generator {
            $tokens = ['AI', 'token', 'SSE', 'for:', $prompt];
            foreach ($tokens as $i => $token) {
                usleep(30000);
                yield [
                    'id' => 'tok-' . ($i + 1),
                    'event' => 'token',
                    'retry' => 1000,
                    'data' => $token,
                ];
            }
        })();

        return vhttpd_stream_sse($events, 200, ['x-demo' => 'ai-stream-sse']);
    }

    return [
        'status' => 404,
        'content_type' => 'application/json; charset=utf-8',
        'body' => json_encode(
            [
                'error' => 'Not Found',
                'hint' => 'Try /ai/stream or /ai/sse',
            ],
            JSON_UNESCAPED_UNICODE
        ),
    ];
};
```

### 启动应用

```bash
./vhttpd --config examples/config/ai-stream.toml
```

---

## 第二步：测试文本流

文本流是最简单的流式模式。让我测试一下：

```bash
curl --noproxy '*' -N "http://127.0.0.1:19882/ai/stream?prompt=vhttpd"
```

你会看到类似这样的输出，每个 token 分隔显示：

```
AI token stream for: vhttpd
```

加上 `-N` 参数可以实时看到每个 chunk 的到达。如果去掉延迟（`usleep`），你会看到流式输出的效果。

---

## 第三步：测试 SSE

SSE (Server-Sent Events) 是 Web 前端常用的流式格式。让我测试一下：

```bash
curl --noproxy '*' -N "http://127.0.0.1:19882/ai/sse?prompt=vhttpd"
```

你会看到：

```
id: tok-1
event: token
retry: 1000
data: AI

id: tok-2
event: token
retry: 1000
data: token

id: tok-3
event: token
retry: 1000
data: SSE

id: tok-4
event: token
retry: 1000
data: for:

id: tok-5
event: token
retry: 1000
data: vhttpd
```

SSE 格式的特点：
- 每条消息以空行分隔
- 可以包含 `id`、`event`、`retry`、`data` 等字段
- 浏览器原生支持 `EventSource` API

---

## 第四步：在 Web 前端使用 SSE

SSE 的真正威力在于 Web 前端。让我创建一个简单的 HTML 页面来演示：

创建 `public/ai-chat.html`：

```html
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <title>vhttpd AI Chat</title>
    <style>
        body { font-family: sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
        #chat { border: 1px solid #ccc; padding: 20px; min-height: 300px; border-radius: 8px; }
        #input { width: 100%; padding: 10px; margin-top: 10px; border-radius: 4px; border: 1px solid #ddd; }
        button { padding: 10px 20px; margin-top: 10px; background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        .token { display: inline; }
        .thinking { color: #888; font-style: italic; }
    </style>
</head>
<body>
    <h1>🤖 vhttpd AI Chat</h1>
    <div id="chat" class="thinking">Waiting for your message...</div>
    <input type="text" id="input" placeholder="Ask me anything..." />
    <button onclick="sendMessage()">Send</button>

    <script>
        const chat = document.getElementById('chat');
        const input = document.getElementById('input');

        input.addEventListener('keypress', (e) => {
            if (e.key === 'Enter') sendMessage();
        });

        function sendMessage() {
            const message = input.value.trim();
            if (!message) return;

            chat.innerHTML = '<span class="thinking">AI is thinking...</span>';
            chat.scrollTop = chat.scrollHeight;

            const eventSource = new EventSource(`/ai/sse?prompt=${encodeURIComponent(message)}`);

            eventSource.addEventListener('token', (e) => {
                chat.innerHTML = chat.innerHTML.replace('<span class="thinking">AI is thinking...</span>', '');
                const span = document.createElement('span');
                span.className = 'token';
                span.textContent = e.data;
                chat.appendChild(span);
                chat.scrollTop = chat.scrollHeight;
            });

            eventSource.onerror = () => {
                eventSource.close();
                chat.innerHTML += '<br><em>(Connection closed)</em>';
            };
        }
    </script>
</body>
</html>
```

然后修改配置文件启用静态文件服务：

```toml
[assets]
enabled = true
prefix = "/assets"
root = "examples/public"
cache_control = "public, max-age=3600"
```

现在访问 `http://127.0.0.1:19882/assets/ai-chat.html`，你就可以看到实时流式响应的效果了！

---

## 第五步：连接真实 AI 服务

上面的例子使用模拟数据。现在让我们看看如何连接真实的 AI 服务。

### Ollama 本地模型

Ollama 是一个流行的本地 AI 模型运行工具。查看配置 [`ollama-proxy.toml`](file:///workspace/examples/config/ollama-proxy.toml)：

```toml
[server]
host = "127.0.0.1"
port = 19885

[files]
pid_file = "/tmp/vhttpd_ollama.pid"
event_log = "/tmp/vhttpd_ollama.events.ndjson"

[worker]
autostart = true
read_timeout_ms = 30000
socket = "/tmp/vslim_ollama.sock"
cmd = "php -d extension=/path/to/vslim/vslim.so /path/to/php-worker"

[worker.env]
VHTTPD_APP = "/path/to/examples/ollama-proxy-app.php"
OLLAMA_BASE_URL = "http://127.0.0.1:11434"

[admin]
host = "127.0.0.1"
port = 19985
token = ""
```

### Ollama 代理应用

创建 [`ollama-proxy-app.php`](file:///workspace/examples/ollama-proxy-app.php)（简化版）：

```php
<?php
declare(strict_types=1);

use Nyholm\Psr7\Factory\Psr17Factory;

return static function (mixed $request, array $envelope = []): array|\VPhp\VHttpd\PhpWorker\StreamResponse {
    $req = is_array($request) ? $request : $envelope;
    $path = (string) ($req['path'] ?? '/');

    // Ollama Chat API 代理
    if ($req['method'] === 'POST' && $path === '/chat') {
        $body = $req['body'] ?? [];
        $baseUrl = getenv('OLLAMA_BASE_URL') ?: 'http://127.0.0.1:11434';

        // 转发到 Ollama
        $ch = curl_init($baseUrl . '/api/chat');
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => json_encode($body),
            CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
            CURLOPT_RETURNTRANSFER => false,
            CURLOPT_WRITEFUNCTION => function ($ch, $chunk) {
                echo $chunk;
                flush();
                return strlen($chunk);
            },
        ]);

        curl_exec($ch);
        curl_close($ch);

        return ['status' => 200]; // 流已经直接输出
    }

    return [
        'status' => 404,
        'content_type' => 'application/json; charset=utf-8',
        'body' => json_encode(['error' => 'Not Found']),
    ];
};
```

### 启动并测试

```bash
# 启动 Ollama（需要先安装）
ollama serve &
ollama pull llama2

# 启动 vhttpd
./vhttpd --config examples/config/ollama-proxy.toml

# 测试
curl --noproxy '*' -X POST \
  -H "Content-Type: application/json" \
  -d '{"model":"llama2","messages":[{"role":"user","content":"Hello!"}]}' \
  http://127.0.0.1:19885/chat
```

你会看到 Ollama 的流式响应实时输出！

---

## 理解 vhttpd 流式架构

### 流式执行阶段

vhttpd 的流式执行分为三个阶段（Phase）：

**Phase 1: Direct Stream**
- Worker 直接持有流连接
- 简单但不够灵活
- 适合简单场景

**Phase 2: Dispatch Stream**
- vhttpd 持有下游连接
- Worker 处理 `open/next/close` 事件
- 更灵活，支持中间件

**Phase 3: Upstream Plan**
- Worker 返回执行计划
- vhttpd 自己连接上游服务
- 最适合 AI 代理场景

### 流式配置选项

```toml
[stream]
strategy = "upstream_plan"  # direct | dispatch | upstream_plan
output = "sse"               # text | sse

[upstream]
provider = "ollama"          # ollama | openai | feishu
base_url = "http://127.0.0.1:11434"
timeout_ms = 30000
```

---

## 对比：传统方式 vs vhttpd

| 方面 | 传统 PHP-FPM | vhttpd |
|------|--------------|--------|
| 流式输出 | ❌ 不支持或复杂 | ✅ 原生支持 |
| WebSocket | ❌ 需要额外服务 | ✅ 内置 |
| AI 集成 | ❌ 需要手动处理 | ✅ 支持 upstream plan |
| 连接管理 | ❌ 每个请求独立 | ✅ 持久化 worker |
| 错误处理 | ⚠️ 复杂 | ✅ 结构化事件 |
| 可观测性 | ❌ 需要额外工具 | ✅ Admin Plane |

---

## 最佳实践

### 1. 合理的超时设置

```toml
[worker]
read_timeout_ms = 30000  # AI 生成可能需要更长时间
```

### 2. 事件日志

```toml
[files]
event_log = "tmp/vhttpd_stream.events.ndjson"
```

流式事件会被记录到 NDJSON 文件，方便调试和监控。

### 3. 使用 Admin Plane 监控

```bash
# 查看运行时状态
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19982/admin/runtime

# 查看活跃的上游连接
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19982/admin/runtime/upstreams
```

---

## 下一步

恭喜你！你已经掌握了 vhttpd 的流式能力。在后续文章中，我们将深入探讨：
- **MCP (Model Context Protocol)** - 构建 AI 工具平台
- **飞书机器人集成** - 将 AI 能力带入企业沟通
- **高级流式模式** - upstream plan 深度解析

如果你想继续探索，可以：
- 查看 [`openai-gateway.toml`](file:///workspace/examples/config/openai-gateway.toml) 了解 OpenAI 兼容网关
- 探索 [`feishu-bot-mcp-app.php`](file:///workspace/examples/feishu-bot-mcp-app.php) 了解飞书 + AI 集成
- 阅读 [`OVERVIEW.md`](file:///workspace/docs/OVERVIEW.md) 了解完整的流式架构

---

## 常见问题

**Q: vjsx executor 支持流式吗？**
A: 当前 vjsx executor 主要用于轻量级逻辑。流式功能需要 PHP executor。

**Q: 如何处理 AI 服务不可用的情况？**
A: 使用 try-catch 捕获异常，返回友好的错误消息。流式场景下可以在 `error` 事件中发送错误信息。

**Q: 如何保证流式响应的顺序？**
A: vhttpd 会保证 chunk 按顺序传输。如果需要更严格的顺序控制，可以在应用层添加序列号。

---

## 相关资源

- [AI 流示例](file:///workspace/examples/ai-stream-app.php)
- [Ollama 代理配置](file:///workspace/examples/config/ollama-proxy.toml)
- [OpenAI 网关配置](file:///workspace/examples/config/openai-gateway.toml)
- [流式架构文档](file:///workspace/docs/OVERVIEW.md)
- [飞书机器人示例](file:///workspace/examples/feishu-bot-mcp-app.php)
