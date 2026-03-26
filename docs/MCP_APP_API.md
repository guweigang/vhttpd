# `VSlim\Mcp\App` API

这页专门整理 `VPhp\VSlim\Mcp\App` 的高层 API。

目标不是解释 MCP 全规范，而是回答一个更实用的问题：

- 在 PHP userland 里，什么时候该 `register(...)`
- 什么时候该 `capability(...)`
- 什么时候直接用 `tool/resource/prompt`
- 什么时候用 `notification/request`
- 什么时候用 `queue*` helper

核心文件：

- [`/Users/guweigang/Source/vhttpd/php/package/src/VSlim/Mcp/App.php`](/Users/guweigang/Source/vhttpd/php/package/src/VSlim/Mcp/App.php)

## Mental Model

可以把 `App` 分成三层：

1. 注册层
   - 定义 server 提供哪些 tools/resources/prompts/methods/capabilities
2. builder 层
   - 构造 JSON-RPC notification / request
3. queue 层
   - 把 notification / request 排进当前 MCP session 的 SSE 队列

也就是说：

- `tool(...)` / `resource(...)` / `prompt(...)`
  是“注册能力”
- `capability(...)` / `capabilities(...)`
  是“声明 server capabilities”
- `notification(...)` / `request(...)`
  是“构造消息”
- `queue*`
  是“把消息放进 session outbound queue”

## 1. Registration API

### `register(string $method, callable $handler): self`

完全自定义一个 MCP method。

适合：

- 你要处理自定义 method
- 你要自己决定返回 JSON-RPC body
- 你要自己决定是否排队通知 / request

### `capability(string $name, array $definition = []): self`

显式声明一条 server capability。

适合：

- 你想声明 `logging`
- 你想声明 `sampling`
- 你不想只依赖 `tool/resource/prompt` 的自动推导

最小示例：

```php
$mcp->capability('sampling', []);
```

### `capabilities(array $definitions): self`

批量声明 server capabilities。

最小示例：

```php
$mcp->capabilities([
    'logging' => [],
    'sampling' => [],
]);
```

说明：

- 显式声明优先于自动推导
- `tool(...)` / `resource(...)` / `prompt(...)` 仍会自动补出
  `tools` / `resources` / `prompts`
- 但如果你已经显式声明了同名 capability，`App` 不会覆盖它

### `tool(string $name, string $description, array $inputSchema, callable $handler): self`

注册 tool 定义，并自动接入：

- `tools/list`
- `tools/call`

### `resource(string $uri, string $name, string $description, string $mimeType, callable $handler): self`

注册 resource 定义，并自动接入：

- `resources/list`
- `resources/read`

### `prompt(string $name, string $description, array $arguments, callable $handler): self`

注册 prompt 定义，并自动接入：

- `prompts/list`
- `prompts/get`

## 2. Builder API

这些 helper 只负责“生成 JSON-RPC 消息字符串”，不会自动排进 session queue。

### `notification(string $method, array $params = []): string`

构造 notification：

```php
App::notification('notifications/message', ['text' => 'hello']);
```

### `request(mixed $id, string $method, array $params = []): string`

构造 request：

```php
App::request('req-1', 'ping', ['from' => 'server']);
```

### `samplingRequest(...)`

构造 `sampling/createMessage` request。

适合：

- 先把 sampling 当成标准 MCP request relay
- 不手写 `sampling/createMessage` payload

最小示例：

```php
App::samplingRequest(
    'sample-1',
    [
        [
            'role' => 'user',
            'content' => [
                ['type' => 'text', 'text' => 'Summarize topic: runtime contract'],
            ],
        ],
    ],
    ['hints' => [['name' => 'qwen2.5']]],
    'You are a concise assistant.',
    128,
);
```

## 3. Queue API

这些 helper 会返回一个完整的 `mcp` handler result：

- JSON body
- `messages[]`
- `protocol_version`
- `session_id`

也就是它们会直接参与：

- `POST /mcp`
- `GET /mcp`
- 当前 session 的 pending queue

### `queuedResult(...)`

最低层的 queue helper。

如果你已经手工构造好了 `messages[]`，可以直接用它。

### `queueMessages(...)`

比 `queuedResult(...)` 稍高一层。

适合：

- 你已经有一组 MCP message string
- 只是不想再重复拼 `body / headers / queued result`

### `notify(...)`

最常用的一层。

一条 notification + 一个标准 `{queued: true}` result：

```php
return App::notify(
    $request['id'] ?? null,
    'notifications/message',
    ['text' => 'hello from server'],
    (string) ($frame['session_id'] ?? ''),
    (string) ($frame['protocol_version'] ?? '2025-11-05'),
);
```

### `queueNotification(...)`

语义上比 `notify(...)` 更直白，等价于“把一条 notification 排进 queue”。

适合你想统一使用 `queue*` 命名体系时。

### `queueRequest(...)`

把一条 server-to-client request 排进 queue。

适合：

- `sampling/createMessage`
- 未来其他 server -> client request

### `queueSampling(...)`

在 `queueRequest(...)` 之上的 sampling 专用 helper。

这是当前做 `sampling` 的推荐入口。

### `queueProgress(...)`

排一条 `notifications/progress`。

最小示例：

```php
return App::queueProgress(
    $request['id'] ?? null,
    'demo-progress',
    50,
    100,
    'Half way there',
    (string) ($frame['session_id'] ?? ''),
    (string) ($frame['protocol_version'] ?? '2025-11-05'),
);
```

### `queueLog(...)`

排一条 `notifications/message` 风格的日志消息。

适合：

- 运行提示
- 调试消息
- demo / tracing

## Recommended Usage

### 普通 MCP server 能力

优先用：

- `tool(...)`
- `resource(...)`
- `prompt(...)`

### 一条简单的 server notification

优先用：

- `notify(...)`

### 一条更显式的 queued notification / request

优先用：

- `queueNotification(...)`
- `queueRequest(...)`

### Sampling

优先用：

- `queueSampling(...)`

不要直接在 `vhttpd` 里把 sampling 和 upstream execution 混起来。

### 进度 / 日志

优先用：

- `queueProgress(...)`
- `queueLog(...)`

## Current Example Coverage

这些 helper 目前都已经有 example 或 focused regression 覆盖：

- 示例：
  - [`/Users/guweigang/Source/vhttpd/examples/mcp-app.php`](/Users/guweigang/Source/vhttpd/examples/mcp-app.php)
- focused regression：
  - [`/Users/guweigang/Source/vphpx/vslim/tests/test_php_worker_mcp_dispatch.phpt`](/Users/guweigang/Source/vphpx/vslim/tests/test_php_worker_mcp_dispatch.phpt)

当前 focused test 已覆盖：

- builtin tools/resources/prompts
- queued notification
- sampling request
- progress helper
- log helper
- queued request helper
