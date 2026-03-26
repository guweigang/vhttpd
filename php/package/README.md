# vhttpd PHP Package

Composer package root for publishing to Packagist.

Project overview:

- [`/Users/guweigang/Source/vhttpd/docs/OVERVIEW.md`](/Users/guweigang/Source/vhttpd/docs/OVERVIEW.md)

## Mode split

这套代码现在明确分成两种使用方式：

- 安装了 `vslim.so`
  优先使用扩展暴露的 `VSlim\*`
- 没有安装 `vslim.so`，只使用 Composer package
  使用这里提供的 `VPhp\VHttpd\*` 和 `VPhp\VSlim\*`

最重要的一条边界是：

- 扩展模式下的流式响应类型：`VSlim\Stream\Response`
- 纯 PHP package 模式下的流式组件：`VPhp\VSlim\Stream\*`

## Install

```bash
composer require vphpext/vhttpd
```

## Usage

```php
<?php

declare(strict_types=1);

require __DIR__ . '/vendor/autoload.php';

$mgr = new VPhp\VHttpd\Manager(
    '/path/to/vhttpd',
    '127.0.0.1',
    19881,
    '/tmp/vhttpd.pid',
    '/tmp/vhttpd.events.ndjson',
    '/tmp/vhttpd.stdout.log'
);
```

Primary classes:

- `VPhp\\VHttpd\\Manager`
- `VPhp\\VHttpd\\VHttpd`
- `VPhp\\VHttpd\\AdminClient`
- `VPhp\\VHttpd\\Psr7Adapter`
- `VPhp\\VHttpd\\Attribute\\Dispatchable`
- `VPhp\\VHttpd\\Upstream\\Plan`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\Command`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\CommandFactory`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\CommandBatch`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\CommandBus`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\Event`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\EventRouter`
- `VPhp\\VSlim\\Psr7Adapter`
- `VPhp\\VHttpd\\PhpWorker\\Server`
- `VPhp\\VHttpd\\PhpWorker\\Client`
- `VPhp\\VHttpd\\PhpWorker\\StreamResponse`
- `VPhp\\VSlim\\WebSocket\\App`
- `VPhp\\VHttpd\\PhpWorker\\WebSocket\\Connection`
- `VPhp\\VHttpd\\PhpWorker\\WebSocket\\CommandSink`
- `VPhp\\VHttpd\\PhpWorker\\WebSocket\\CommandBuffer`
- `VPhp\\VSlim\\Mcp\\App`
- `VPhp\\VSlim\\App\\Feishu\\BotApp`
- `VPhp\\VSlim\\App\\Feishu\\BotHandler`
- `VPhp\\VSlim\\App\\Feishu\\BotAdapter`
- `VPhp\\VSlim\\DbGateway\\PDO` (experimental)
- `VPhp\\VSlim\\DbGateway\\PDOStatement` (experimental)
- `VSlim\\Container` (PSR-11, provided by `vslim.so` when `psr` extension is enabled)
- `VSlim\\Container\\NotFoundException` (provided by `vslim.so`)
- `VSlim\\Container\\ContainerException` (provided by `vslim.so`)

Pure PHP package stream helpers:

- `VPhp\\VSlim\\Stream\\Response`
- `VPhp\\VSlim\\Stream\\Factory`
- `VPhp\\VSlim\\Stream\\OllamaClient`
- `VPhp\\VSlim\\Stream\\NdjsonDecoder`
- `VPhp\\VSlim\\Stream\\SseEncoder`

Phase 3 planning helpers:

- `VPhp\\VHttpd\\Upstream\\Plan`
- `VPhp\\VSlim\\Stream\\Factory::ollamaUpstreamTextPlan(...)`
- `VPhp\\VSlim\\Stream\\Factory::ollamaUpstreamSsePlan(...)`

These are now executable by `vhttpd` itself for the phase-3 Ollama path:
the worker returns a plan, and `vhttpd` owns the live upstream stream.

Composer bin entrypoints:

- `vendor/bin/php-worker`
- `vendor/bin/php-worker-client`

Internal host socket protocol:

- [`/Users/guweigang/Source/vhttpd/docs/INTERNAL_HOST_SOCKET_PROTOCOL.md`](/Users/guweigang/Source/vhttpd/docs/INTERNAL_HOST_SOCKET_PROTOCOL.md)

Role map:

- [`PACKAGE_ROLE_MAP.md`](/Users/guweigang/Source/vhttpd/php/package/PACKAGE_ROLE_MAP.md)

## PhpWorker Dispatchables

`PhpWorker` 直接识别和调度的对象，现在可以用
`VPhp\\VHttpd\\Attribute\\Dispatchable` 显式表达。

当前约定的 kind 包括：

- `http`
- `websocket`
- `stream`
- `mcp`
- `websocket_upstream`

内建类型和这个 attribute 会一起工作：

- `VSlim\\App` 仍然是原生 `http` dispatchable
- `VPhp\\VSlim\\WebSocket\\App` 标记为 `websocket`
- `VPhp\\VHttpd\\PhpWorker\\StreamApp` 标记为 `stream`
- `VPhp\\VSlim\\Mcp\\App` 标记为 `mcp`

你也可以给自定义 PHP 类加这个 attribute，让 `PhpWorker\\Server` 直接识别它。

## Feishu namespace split

Feishu APIs are now described in two layers:

- app-facing APIs:
  - `VPhp\\VSlim\\App\\Feishu\\BotApp`
  - `VPhp\\VSlim\\App\\Feishu\\BotHandler`
  - `VPhp\\VSlim\\App\\Feishu\\BotAdapter`
- provider-facing APIs:
  - `VPhp\\VHttpd\\Upstream\\WebSocket\\Feishu\\Command`
  - `VPhp\\VHttpd\\Upstream\\WebSocket\\Feishu\\Event`
  - `VPhp\\VHttpd\\Upstream\\WebSocket\\Feishu\\Message`
  - `VPhp\\VHttpd\\Upstream\\WebSocket\\Feishu\\Content\\*`

当前 package 里已经直接按 provider/app split 落到新目录，不再把 Feishu app-facing API 挂在 `PhpWorker` 下。

## Normalized upstream command API

PHP package 现在也开始提供一层更稳定的 websocket upstream command/event API，
方便 app 代码直接表达 normalized contract，而不是手写数组：

- `VPhp\\VHttpd\\Upstream\\WebSocket\\Command`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\CommandFactory`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\CommandBatch`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\CommandBus`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\Event`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\EventHandler`
- `VPhp\\VHttpd\\Upstream\\WebSocket\\EventRouter`

一个最小示例：

```php
<?php

use VPhp\VHttpd\Upstream\WebSocket\CommandBus;
use VPhp\VHttpd\Upstream\WebSocket\CommandFactory;
use VPhp\VHttpd\Upstream\WebSocket\Event;

$event = Event::fromDispatchRequest($request);
$bus = new CommandBus();

$bus->send(CommandFactory::providerMessageSend('feishu', [
    'target_type' => 'chat_id',
    'target' => 'oc_demo',
    'message_type' => 'text',
    'content' => json_encode(['text' => 'hello']),
]));

return $bus->export();
```

## MCP helper

更系统的 API 整理见：

- [`/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md`](/Users/guweigang/Source/vhttpd/docs/MCP_APP_API.md)

`VPhp\VSlim\Mcp\App` 现在可以直接注册工具，不用手写 `tools/list` / `tools/call`：

```php
<?php

declare(strict_types=1);

use VPhp\VSlim\Mcp\App;

$mcp = (new App(
    ['name' => 'demo-mcp', 'version' => '0.1.0'],
))->tool(
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
                ['type' => 'text', 'text' => (string)($arguments['text'] ?? '')],
            ],
            'isError' => false,
        ];
    },
);

return [
    'mcp' => $mcp,
];
```

这样 `initialize`、`tools/list`、`tools/call` 都会走 `App` 的内建行为；如果你确实需要完全自定义协议行为，仍然可以继续用 `register(...)`。

如果你想显式声明 server capability，而不只依赖自动推导，也可以直接：

```php
$mcp->capabilities([
    'logging' => [],
    'sampling' => [],
]);
```

这样 `initialize.result.capabilities` 里就会带上这些声明；同时 `tool/resource/prompt` 仍会继续自动补出 `tools/resources/prompts`。

资源也可以直接注册，不用手写 `resources/list` / `resources/read`：

```php
$mcp->resource(
    'resource://demo/readme',
    'demo-readme',
    'Read the demo MCP resource payload',
    'text/plain',
    static function (): string {
        return "hello resource\n";
    },
);
```

这样 `App` 会自动提供内建的 `resources/list` 和 `resources/read`。

Prompt 也可以直接注册：

```php
$mcp->prompt(
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
        return [
            'messages' => [
                [
                    'role' => 'user',
                    'content' => [
                        ['type' => 'text', 'text' => 'Welcome, ' . ($arguments['name'] ?? 'guest') . '!'],
                    ],
                ],
            ],
        ];
    },
);
```

这样 `App` 会自动提供内建的 `prompts/list` 和 `prompts/get`。

如果你需要把服务端通知排进 MCP session 的 SSE 队列，也不用自己手写 JSON：

```php
$mcp->register('debug/notify', static function (array $request, array $frame): array {
    return App::notify(
        $request['id'] ?? null,
        'notifications/message',
        ['text' => 'hello from server'],
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
        ['queued' => true],
    );
});
```

这样返回值里的 `messages[]` 会被 `vhttpd` 放进当前 MCP session 的 pending queue，后续通过 `GET /mcp` 的 SSE 流推给客户端。

如果你想显式启用 Feishu MCP 工具，而不是把 Feishu 语义绑定到所有 MCP app，可以单独注册：

```php
use VPhp\VHttpd\Upstream\WebSocket\Feishu\McpToolset;
use VPhp\VSlim\Mcp\App;

$mcp = McpToolset::register(
    new App(['name' => 'demo-mcp-feishu', 'version' => '0.1.0'])
);
```

这样会注册：

- `feishu.list_chats`
- `feishu.send_text`

`feishu.list_chats` 不再依赖全局注入的 Feishu 上下文。它会显式通过：

- `VPhp\\VHttpd\\VHttpd::admin()->get('/runtime/feishu/chats')`

去读取 `vhttpd` 宿主的运行态快照。所以只有显式启用了 Feishu MCP 工具集的 app，才会接触到 Feishu chats 语义。

`VPhp\VHttpd\VHttpd::gateway('feishu')` also uses the same internal unix socket. The current host gateway helpers support:

- `sendText(...)`
- `sendImage(...)`
- `uploadImageData(...)`
- `sendLocalImage(...)`
- `sendRemoteImage(...)`

For `/feishu/images`, PHP no longer base64-encodes image bytes into JSON by default. The request now uses:

1. a JSON header frame
2. a raw binary image frame

Current image safety limits:

- PHP side: 10 MB maximum image size
- `vhttpd` side: 10 MB maximum image size
- remote image helper: `Content-Length` precheck when available

如果你想手工构造多条通知，仍然可以继续用：

- `App::notification(...)`
- `App::queuedResult(...)`

Sampling 也可以先走 helper builder，而不用自己拼 `sampling/createMessage`：

```php
$mcp->register('debug/sample', static function (array $request, array $frame): array {
    return App::queueSampling(
        $request['id'] ?? null,
        'sample-' . ($request['id'] ?? '1'),
        [
            [
                'role' => 'user',
                'content' => [
                    ['type' => 'text', 'text' => 'Summarize topic: runtime contract'],
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

这个 helper 当前只负责把 `sampling/createMessage` 请求排进 MCP session queue；真正的 sampling 执行仍然属于 MCP client，不在 `vhttpd` 内部完成。

如果你想把这层再抽象得更通用，当前还可以直接用：

- `App::queueMessages(...)`
- `App::queueNotification(...)`
- `App::queueRequest(...)`
- `App::queueProgress(...)`
- `App::queueLog(...)`

最小 progress 示例：

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

最小 log / queued request 示例：

```php
$mcp->register('debug/log', static function (array $request, array $frame): array {
    return App::queueLog(
        $request['id'] ?? null,
        'info',
        'hello log',
        ['scope' => 'demo', 'message' => 'hello log'],
        'vhttpd-mcp-demo',
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
    );
});

$mcp->register('debug/request', static function (array $request, array $frame): array {
    return App::queueRequest(
        $request['id'] ?? null,
        'req-' . ($request['id'] ?? '1'),
        'ping',
        ['from' => 'server'],
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
    );
});
```

## StreamResponse quick examples

`StreamResponse` is the common streaming contract for any PHP app behind `vhttpd`.

如果你在写的是纯 PHP package app，用：

- `VPhp\VHttpd\PhpWorker\StreamResponse`
- `VPhp\VSlim\Stream\*`

如果你写的是安装了 `vslim.so` 的 VSlim app，用：

- `VSlim\Stream\Response`

### Plain PHP handler

```php
<?php

declare(strict_types=1);

use VPhp\VHttpd\PhpWorker\StreamResponse;

return function (array $envelope) {
    $prompt = (string)($envelope['query']['prompt'] ?? 'hello');
    $events = (function () use ($prompt) {
        foreach (preg_split('//u', $prompt, -1, PREG_SPLIT_NO_EMPTY) as $i => $token) {
            yield [
                'event' => 'token',
                'id' => 'tok-' . ($i + 1),
                'data' => $token,
            ];
        }
    })();
    return StreamResponse::sse($events);
};
```

### Laravel-style endpoint return

```php
<?php

declare(strict_types=1);

use Illuminate\Http\Request;
use VPhp\VHttpd\PhpWorker\StreamResponse;

Route::get('/ai/stream', function (Request $request) {
    $prompt = (string)$request->query('prompt', 'hello');
    $chunks = (function () use ($prompt) {
        foreach (str_split($prompt) as $ch) {
            yield $ch;
        }
    })();
    return StreamResponse::text($chunks, 200, 'text/plain; charset=utf-8', [
        'content-type' => 'text/plain; charset=utf-8',
    ]);
});
```

### VSlim extension route return

```php
<?php

declare(strict_types=1);

$app = new VSlim\App();

$app->get('/stream/text', function () {
    return VSlim\Stream\Response::text((function (): iterable {
        yield "hello\n";
        yield "world\n";
    })());
});
```

## Experimental DB gateway client

```php
<?php

declare(strict_types=1);

use VPhp\VSlim\DbGateway\PDO;

$db = new PDO('/tmp/vhttpd_db.sock');
$db->ping();

$stmt = $db->prepare('SELECT id, name FROM users WHERE id = ?');
$stmt->execute([123]);
$row = $stmt->fetch();

$db->beginTransaction();
try {
    $db->execute('UPDATE accounts SET balance = balance - ? WHERE id = ?', [100, 1]);
    $db->execute('UPDATE accounts SET balance = balance + ? WHERE id = ?', [100, 2]);
    $db->commit();
} catch (Throwable $e) {
    $db->rollBack();
    throw $e;
}
```

## VSlim global container (PSR-11)

```php
<?php

declare(strict_types=1);

use VSlim\Container;

$container = new Container();
$container->set('app.name', 'vslim-demo');
$container->factory('clock', fn () => new DateTimeImmutable('now'));

Container::setGlobal($container);

$global = Container::requireGlobal();
echo $global->get('app.name') . PHP_EOL;
```

## Publish workflow

```bash
cd /Users/guweigang/Source/vhttpd/php/package
composer validate
# tag and push from the dedicated vhttpd package repository, then let Packagist sync
```
