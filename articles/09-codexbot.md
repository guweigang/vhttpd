# 从零构建 AI 编程助手：codexbot 案例深度解析

在前面的文章中，我们已经了解了 vjsx 的基础能力。现在，让我们通过一个完整的实际案例——codexbot——来深入了解如何构建一个功能强大的 AI 编程助手。codexbot 是 vhttpd 生态中的旗舰应用，它集成了 Codex 协议、飞书平台、实时协作等多项能力。

---

## 什么是 Codex？

Codex 是 OpenAI 开发的 AI 编程协议，它让 AI 助手能够：

- 读写文件
- 执行命令
- 搜索代码
- 进行代码审查
- 实时协作

vhttpd 通过 WebSocket upstream 连接到 Codex 服务器，实现完整的协议支持。

---

## codexbot 架构概览

### 整体架构

```
用户 → 飞书 → vhttpd (WebSocket upstream)
                ↓
          PHP Worker
                ↓
        ┌───────┴───────┐
        ↓               ↓
   Codex Session    Admin Dashboard
        ↓               ↓
   Codex Server     实时 WebSocket
```

### 核心组件

查看 [`codexbot-app`](file:///workspace/examples/codexbot-app) 目录结构：

```
codexbot-app/
├── app.php                    # 应用入口
├── autoload.php               # 自动加载
├── lib/
│   ├── AppRuntime.php         # 应用运行时
│   ├── Db.php                 # 数据库连接
│   ├── Admin/                 # 管理后台
│   │   ├── AdminDashboardLiveView.php
│   │   ├── AdminHttpApp.php
│   │   └── ...
│   ├── Repository/            # 数据访问层
│   │   ├── ProjectRepository.php
│   │   ├── CommandContextRepository.php
│   │   └── ...
│   ├── Service/               # 业务服务层
│   │   ├── CodexSessionService.php
│   │   ├── StreamService.php
│   │   └── ...
│   └── Upstream/              # 上游处理
│       ├── FeishuInboundRouter.php
│       ├── FeishuCommandRouter.php
│       └── ...
└── views/                     # 视图文件
```

---

## 第一步：理解应用入口

查看 [`codexbot-app/app.php`](file:///workspace/examples/codexbot-app/app.php)：

```php
<?php
declare(strict_types=1);

/**
 * Codex + Feishu Bot Implementation for vhttpd.
 */

$codexBotTz = getenv("VHTTPD_BOT_TZ") ?: getenv("TZ") ?: "Asia/Shanghai";
date_default_timezone_set($codexBotTz);

require_once __DIR__ . "/autoload.php";

$runtime = new CodexBot\AppRuntime();
return $runtime->handlers();
```

入口文件非常简洁：
1. 设置时区
2. 加载自动加载文件
3. 创建应用运行时实例
4. 返回处理器集合

---

## 第二步：应用运行时详解

查看 [`lib/AppRuntime.php`](file:///workspace/examples/codexbot-app/lib/AppRuntime.php)：

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

核心设计：

1. **双模式处理** - HTTP 请求和 WebSocket upstream 事件
2. **延迟初始化** - `upstreamGraph` 使用延迟加载
3. **统一事件分发** - 所有事件通过 `EventRouter` 统一处理

---

## 第三步：飞书消息路由

查看 [`lib/Upstream/FeishuInboundRouter.php`](file:///workspace/examples/codexbot-app/lib/Upstream/FeishuInboundRouter.php)：

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

        // 记录日志
        file_put_contents(
            'php://stderr',
            "[PHP] Feishu inbound normalized: type={$messageType}, text_len=" . strlen($text) .
            ", preview=" . substr($text, 0, 160) . "\n"
        );

        // 查找关联的项目
        $project = $this->channelRepo->findProjectByTarget('feishu', $chatId);
        $project = $this->commandRouter->refreshProjectContext($project);

        // 空消息直接返回
        if ($text === '') {
            return ['commands' => []];
        }

        // 路由到命令处理器
        return $this->commandRouter->dispatch($text, $project, $chatId, $sender, $payload);
    }
}
```

消息路由流程：

1. **解析消息** - 提取文本内容
2. **查找项目** - 根据 chat_id 查找关联的项目
3. **刷新上下文** - 更新项目最新状态
4. **命令分发** - 根据消息内容路由到不同处理器

---

## 第四步：命令路由器

查看 [`lib/Upstream/FeishuCommandRouter.php`](file:///workspace/examples/codexbot-app/lib/Upstream/FeishuCommandRouter.php)：

```php
<?php
declare(strict_types=1);

namespace CodexBot\Upstream;

final class FeishuCommandRouter
{
    private const DEFAULT_MODEL = 'gpt-5.3-codex';

    public function dispatch(string $text, ?array &$project, string $chatId, string $sender, array $payload): ?array
    {
        // 1. 帮助命令
        $helpResponse = $this->handleHelpCommand($text, $chatId);
        if ($helpResponse !== null) {
            return $helpResponse;
        }

        // 2. 创建项目
        $createResponse = $this->handleCreateCommand($text, $chatId, $project);
        if ($createResponse !== null) {
            return $createResponse;
        }

        // 3. 导入项目
        $importResponse = $this->handleImportCommand($text, $chatId, $project);
        if ($importResponse !== null) {
            return $importResponse;
        }

        // 4. 设置管理
        $settingsResponse = $this->handleSettingsCommand($text, $chatId);
        if ($settingsResponse !== null) {
            return $settingsResponse;
        }

        // 5. 绑定项目
        $bindResponse = $this->handleBindCommand($text, $chatId);
        if ($bindResponse !== null) {
            return $bindResponse;
        }

        // 6. 取消操作
        $cancelResponse = $this->handleCancelCommand($text, $chatId);
        if ($cancelResponse !== null) {
            return $cancelResponse;
        }

        // 7. 工作线程管理
        $workerResponse = $this->handleWorkerCommand($text, $chatId);
        if ($workerResponse !== null) {
            return $workerResponse;
        }

        // 8. 配置命令（发送到 Codex）
        $configResponse = $this->handleConfigCommand($text, $project, $chatId, $sender, $payload);
        if ($configResponse !== null) {
            return $configResponse;
        }

        // 默认：发送到 Codex 会话
        return $this->handleDefaultCommand($text, $project, $chatId, $sender);
    }
}
```

命令处理链：

1. **help** - 显示帮助信息
2. **create** - 创建新项目
3. **import** - 导入现有项目
4. **settings** - 管理设置
5. **bind** - 绑定项目到频道
6. **cancel** - 取消当前操作
7. **worker** - 工作线程管理
8. **config** - 发送配置命令
9. **default** - 默认发送到 Codex 会话

---

## 第五步：Codex 会话服务

查看 [`lib/Service/CodexSessionService.php`](file:///workspace/examples/codexbot-app/lib/Service/CodexSessionService.php)（概念性）：

```php
<?php
declare(strict_types=1);

namespace CodexBot\Service;

final class CodexSessionService
{
    private array $sessions = [];
    private array $threads = [];

    public function createSession(string $projectKey, string $model = 'gpt-5.3-codex'): string
    {
        $sessionId = $this->generateSessionId();

        $this->sessions[$sessionId] = [
            'id' => $sessionId,
            'project_key' => $projectKey,
            'model' => $model,
            'status' => 'initializing',
            'created_at' => time(),
        ];

        // 初始化 Codex 线程
        $this->threads[$sessionId] = $this->initializeCodexThread($sessionId);

        return $sessionId;
    }

    public function sendMessage(string $sessionId, string $message): array
    {
        $session = $this->sessions[$sessionId] ?? null;
        if (!$session) {
            return ['error' => 'Session not found'];
        }

        // 发送到 Codex
        $response = $this->sendToCodex($sessionId, $message);

        return [
            'ok' => true,
            'response' => $response,
            'session_id' => $sessionId,
        ];
    }

    public function getSessionStatus(string $sessionId): array
    {
        return $this->sessions[$sessionId] ?? ['error' => 'Session not found'];
    }

    private function initializeCodexThread(string $sessionId): array
    {
        // 调用 Codex API 初始化线程
        return [
            'id' => $this->generateThreadId(),
            'session_id' => $sessionId,
            'status' => 'idle',
        ];
    }

    private function sendToCodex(string $sessionId, string $message): string
    {
        // 实现与 Codex 服务器的通信
        // ...
        return "Codex response for: {$message}";
    }

    private function generateSessionId(): string
    {
        return 'sess_' . bin2hex(random_bytes(16));
    }

    private function generateThreadId(): string
    {
        return 'thread_' . bin2hex(random_bytes(16));
    }
}
```

Codex 会话服务的核心功能：

1. **创建会话** - 为每个项目创建独立的 Codex 会话
2. **发送消息** - 将用户消息转发到 Codex
3. **状态管理** - 跟踪会话状态
4. **线程管理** - 管理 Codex 线程

---

## 第六步：TypeScript 实现（codexbot-app-ts）

查看 TypeScript 版本的实现 [`codexbot-app-ts`](file:///workspace/examples/codexbot-app-ts)：

### 入口文件

```typescript
// examples/codexbot-app-ts/app.mts
const bot = {
  http(ctx: any) {
    return ctx.json(
      {
        ok: true,
        kind: "http",
        dispatchKind: ctx.runtime.dispatchKind,
        path: ctx.path,
      },
      200,
    );
  },

  websocket_upstream(frame: any) {
    const payload = frame.payloadJson({});
    const prompt =
      typeof payload.text === "string" && payload.text.trim() !== ""
        ? payload.text
        : "empty";

    return {
      handled: true,
      commands: [
        {
          type: "provider.message.send",
          provider: frame.provider,
          instance: frame.instance,
          target: frame.target,
          target_type: frame.targetType || "chat_id",
          message_type: "text",
          text: `received: ${prompt}`,
          metadata: {
            event_type: frame.eventType,
            dispatch_kind: frame.runtime.dispatchKind,
          },
        },
      ],
    };
  },
};

export default bot;
```

### Codex 协议定义

查看 [`codex/protocol.mts`](file:///workspace/examples/codexbot-app-ts/codex/protocol.mts)：

```typescript
export const CODEX_THREAD_STATUS = Object.freeze({
  NOT_LOADED: "notLoaded",
  IDLE: "idle",
  SYSTEM_ERROR: "systemError",
  ACTIVE: "active",
});

export const CODEX_THREAD_ACTIVE_FLAG = Object.freeze({
  WAITING_ON_APPROVAL: "waitingOnApproval",
  WAITING_ON_USER_INPUT: "waitingOnUserInput",
});

export const CODEX_TURN_STATUS = Object.freeze({
  COMPLETED: "completed",
  INTERRUPTED: "interrupted",
  FAILED: "failed",
  IN_PROGRESS: "inProgress",
});

export const CODEX_MESSAGE_PHASE = Object.freeze({
  COMMENTARY: "commentary",
  FINAL_ANSWER: "final_answer",
});

export function normalizeCodexThreadStatus(value: any): string {
  if (typeof value !== "string") {
    return "";
  }
  const trimmed = value.trim();
  const lowered = trimmed.toLowerCase();
  if (lowered === CODEX_THREAD_STATUS.NOT_LOADED.toLowerCase()) {
    return CODEX_THREAD_STATUS.NOT_LOADED;
  }
  if (lowered === CODEX_THREAD_STATUS.IDLE.toLowerCase()) {
    return CODEX_THREAD_STATUS.IDLE;
  }
  if (lowered === CODEX_THREAD_STATUS.SYSTEM_ERROR.toLowerCase()) {
    return CODEX_THREAD_STATUS.SYSTEM_ERROR;
  }
  if (lowered === CODEX_THREAD_STATUS.ACTIVE.toLowerCase()) {
    return CODEX_THREAD_STATUS.ACTIVE;
  }
  return trimmed;
}

export function isCodexThreadIdleStatus(value: any): boolean {
  return normalizeCodexThreadStatus(value) === CODEX_THREAD_STATUS.IDLE;
}

export function isCodexThreadActiveStatus(value: any): boolean {
  return normalizeCodexThreadStatus(value) === CODEX_THREAD_STATUS.ACTIVE;
}

export function isCodexTurnInProgress(value: any): boolean {
  return value?.toLowerCase() === "inprogress";
}

export function isCodexTurnFailed(value: any): boolean {
  return value?.toLowerCase() === "failed";
}
```

这些协议定义帮助我们：

1. **类型安全** - 使用 TypeScript 类型
2. **状态规范化** - 统一处理不同大小写
3. **状态检查** - 方便的状态判断函数

---

## 第七步：Admin Dashboard 实时功能

查看 [`lib/Admin/AdminDashboardLiveView.php`](file:///workspace/examples/codexbot-app/lib/Admin/AdminDashboardLiveView.php)：

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
            // 分配表单数据
            ->assign('create_project_key', (string) $socket->get('create_project_key'))
            ->assign('create_project_name', (string) $socket->get('create_project_name'))
            ->assign('create_project_repo_path', (string) $socket->get('create_project_repo_path'))
            // 加载当前状态
            $this->reloadState($socket);
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
            // 广播刷新事件
            $socket->broadcast_info(self::TOPIC, 'dashboard_refresh', ['source' => 'create_project'], false);
            return;
        }
        // ... 其他事件处理
    }

    private function reloadState(\VSlim\Live\Socket $socket, ?string $message = null): void
    {
        $socket->assign('projects', $this->projectRepo->findAll());
        $socket->assign('settings', $this->settingsRepo->findAll());
        $socket->assign('tasks', $this->taskRepo->findRecent());
        $socket->assign('streams', $this->streamRepo->findActive());
        if ($message) {
            $socket->flash('info', $message);
        }
    }
}
```

Admin Dashboard 的实时功能：

1. **Live View** - 实时更新的管理界面
2. **事件驱动** - 通过 WebSocket 实时推送更新
3. **表单处理** - 创建项目、修改设置等
4. **状态同步** - 所有连接的用户看到相同状态

---

## 第八步：部署和配置

### 配置文件

查看 [`codexbot.toml`](file:///workspace/examples/codexbot-app/codexbot.toml)：

```toml
[server]
host = "0.0.0.0"
port = 19881

[files]
pid_file = "/var/run/vhttpd_codexbot.pid"
event_log = "/var/log/vhttpd_codexbot.events.ndjson"

[worker]
autostart = true
pool_size = 4
socket_prefix = "/tmp/vslim_codexbot"
read_timeout_ms = 30000
max_requests = 5000

[admin]
host = "0.0.0.0"
port = 19981
token = "${ADMIN_TOKEN}"

[feishu]
enabled = true
open_base_url = "https://open.feishu.cn/open-apis"
reconnect_delay_ms = 5000
token_refresh_skew_seconds = 120

[feishu.main]
app_id = "${FEISHU_APP_ID}"
app_secret = "${FEISHU_APP_SECRET}"

[codex]
enabled = true
server_url = "${CODEX_SERVER_URL}"
api_key = "${CODEX_API_KEY}"
default_model = "gpt-5.3-codex"
max_concurrent_sessions = 100

[db]
driver = "sqlite"
path = "/var/lib/codexbot/codexbot.db"
```

### 启动脚本

```bash
#!/bin/bash
# start-codexbot.sh

export ADMIN_TOKEN="your-secure-token"
export FEISHU_APP_ID="your-feishu-app-id"
export FEISHU_APP_SECRET="your-feishu-app-secret"
export CODEX_SERVER_URL="https://api.cohere.ai"
export CODEX_API_KEY="your-codex-api-key"

cd /path/to/vhttpd
./vhttpd --config examples/codexbot-app/codexbot.toml
```

---

## 第九步：最佳实践

### 1. 会话管理

```php
// 使用数据库持久化会话
class SessionRepository {
    public function save(Session $session): void {
        $stmt = $this->db->prepare(
            'INSERT OR REPLACE INTO sessions (id, project_key, model, status, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?)'
        );
        $stmt->execute([
            $session->id,
            $session->projectKey,
            $session->model,
            $session->status,
            $session->createdAt,
            time(),
        ]);
    }

    public function findById(string $id): ?Session {
        $row = $this->db->query(
            'SELECT * FROM sessions WHERE id = ?',
            [$id]
        )->fetch();
        return $row ? Session::fromArray($row) : null;
    }
}
```

### 2. 错误恢复

```php
// 自动重连和状态恢复
class CodexConnectionManager {
    private int $retryCount = 0;
    private const MAX_RETRIES = 3;

    public function connect(): bool {
        try {
            $this->codexClient->connect();
            $this->retryCount = 0;
            return true;
        } catch (Exception $e) {
            $this->retryCount++;
            if ($this->retryCount < self::MAX_RETRIES) {
                sleep(pow(2, $this->retryCount)); // 指数退避
                return $this->connect();
            }
            return false;
        }
    }
}
```

### 3. 资源清理

```php
// 定期清理过期会话
class SessionCleanupService {
    public function cleanup(int $maxAgeSeconds = 3600): int {
        $cutoff = time() - $maxAgeSeconds;
        $count = $this->sessionRepo->deleteOlderThan($cutoff);
        $this->logger->info("Cleaned up {$count} expired sessions");
        return $count;
    }
}
```

---

## 第十步：监控和调试

### Admin Plane API

```bash
# 查看运行时状态
curl -H 'x-vhttpd-admin-token: xxx' \
  http://localhost:19981/admin/runtime

# 查看活跃会话
curl -H 'x-vhttpd-admin-token: xxx' \
  http://localhost:19981/admin/codex/sessions

# 查看项目列表
curl -H 'x-vhttpd-admin-token: xxx' \
  http://localhost:19981/admin/projects

# 查看事件日志
tail -f /var/log/vhttpd_codexbot.events.ndjson
```

### 日志分析

```bash
# 统计错误
cat /var/log/vhttpd_codexbot.events.ndjson | \
  jq 'select(.kind | startswith("error"))' | \
  wc -l

# 分析命令使用
cat /var/log/vhttpd_codexbot.events.ndjson | \
  jq 'select(.kind == "command.execute")' | \
  jq -r '.command' | \
  sort | \
  uniq -c | \
  sort -rn
```

---

## 常见问题

**Q: Codex 和 MCP 有什么区别？**
A: Codex 是 OpenAI 的编程协议，vhttpd 作为客户端连接；MCP 是通用 AI 协议，vhttpd 作为服务端接收请求。

**Q: 如何支持多个飞书机器人？**
A: 配置多个 `[feishu.name]` 块，每个有不同的 app_id。

**Q: 会话数据如何持久化？**
A: 使用数据库（SQLite/MySQL/PostgreSQL）存储会话和项目信息。

**Q: 如何扩展到多个 Codex 实例？**
A: 使用负载均衡器分发会话，或实现会话亲和性。

---

## 下一步

恭喜你！已经深入了解了 codexbot 的完整架构。在后续文章中，我们将继续探索：

- **架构深度解析** - 从协议层到运行时的完整流程
- **可观测性实战** - 监控、调试和运维最佳实践
- **高级模式** - 多监听器、数据库连接池等

如果你想继续探索，可以：
- 查看完整的 [`codexbot-app`](file:///workspace/examples/codexbot-app) 源码
- 查看 TypeScript 版本的 [`codexbot-app-ts`](file:///workspace/examples/codexbot-app-ts)
- 阅读 Codex 协议规范

---

## 相关资源

- [CodexBot PHP 版本](file:///workspace/examples/codexbot-app/)
- [CodexBot TypeScript 版本](file:///workspace/examples/codexbot-app-ts/)
- [Codex 协议定义](file:///workspace/examples/codexbot-app-ts/codex/protocol.mts)
- [飞书集成](file:///workspace/examples/feishu-bot-mcp-app.php)
- [Admin Dashboard](file:///workspace/examples/codexbot-app/lib/Admin/AdminDashboardLiveView.php)
