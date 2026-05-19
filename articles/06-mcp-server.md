# MCP 服务端实践：构建可扩展的 AI 工具平台

在上一篇文章中，我们了解了如何构建 AI Gateway。现在，让我们探讨更具革命性的技术：**MCP (Model Context Protocol)**。MCP 是 AI 应用的标准化协议，让 AI 助手能够安全地访问工具和数据。vhttpd 内置支持 MCP，让我们可以轻松构建可扩展的 AI 工具平台。

---

## 什么是 MCP？

MCP 是由 Anthropic 等公司共同开发的开放协议，用于 AI 助手与外部系统之间的标准化交互。

### MCP 的核心能力

| 能力 | 描述 | 示例 |
|------|------|------|
| **Tools** | AI 可以调用的函数 | 读取文件、查询数据库、发送消息 |
| **Resources** | AI 可以访问的数据 | 文档、代码库、知识库 |
| **Prompts** | 预制的提示模板 | 代码审查模板、文档摘要模板 |
| **Sampling** | 服务端调用 AI 模型 | 代码生成、内容补全 |
| **Logging** | 记录操作日志 | 审计、调试 |
| **Notifications** | 发送实时通知 | 任务完成提醒、错误告警 |

### 为什么选择 MCP？

1. **标准化协议** - 不再为每个 AI 写专用集成
2. **安全性** - 权限隔离、操作审计
3. **生态系统** - 与 Cherry Studio、Claude Desktop 等工具兼容
4. **轻量级** - 基于 JSON-RPC，易于实现

---

## vhttpd 的 MCP 架构

vhttpd 的 MCP 支持具有以下特点：

### 传输方式：Streamable HTTP

不同于传统的 WebSocket，vhttpd 使用 **Streamable HTTP** 传输 MCP：

```
MCP Client → POST /mcp (发送请求)
           ↓
vhttpd → 调度到 PHP Worker
           ↓
MCP Client → GET /mcp (获取响应 SSE)
```

这种方式的优势：
- **无 WebSocket 依赖** - 简单的 HTTP 协议
- **更好的兼容性** - 兼容传统代理、负载均衡
- **易于调试** - 标准的 HTTP 流量

### 与 Codex 的区别

| 维度 | MCP | Codex |
|------|-----|-------|
| vhttpd 角色 | **Server**（接收请求） | **Client**（主动连接） |
| 连接方向 | 外部 client → vhttpd | vhttpd → Codex app-server |
| 传输方式 | HTTP Streamable (POST+GET SSE) | WebSocket (persistent) |

---

## 第一步：运行 MCP 示例

让我们查看 vhttpd 的 MCP 配置 [`mcp.toml`](file:///workspace/examples/config/mcp.toml)：

```toml
[server]
host = "127.0.0.1"
port = 19895

[files]
pid_file = "/tmp/vhttpd_mcp.pid"
event_log = "/tmp/vhttpd_mcp.events.ndjson"

[worker]
autostart = true
pool_size = 2
socket = "/tmp/vhttpd_mcp_worker.sock"
read_timeout_ms = 3000
cmd = "php /path/to/php-worker"

[worker.env]
VHTTPD_APP = "/path/to/examples/mcp-app.php"

[admin]
host = "127.0.0.1"
port = 19995
token = ""

[mcp]
max_sessions = 1000
max_pending_messages = 128
session_ttl_seconds = 900
sampling_capability_policy = "error"
allowed_origins = [
  "http://127.0.0.1:19895",
  "http://localhost:19895",
]

[assets]
enabled = false
prefix = "/assets"
root = "/path/to/examples/public"
cache_control = "public, max-age=3600"
```

关键配置说明：
- `max_sessions` - 最大同时连接的 MCP 会话数
- `session_ttl_seconds` - 会话超时时间
- `allowed_origins` - 允许的跨域源

### 启动 vhttpd

```bash
./vhttpd --config examples/config/mcp.toml
```

你会看到：

```
vhttpd starting...
listening on 127.0.0.1:19895
MCP server enabled
worker pool started (2 workers)
```

---

## 第二步：理解 MCP 应用代码

查看 [`mcp-app.php`](file:///workspace/examples/mcp-app.php)：

```php
<?php
declare(strict_types=1);

use VPhp\VSlim\Mcp\App;

$mcp = (new App(
    ['name' => 'vhttpd-mcp-demo', 'version' => '0.1.0'],
    []
))->capabilities([
    'logging' => [],
    'sampling' => [],
])->tool(
    'echo',
    'Echo text back to the caller',
    [
        'type' => 'object',
        'properties' => [
            'text' => ['type' => 'string'],
        ],
        'required' => ['text'],
    ],
    static function (array $arguments): array {
        return [
            'content' => [
                ['type' => 'text', 'text' => (string) ($arguments['text'] ?? '')],
            ],
            'isError' => false,
        ];
    },
)->resource(
    'resource://demo/readme',
    'demo-readme',
    'Read the demo MCP resource payload',
    'text/plain',
    static function (): string {
        return "vhttpd mcp demo resource\n";
    },
)->prompt(
    'welcome',
    'Build a welcome prompt for a named user',
    [
        [
            'name' => 'name',
            'description' => 'Display name for the user',
            'required' => true,
        ],
    ],
    static function (array $arguments): array {
        $name = (string) ($arguments['name'] ?? 'guest');
        return [
            'description' => 'Welcome prompt',
            'messages' => [
                [
                    'role' => 'user',
                    'content' => [
                        [
                            'type' => 'text',
                            'text' => 'Welcome, ' . $name . '!',
                        ],
                    ],
                ],
            ],
        ];
    },
)->register('debug/notify', static function (array $request, array $frame): array {
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $text = (string) ($params['text'] ?? 'hello from server');
    return App::notify(
        $request['id'] ?? null,
        'notifications/message',
        ['text' => $text],
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
        ['queued' => true],
        200,
        ['content-type' => 'application/json; charset=utf-8'],
    );
});

return [
    'mcp' => $mcp,
];
```

这个示例展示了 MCP 的核心功能：
- **注册工具** - `tool()`
- **注册资源** - `resource()`
- **注册提示** - `prompt()`
- **注册自定义方法** - `register()`
- **能力声明** - `capabilities()`

---

## 第三步：测试 MCP

### 使用 curl 直接测试

```bash
# 发送请求到 MCP
curl --noproxy '*' -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "tools/call",
    "params": {
      "name": "echo",
      "arguments": {
        "text": "Hello from MCP!"
      }
    }
  }' \
  http://127.0.0.1:19895/mcp
```

你会收到响应：

```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "result": {
    "content": [
      {
        "type": "text",
        "text": "Hello from MCP!"
      }
    ],
    "isError": false
  }
}
```

### 使用 Cherry Studio 测试

1. 下载并安装 [Cherry Studio](https://cherry.ai)
2. 添加 MCP 服务器：
   ```
   名称：vhttpd MCP
   地址：http://127.0.0.1:19895/mcp
   ```
3. 启动聊天会话，Cherry Studio 会自动发现工具、资源和提示

---

## 第四步：构建实用的 MCP 工具

让我们创建一个更实用的 MCP 工具，例如文件系统操作：

创建 `mcp-filesystem-app.php`：

```php
<?php
declare(strict_types=1);

use VPhp\VSlim\Mcp\App;

$mcp = (new App(
    ['name' => 'vhttpd-filesystem', 'version' => '0.1.0'],
    []
))->capabilities([
    'logging' => [],
    'resources' => [],
    'tools' => [],
])->tool(
    'read_file',
    'Read a text file from the filesystem',
    [
        'type' => 'object',
        'properties' => [
            'path' => [
                'type' => 'string',
                'description' => 'Path to the file',
            ],
        ],
        'required' => ['path'],
    ],
    static function (array $arguments): array {
        $path = (string) ($arguments['path'] ?? '');
        
        // 安全检查
        $realPath = realpath($path);
        if ($realPath === false || !file_exists($realPath)) {
            return [
                'content' => [
                    ['type' => 'text', 'text' => "File not found: {$path}"],
                ],
                'isError' => true,
            ];
        }
        
        $content = file_get_contents($realPath);
        
        return [
            'content' => [
                ['type' => 'text', 'text' => $content],
            ],
            'isError' => false,
        ];
    },
)->tool(
    'write_file',
    'Write content to a file',
    [
        'type' => 'object',
        'properties' => [
            'path' => ['type' => 'string'],
            'content' => ['type' => 'string'],
        ],
        'required' => ['path', 'content'],
    ],
    static function (array $arguments): array {
        $path = (string) ($arguments['path'] ?? '');
        $content = (string) ($arguments['content'] ?? '');
        
        try {
            file_put_contents($path, $content);
            return [
                'content' => [
                    ['type' => 'text', 'text' => "File written: {$path}"],
                ],
                'isError' => false,
            ];
        } catch (Exception $e) {
            return [
                'content' => [
                    ['type' => 'text', 'text' => "Error: {$e->getMessage()}"],
                ],
                'isError' => true,
            ];
        }
    },
)->tool(
    'list_directory',
    'List contents of a directory',
    [
        'type' => 'object',
        'properties' => [
            'path' => ['type' => 'string'],
        ],
        'required' => ['path'],
    ],
    static function (array $arguments): array {
        $path = (string) ($arguments['path'] ?? '.');
        
        $files = scandir($path);
        if ($files === false) {
            return [
                'content' => [
                    ['type' => 'text', 'text' => "Cannot list directory: {$path}"],
                ],
                'isError' => true,
            ];
        }
        
        $listing = implode("\n", array_diff($files, ['.', '..']));
        
        return [
            'content' => [
                ['type' => 'text', 'text' => $listing],
            ],
            'isError' => false,
        ];
    },
)->resource(
    'resource://config/server',
    'vhttpd-config',
    'Read vhttpd server configuration',
    'text/toml',
    static function (): string {
        return file_get_contents('/path/to/config.toml');
    },
);

return [
    'mcp' => $mcp,
];
```

这个示例展示了：
- **多个工具** - read_file、write_file、list_directory
- **资源访问** - 访问配置文件
- **错误处理** - 安全检查和异常处理

---

## 第五步：与飞书机器人集成

vhttpd 的 MCP 可以与飞书机器人完美集成。查看 [`feishu-bot-mcp-app.php`](file:///workspace/examples/feishu-bot-mcp-app.php) 和 [`mcp-feishu-app.php`](file:///workspace/examples/mcp-feishu-app.php)：

### 集成架构

```
用户 → 飞书 → vhttpd WebSocket upstream
              ↓
          PHP Worker
              ↓
        MCP 工具执行
              ↓
          飞书消息发送
```

### 关键代码

```php
use VPhp\VHttpd\Upstream\WebSocket\Feishu\McpToolset;
use VPhp\VSlim\Mcp\App;

$mcp = McpToolset::register(
    new App(['name' => 'vhttpd-mcp-feishu-demo', 'version' => '0.1.0'], [])
);

return [
    'http' => $httpHandler,
    'websocket_upstream' => static fn(array $frame): array => $feishuBotApp->handle($frame),
    'mcp' => $mcp,
];
```

通过这种方式，AI 助手可以：
- 读取飞书消息历史
- 发送飞书卡片消息
- 查询飞书群成员
- 处理飞书事件

---

## 第六步：高级 MCP 功能

### 1. Sampling（服务端调用 AI）

MCP 允许服务端主动调用 AI 模型：

```php
$mcp->register('debug/sample', static function (array $request, array $frame): array {
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $topic = (string) ($params['topic'] ?? 'vhttpd');
    return App::queueSampling(
        $request['id'] ?? null,
        'sample-' . (string) ($request['id'] ?? '1'),
        [
            [
                'role' => 'user',
                'content' => [
                    [
                        'type' => 'text',
                        'text' => 'Summarize topic: ' . $topic,
                    ],
                ],
            ],
        ],
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
        ['hints' => [['name' => 'qwen2.5']]],
        'You are a concise assistant.',
        128,
    );
});
```

### 2. Notifications（发送通知）

```php
$mcp->register('debug/notify', static function (array $request, array $frame): array {
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $text = (string) ($params['text'] ?? 'hello from server');
    return App::notify(
        $request['id'] ?? null,
        'notifications/message',
        ['text' => $text],
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
        ['queued' => true],
        200,
        ['content-type' => 'application/json; charset=utf-8'],
    );
});
```

### 3. Logging（记录日志）

```php
$mcp->register('debug/log', static function (array $request, array $frame): array {
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $message = (string) ($params['message'] ?? 'runtime note');
    return App::queueLog(
        $request['id'] ?? null,
        'info',
        $message,
        ['scope' => 'demo', 'message' => $message],
        'vhttpd-mcp-demo',
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
    );
});
```

### 4. Progress（进度报告）

```php
$mcp->register('debug/progress', static function (array $request, array $frame): array {
    return App::queueProgress(
        $request['id'] ?? null,
        'demo-progress',
        50,
        100,
        'Half way there',
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
    );
});
```

---

## 第七步：监控和调试

### Admin Plane

```bash
# 查看 MCP 运行时状态
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19995/admin/runtime

# 查看活跃的 MCP 会话
curl -H 'x-vhttpd-admin-token: xxx' \
  http://127.0.0.1:19995/admin/runtime/mcp

# 查看事件日志
tail -f /tmp/vhttpd_mcp.events.ndjson
```

### 调试 MCP 通信

MCP 使用 JSON-RPC 2.0 协议：

```json
// 请求
{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "tools/call",
  "params": {
    "name": "echo",
    "arguments": {"text": "test"}
  }
}

// 响应
{
  "jsonrpc": "2.0",
  "id": "1",
  "result": {
    "content": [{"type": "text", "text": "test"}],
    "isError": false
  }
}

// 通知
{
  "jsonrpc": "2.0",
  "method": "notifications/message",
  "params": {
    "text": "Hello from server"
  }
}
```

---

## 最佳实践

### 1. 安全权限控制

```php
// 工具中验证权限
->tool('read_file', ..., static function (array $arguments): array {
    $path = $arguments['path'] ?? '';
    
    // 防止路径遍历
    if (str_contains($path, '..')) {
        return ['content' => [['type' => 'text', 'text' => 'Invalid path']], 'isError' => true];
    }
    
    // 只允许访问特定目录
    $allowedRoot = '/var/app';
    $realPath = realpath($path);
    if (!str_starts_with($realPath, $allowedRoot)) {
        return ['content' => [['type' => 'text', 'text' => 'Access denied']], 'isError' => true];
    }
    
    // ...
});
```

### 2. 资源描述

```php
->resource(
    'resource://docs/api',
    'api-doc',
    'API documentation with endpoints and examples',
    'text/markdown',
    static function (): string {
        return file_get_contents(__DIR__ . '/docs/api.md');
    },
)
```

### 3. 工具参数验证

使用完整的 JSON Schema 描述参数：

```php
->tool(
    'query_database',
    'Query the database',
    [
        'type' => 'object',
        'properties' => [
            'query' => [
                'type' => 'string',
                'description' => 'SQL query to execute',
                'minLength' => 1,
            ],
            'limit' => [
                'type' => 'integer',
                'description' => 'Maximum number of results',
                'minimum' => 1,
                'maximum' => 100,
            ],
        ],
        'required' => ['query'],
    ],
    $handler
)
```

### 4. 错误消息友好化

```php
try {
    // 执行操作
} catch (Exception $e) {
    return [
        'content' => [
            [
                'type' => 'text',
                'text' => "Sorry, I couldn't complete the operation. " .
                          "Error details: {$e->getMessage()}",
            ],
        ],
        'isError' => true,
    ];
}
```

---

## 下一步

恭喜你！你已经掌握了 MCP 服务端开发。在后续文章中，我们将探讨：
- **飞书机器人实战** - 从简单回落到智能对话
- **vjsx 入门** - 用 TypeScript 快速扩展 vhttpd
- **深入理解架构** - 从协议层到运行时

如果你想继续探索，可以：
- 查看 [`feishu-bot-mcp-app.php`](file:///workspace/examples/feishu-bot-mcp-app.php) 了解飞书集成
- 探索 Cherry Studio 的 MCP 生态
- 阅读 MCP 官方规范

---

## 常见问题

**Q: vjsx executor 支持 MCP 吗？**
A: 当前 MCP 主要通过 PHP Worker 实现。vjsx executor 支持 HTTP 和 WebSocket，但暂不支持 MCP。

**Q: 如何实现认证？**
A: 可以在 Worker 层检查请求头，验证 API Key 或 JWT token。

**Q: MCP 支持二进制资源吗？**
A: 可以使用 base64 编码，或返回资源 URI。

**Q: 如何实现长任务？**
A: 使用 notifications + progress 更新，让用户知道任务在进行中。

---

## 相关资源

- [MCP 示例应用](file:///workspace/examples/mcp-app.php)
- [MCP 配置](file:///workspace/examples/config/mcp.toml)
- [飞书 MCP 集成](file:///workspace/examples/mcp-feishu-app.php)
- [MCP vs Codex 分析](file:///workspace/docs/codex_vs_mcp_reuse_analysis.md)
- [MCP 官方规范](https://modelcontextprotocol.io)
- [Cherry Studio](https://cherry.ai)
