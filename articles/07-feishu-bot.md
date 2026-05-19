# 飞书机器人实战：从简单回落到智能对话

在上一篇文章中，我们了解了 MCP 服务端开发。现在，让我们探讨 vhttpd 的另一个强大功能：**飞书机器人集成**。vhttpd 通过 WebSocket upstream 与飞书开放平台连接，让我们可以构建强大的企业智能应用。

---

## 为什么用 vhttpd 做飞书机器人？

传统飞书机器人的问题：
- 需要自己维护 Webhook 服务
- 需要处理签名验证、加密解密
- 需要管理 token 刷新
- 需要处理重连机制

vhttpd 的优势：
- **内置 WebSocket upstream** - 自动连接飞书开放平台
- **自动处理 token 刷新** - 无需关心认证细节
- **事件路由** - 统一的事件分发框架
- **AI 集成** - 与 MCP、流式响应无缝配合
- **可观测性** - Admin Plane 监控机器人状态

---

## 飞书架构概览

### 连接方式

vhttpd 使用飞书的长连接模式：

```
vhttpd → WebSocket → 飞书开放平台
       ↓
    接收事件
       ↓
    PHP Worker
       ↓
    发送响应
```

### 事件处理流程

1. **事件接收** - 从飞书接收消息、卡片点击等事件
2. **事件路由** - 根据事件类型分发到不同处理器
3. **命令解析** - 解析用户输入的命令和参数
4. **业务逻辑** - 执行实际的业务操作
5. **响应发送** - 通过飞书 API 发送响应消息

---

## 第一步：配置飞书机器人

查看 [`feishu-bot.toml`](file:///workspace/examples/config/feishu-bot.toml)：

```toml
[server]
host = "127.0.0.1"
port = 19881

[files]
pid_file = "/tmp/vhttpd_${server.port}.pid"
event_log = "/tmp/vhttpd_${server.port}.events.ndjson"

[worker]
read_timeout_ms = 3000
autostart = true
pool_size = 4
socket_prefix = "/tmp/vslim_worker"
max_requests = 5000
restart_backoff_ms = 500
restart_backoff_max_ms = 8000
cmd = "php /path/to/php-worker"

[worker.env]
VHTTPD_APP = "/path/to/examples/feishu-bot-mcp-app.php"

[admin]
host = "127.0.0.1"
port = 19981
token = "change-me"

[feishu]
enabled = true
open_base_url = "https://open.feishu.cn/open-apis"
reconnect_delay_ms = 3000
token_refresh_skew_seconds = 60
recent_event_limit = 20

[feishu.main]
app_id = "${env.FEISHU_APP_ID:-}"
app_secret = "${env.FEISHU_APP_SECRET:-}"
verification_token = ""
encrypt_key = ""
```

关键配置说明：
- `[feishu].enabled` - 启用飞书集成
- `[feishu.main].app_id` 和 `app_secret` - 飞书应用凭证（从环境变量读取）
- `reconnect_delay_ms` - 重连延迟
- `token_refresh_skew_seconds` - Token 刷新提前量

### 在飞书开放平台创建应用

1. 访问 [飞书开放平台](https://open.feishu.cn)
2. 创建企业自建应用
3. 获取 `App ID` 和 `App Secret`
4. 启用机器人能力
5. 配置订阅事件（消息接收、卡片互动）
6. 设置事件订阅地址（使用 vhttpd 的长连接，不需要公网地址！）

---

## 第二步：理解代码架构

查看 [`codexbot-app`](file:///workspace/examples/codexbot-app) 目录下的结构：

```
examples/codexbot-app/
├── app.php                 # 入口文件
├── autoload.php            # 自动加载
├── lib/
│   ├── AppRuntime.php      # 应用运行时
│   ├── Admin/              # 管理后台
│   ├── Repository/         # 数据访问层
│   ├── Service/            # 业务服务层
│   └── Upstream/           # 上游处理
│       ├── FeishuInboundRouter.php
│       ├── FeishuCommandRouter.php
│       └── FeishuMessageParser.php
└── views/                  # 视图文件
```

### 入口文件

查看 [`codexbot-app/app.php`](file:///workspace/examples/codexbot-app/app.php)：

```php
<?php
declare(strict_types=1);

$codexBotTz = getenv("VHTTPD_BOT_TZ") ?: getenv("TZ") ?: "Asia/Shanghai";
date_default_timezone_set($codexBotTz);

require_once __DIR__ . "/autoload.php";

$runtime = new CodexBot\AppRuntime();
return $runtime->handlers();
```

### 应用运行时

查看 [`codexbot-app/lib/AppRuntime.php`](file:///workspace/examples/codexbot-app/lib/AppRuntime.php)：

```php
<?php
declare(strict_types=1);

namespace CodexBot;

use CodexBot\Admin\AdminHttpApp;
use CodexBot\Upstream\UpstreamGraphFactory;
use VPhp\VHttpd\Upstream\WebSocket\CommandBus;
use VPhp\VHttpd\Upstream\WebSocket\Event;

final class AppRuntime
{
    private ?array $upstreamGraph = null;

    public function __construct(
        private ?UpstreamGraphFactory $graphFactory = null,
        private ?AdminHttpApp $adminHttpApp = null,
    ) {
        $this->graphFactory ??= new UpstreamGraphFactory();
        $this->adminHttpApp ??= new AdminHttpApp();
    }

    public function handle(mixed $request, array $envelope = []): array
    {
        $req = is_array($request) ? $request : $envelope;
        $mode = (string) ($req['mode'] ?? '');

        if ($mode === 'websocket_upstream') {
            return $this->handleWebSocketUpstream($req);
        }

        return $this->handleHttp($req);
    }

    public function handlers(): array
    {
        return [
            'http' => $this,
            'websocket_upstream' => $this,
        ];
    }

    private function handleWebSocketUpstream(array $request): array
    {
        $provider = (string) ($request['provider'] ?? '');
        $eventType = (string) ($request['event_type'] ?? '');
        $payloadRaw = (string) ($request['payload'] ?? '');

        file_put_contents(
            'php://stderr',
            "[PHP] Provider: {$provider}, Event: {$eventType}, Payload: " . substr($payloadRaw, 0, 200) . "...\n"
        );

        $event = Event::fromDispatchRequest($request);
        $bus = $this->upstreamGraph()['event_router']->dispatch($event, new CommandBus());
        return $bus->export();
    }

    private function handleHttp(array $request): array
    {
        return $this->adminHttpApp->handle($request);
    }

    private function upstreamGraph(): array
    {
        if (!is_array($this->upstreamGraph)) {
            $this->upstreamGraph = $this->graphFactory->create();
        }

        return $this->upstreamGraph;
    }
}
```

### 事件路由器

查看 [`codexbot-app/lib/Upstream/FeishuInboundRouter.php`](file:///workspace/examples/codexbot-app/lib/Upstream/FeishuInboundRouter.php)：

```php
<?php
declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\ProjectChannelRepository;

final class FeishuInboundRouter
{
    public function __construct(
        private ProjectChannelRepository $channelRepo,
        private FeishuCommandRouter $commandRouter,
        private FeishuMessageParser $messageParser,
    ) {
    }

    public function dispatch(array $payload): ?array
    {
        $eventType = (string) ($payload['header']['event_type'] ?? '');
        $tenantKey = (string) ($payload['header']['tenant_key'] ?? '');
        $sender = $payload['event']['sender']['sender_id']['open_id'] ?? '';
        $chatId = $payload['event']['message']['chat_id'] ?? '';
        $message = is_array($payload['event']['message'] ?? null) ? $payload['event']['message'] : [];
        $messageType = (string) ($message['message_type'] ?? '');
        $text = $this->messageParser->extractPrompt($message);

        file_put_contents(
            'php://stderr',
            "[PHP] Feishu inbound normalized: type={$messageType}, text_len=" . strlen($text) .
            ", preview=" . substr($text, 0, 160) . "\n"
        );

        $project = $this->channelRepo->findProjectByTarget('feishu', $chatId);
        $project = $this->commandRouter->refreshProjectContext($project);

        if ($text === '') {
            return ['commands' => []];
        }

        return $this->commandRouter->dispatch($text, $project, $chatId, $sender, $payload);
    }
}
```

### 命令路由器

查看 [`codexbot-app/lib/Upstream/FeishuCommandRouter.php`](file:///workspace/examples/codexbot-app/lib/Upstream/FeishuCommandRouter.php)：

```php
<?php
declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\CommandContextRepository;
use CodexBot\Repository\ProjectChannelRepository;
use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\SettingsRepository;
use CodexBot\Repository\TaskRepository;
use CodexBot\Service\CodexSessionService;
use CodexBot\Service\CommandFactory;
use CodexBot\Service\StreamService;
use CodexBot\Service\TaskStateService;
use CodexBot\Service\WorkerAdminService;

final class FeishuCommandRouter
{
    private const DEFAULT_MODEL = 'gpt-5.3-codex';

    public function refreshProjectContext(?array $project): ?array
    {
        if (!is_array($project) || $project === []) {
            return null;
        }

        $projectKey = trim((string) ($project['project_key'] ?? ''));
        if ($projectKey === '') {
            return $project;
        }

        $fresh = $this->projectRepo->findByProjectKey($projectKey);
        if (!is_array($fresh) || $fresh === []) {
            return $project;
        }

        foreach (['channel_thread_key', 'is_primary', 'channel_is_active'] as $key) {
            if (array_key_exists($key, $project)) {
                $fresh[$key] = $project[$key];
            }
        }

        return $fresh;
    }

    public function dispatch(string $text, ?array &$project, string $chatId, string $sender, array $payload): ?array
    {
        $helpResponse = $this->handleHelpCommand($text, $chatId);
        if ($helpResponse !== null) {
            return $helpResponse;
        }

        $createResponse = $this->handleCreateCommand($text, $chatId, $project);
        if ($createResponse !== null) {
            return $createResponse;
        }

        $importResponse = $this->handleImportCommand($text, $chatId, $project);
        if ($importResponse !== null) {
            return $importResponse;
        }

        $settingsResponse = $this->handleSettingsCommand($text, $chatId);
        if ($settingsResponse !== null) {
            return $settingsResponse;
        }

        $bindResponse = $this->handleBindCommand($text, $chatId);
        if ($bindResponse !== null) {
            return $bindResponse;
        }

        $cancelResponse = $this->handleCancelCommand($text, $chatId);
        if ($cancelResponse !== null) {
            return $cancelResponse;
        }

        $workerResponse = $this->handleWorkerCommand($text, $chatId);
        if ($workerResponse !== null) {
            return $workerResponse;
        }

        $configResponse = $this->handleConfigCommand($text, $project, $chatId, $sender, $payload);
        // ...
    }
}
```

---

## 第三步：构建简单的回声机器人

让我们创建一个简单的回声机器人，演示基本功能：

创建 `simple-feishu-bot.php`：

```php
<?php
declare(strict_types=1);

use VPhp\VHttpd\Upstream\WebSocket\CommandBus;
use VPhp\VHttpd\Upstream\WebSocket\Event;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Command;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message;

final class SimpleFeishuBot
{
    public function handleWebSocketUpstream(array $request): array
    {
        $event = Event::fromDispatchRequest($request);
        $bus = new CommandBus();

        if ($event->provider !== 'feishu') {
            return $bus->export();
        }

        $payload = $event->payload;
        $eventType = $payload['header']['event_type'] ?? '';

        if ($eventType !== 'im.message.receive_v1') {
            return $bus->export();
        }

        $message = $payload['event']['message'] ?? [];
        $chatId = $message['chat_id'] ?? '';
        $messageId = $message['message_id'] ?? '';

        $contentRaw = $message['content'] ?? '{}';
        $content = json_decode($contentRaw, true);
        $text = $content['text'] ?? '';

        if ($text === '') {
            return $bus->export();
        }

        $responseText = "你说: {$text}";
        $bus->add(Command::sendText($chatId, $responseText, $messageId));

        return $bus->export();
    }

    public function handleHttp(array $request): array
    {
        $path = $request['path'] ?? '/';
        if ($path === '/health') {
            return [
                'status' => 200,
                'content_type' => 'application/json; charset=utf-8',
                'body' => json_encode(['ok' => true, 'service' => 'simple-feishu-bot']),
            ];
        }

        return [
            'status' => 404,
            'content_type' => 'text/plain; charset=utf-8',
            'body' => 'Not found',
        ];
    }
}

$bot = new SimpleFeishuBot();

return [
    'http' => [$bot, 'handleHttp'],
    'websocket_upstream' => [$bot, 'handleWebSocketUpstream'],
];
```

创建配置 `simple-feishu-bot.toml`：

```toml
[server]
host = "127.0.0.1"
port = 19890

[files]
pid_file = "/tmp/vhttpd_simple_feishu.pid"
event_log = "/tmp/vhttpd_simple_feishu.events.ndjson"

[worker]
autostart = true
pool_size = 2
socket = "/tmp/vslim_simple_feishu_worker.sock"
read_timeout_ms = 3000
cmd = "php /path/to/php-worker"

[worker.env]
VHTTPD_APP = "/path/to/simple-feishu-bot.php"

[admin]
host = "127.0.0.1"
port = 19990
token = "change-me"

[feishu]
enabled = true
open_base_url = "https://open.feishu.cn/open-apis"
reconnect_delay_ms = 3000

[feishu.main]
app_id = "${env.FEISHU_APP_ID:-}"
app_secret = "${env.FEISHU_APP_SECRET:-}"
```

启动机器人：

```bash
export FEISHU_APP_ID="your-app-id"
export FEISHU_APP_SECRET="your-app-secret"

./vhttpd --config simple-feishu-bot.toml
```

现在你可以在飞书群里 @ 机器人，它会回声你说的话！

---

## 第四步：构建带卡片的机器人

飞书机器人的强大之处在于交互式卡片。让我们创建一个：

```php
<?php
declare(strict_types=1);

use VPhp\VHttpd\Upstream\WebSocket\CommandBus;
use VPhp\VHttpd\Upstream\WebSocket\Event;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Command;

final class CardBot
{
    public function handleWebSocketUpstream(array $request): array
    {
        $event = Event::fromDispatchRequest($request);
        $bus = new CommandBus();

        if ($event->provider !== 'feishu') {
            return $bus->export();
        }

        $payload = $event->payload;
        $eventType = $payload['header']['event_type'] ?? '';

        if ($eventType === 'im.message.receive_v1') {
            $message = $payload['event']['message'] ?? [];
            $chatId = $message['chat_id'] ?? '';
            $contentRaw = $message['content'] ?? '{}';
            $content = json_decode($contentRaw, true);
            $text = $content['text'] ?? '';

            if (str_contains($text, '天气')) {
                $bus->add(Command::sendCard($chatId, $this->weatherCard()));
            } else {
                $bus->add(Command::sendCard($chatId, $this->welcomeCard()));
            }
        }

        if ($eventType === 'im.message.action_v1') {
            $action = $payload['event']['action'] ?? [];
            $value = $action['value'] ?? [];
            $chatId = $payload['event']['context']['chat_id'] ?? '';
            $messageId = $payload['event']['context']['open_message_id'] ?? '';
            $actionValue = $value['action'] ?? '';

            if ($actionValue === 'like') {
                $bus->add(Command::sendText($chatId, '谢谢你的喜欢！', $messageId));
            }
        }

        return $bus->export();
    }

    private function welcomeCard(): array
    {
        return [
            'config' => [
                'wide_screen_mode' => true,
            ],
            'header' => [
                'title' => [
                    'tag' => 'plain_text',
                    'content' => '🤖 智能助手',
                ],
                'template' => 'blue',
            ],
            'elements' => [
                [
                    'tag' => 'markdown',
                    'content' => '你好！我是智能助手。\n\n**功能:**\n- 问天气\n- 查资料\n- 帮你处理日常任务',
                ],
                [
                    'tag' => 'hr',
                ],
                [
                    'tag' => 'action',
                    'actions' => [
                        [
                            'tag' => 'button',
                            'text' => ['tag' => 'plain_text', 'content' => '👍 点赞'],
                            'type' => 'primary',
                            'value' => ['action' => 'like'],
                        ],
                    ],
                ],
            ],
        ];
    }

    private function weatherCard(): array
    {
        return [
            'config' => [
                'wide_screen_mode' => true,
            ],
            'header' => [
                'title' => [
                    'tag' => 'plain_text',
                    'content' => '🌤 天气预报',
                ],
                'template' => 'green',
            ],
            'elements' => [
                [
                    'tag' => 'div',
                    'text' => ['tag' => 'lark_md', 'content' => '**北京** - 晴转多云'],
                ],
                [
                    'tag' => 'div',
                    'text' => ['tag' => 'lark_md', 'content' => '气温: 18°C ~ 28°C'],
                ],
                [
                    'tag' => 'div',
                    'text' => ['tag' => 'lark_md', 'content' => '空气质量: 优'],
                ],
            ],
        ];
    }
}
```

---

## 第五步：与 AI 集成

现在让我们把飞书机器人与前面的 AI 集成结合起来：

```php
<?php
declare(strict_types=1);

use VPhp\VHttpd\Upstream\WebSocket\CommandBus;
use VPhp\VHttpd\Upstream\WebSocket\Event;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Command;
use VPhp\VHttpd\VHttpd;

final class AIFeishuBot
{
    public function handleWebSocketUpstream(array $request): array
    {
        $event = Event::fromDispatchRequest($request);
        $bus = new CommandBus();

        if ($event->provider !== 'feishu') {
            return $bus->export();
        }

        $payload = $event->payload;
        $eventType = $payload['header']['event_type'] ?? '';

        if ($eventType !== 'im.message.receive_v1') {
            return $bus->export();
        }

        $message = $payload['event']['message'] ?? [];
        $chatId = $message['chat_id'] ?? '';
        $contentRaw = $message['content'] ?? '{}';
        $content = json_decode($contentRaw, true);
        $text = $content['text'] ?? '';

        if ($text === '') {
            return $bus->export();
        }

        // 发送思考中消息
        $thinkingId = VHttpd::gateway('feishu')->sendText(
            instance: 'main',
            chatId: $chatId,
            text: '正在思考...',
        );

        // 调用 AI API
        $aiResponse = $this->callAI($text);

        // 更新消息
        $bus->add(Command::sendText($chatId, $aiResponse, $thinkingId));

        return $bus->export();
    }

    private function callAI(string $prompt): string
    {
        // 这里可以调用 Ollama、OpenAI 等
        // 为了演示，我们返回一个简单的响应
        return "这是 AI 对 \"{$prompt}\" 的回答。";
    }
}
```

---

## 第六步：使用 Admin Plane 监控

查看飞书机器人状态：

```bash
# 查看运行时状态
curl -H 'x-vhttpd-admin-token: change-me' \
  http://127.0.0.1:19981/admin/runtime

# 查看上游 WebSocket 状态
curl -H 'x-vhttpd-admin-token: change-me' \
  http://127.0.0.1:19981/admin/runtime/upstreams/websocket

# 查看事件日志
tail -f /tmp/vhttpd_19881.events.ndjson
```

---

## 第七步：CodexBot 深度解析

让我们看一下 [`codexbot-app`](file:///workspace/examples/codexbot-app) 的完整架构：

### Admin 后台

查看 [`AdminDashboardLiveView.php`](file:///workspace/examples/codexbot-app/lib/Admin/AdminDashboardLiveView.php)：

```php
<?php
declare(strict_types=1);

namespace CodexBot\Admin;

use CodexBot\Db;
use CodexBot\Repository\ProjectChannelRepository;
use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\SettingsRepository;
use CodexBot\Repository\StreamRepository;
use CodexBot\Repository\TaskRepository;

final class AdminDashboardLiveView extends \VSlim\Live\View
{
    private const TOPIC = 'codexbot-admin-dashboard';

    public function mount(\VSlim\Request $req, \VSlim\Live\Socket $socket): void
    {
        $socket
            ->set_root_id('admin-live-root')
            ->set_target((string) ($req->path ?? '/admin'))
            ->assign('title', 'CodexBot Admin')
            ->assign('subtitle', 'Live operations panel for projects, settings, and runtime state.')
            ->assign('request_path', (string) ($req->path ?? '/admin'))
            ->assign('live_endpoint', '/admin/live')
            // ...
    }

    public function handleEvent(string $event, array $payload, \VSlim\Live\Socket $socket): void
    {
        if ($event === 'refresh_dashboard') {
            $this->clearErrors($socket);
            $this->reloadState($socket, 'Dashboard refreshed.');
            return;
        }

        if ($event === 'create_project') {
            $projectKey = trim((string) ($payload['project_key'] ?? ''));
            $projectName = trim((string) ($payload['name'] ?? ''));
            $repoPath = trim((string) ($payload['repo_path'] ?? ''));

            $socket
                ->assign('create_project_key', $projectKey)
                ->assign('create_project_name', $projectName)
                ->assign('create_project_repo_path', $repoPath);

            $result = $this->mutations->createProject($projectKey, $projectName, $repoPath);
            if (!($result['ok'] ?? false)) {
                $socket
                    ->assign('create_project_error', (string) ($result['message'] ?? 'Unable to create project.'))
                    ->flash('error', (string) ($result['message'] ?? 'Unable to create project.'));
                $this->reloadState($socket);
                return;
            }

            $socket
                ->assign('create_project_key', '')
                ->assign('create_project_name', '')
                ->assign('create_project_repo_path', '')
                ->assign('create_project_error', '')
                ->flash('info', (string) ($result['message'] ?? 'Project created.'));
            $this->reloadState($socket);
            $socket->broadcast_info(self::TOPIC, 'dashboard_refresh', ['source' => 'create_project'], false);
            return;
        }
        // ...
    }
}
```

这是一个实时管理后台，你可以：
- 创建和管理项目
- 查看任务状态
- 管理设置
- 实时查看运行时状态

---

## 最佳实践

### 1. 事件处理

```php
// 总是记录事件
file_put_contents(
    'php://stderr',
    "[PHP] Received event: " . json_encode($payload, JSON_UNESCAPED_UNICODE) . "\n"
);

// 使用 try-catch 处理异常
try {
    // 处理逻辑
} catch (Throwable $e) {
    // 发送错误消息
    $bus->add(Command::sendText($chatId, '抱歉，出错了: ' . $e->getMessage()));
    // 记录错误
    error_log($e);
}
```

### 2. 消息去重

```php
// 使用 messageId 去重
private array $processedMessageIds = [];

public function handleWebSocketUpstream(array $request): array
{
    $messageId = $request['payload']['event']['message']['message_id'] ?? '';
    if (in_array($messageId, $this->processedMessageIds)) {
        return ['commands' => []];
    }
    $this->processedMessageIds[] = $messageId;
    // ...
}
```

### 3. 异步处理

```php
// 发送思考中消息，然后异步处理
$thinkingId = VHttpd::gateway('feishu')->sendText($chatId, '正在处理...');
// ...
// 处理完成后更新消息
$bus->add(Command::sendText($chatId, '处理完成！', $thinkingId));
```

---

## 常见问题

**Q: vhttpd 可以同时连接多个飞书应用吗？**
A: 可以！配置多个 `[feishu.name]` 块即可。

**Q: 需要公网 IP 吗？**
A: 不需要！vhttpd 使用长连接模式，主动连接飞书平台。

**Q: 如何处理机器人重启后丢失上下文？**
A: 使用数据库或 Redis 保存会话状态。

---

## 相关资源

- [CodexBot 示例](file:///workspace/examples/codexbot-app/)
- [飞书配置](file:///workspace/examples/config/feishu-bot.toml)
- [飞书 + MCP 集成](file:///workspace/examples/feishu-bot-mcp-app.php)
- [飞书开放平台文档](https://open.feishu.cn/document)
