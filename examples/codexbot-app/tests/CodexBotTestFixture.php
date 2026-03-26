<?php
declare(strict_types=1);

namespace Tests;

use CodexBot\AppRuntime;
use CodexBot\Upstream\BotContextHelper;
use CodexBot\Upstream\BotErrorHelper;
use CodexBot\Upstream\BotJsonHelper;
use CodexBot\Upstream\BotResponseHelper;
use CodexBot\Upstream\CodexNotificationRouter;
use CodexBot\Upstream\FeishuCommandRouter;
use CodexBot\Upstream\FeishuMessageParser;
use CodexBot\Upstream\NotificationLifecycleRouter;
use CodexBot\Upstream\RpcResponseRouter;
use CodexBot\Upstream\RpcResultProjector;
use CodexBot\Upstream\ThreadViewHelper;
use CodexBot\Upstream\UpstreamGraphFactory;
use VPhp\VHttpd\Upstream\WebSocket\EventRouter;
use PDO;

final class CodexBotTestFixture
{
    private static array $booted = [];
    private ?array $ctx = null;
    private ?array $graph = null;
    private ?AppRuntime $runtime = null;

    public function bootstrap(string $dbSuffix = 'pest'): array
    {
        if (!isset(self::$booted[$dbSuffix])) {
            $dbPath = codex_bot_test_db_path($dbSuffix);
            codex_bot_test_init_schema($dbPath);

            putenv('VHTTPD_BOT_DB_PATH=' . $dbPath);
            $app = require dirname(codex_bot_test_app_dir()) . '/codexbot-app.php';

            self::$booted[$dbSuffix] = [
                'db_path' => $dbPath,
                'handler' => $app['websocket_upstream'],
                'http_handler' => $app['http'],
            ];
        }

        $pdo = codex_bot_test_db(self::$booted[$dbSuffix]['db_path']);
        codex_bot_test_reset_state($pdo);
        codex_bot_test_seed_default_binding($pdo);

        $ctx = self::$booted[$dbSuffix];
        $this->ctx = $ctx;
        $this->graph = null;
        $this->runtime = null;
        return $ctx;
    }

    public function context(): array
    {
        $this->ensureBootstrapped();
        return $this->ctx;
    }

    public function handler(): callable
    {
        return $this->context()['handler'];
    }

    public function httpHandler(): callable
    {
        return $this->context()['http_handler'];
    }

    public function dbPath(): string
    {
        return $this->context()['db_path'];
    }

    public function db(): PDO
    {
        return codex_bot_test_db($this->dbPath());
    }

    public function graph(): array
    {
        $this->ensureBootstrapped();

        if (!is_array($this->graph)) {
            $this->graph = (new UpstreamGraphFactory())->create();
        }

        return $this->graph;
    }

    public function runtime(): AppRuntime
    {
        $this->ensureBootstrapped();

        if (!$this->runtime instanceof AppRuntime) {
            $this->runtime = new AppRuntime();
        }

        return $this->runtime;
    }

    public function eventRouter(): EventRouter
    {
        return $this->graph()['event_router'];
    }

    public function feishuCommandRouter(): FeishuCommandRouter
    {
        return $this->graph()['feishu_command_router'];
    }

    public function threadViewHelper(): ThreadViewHelper
    {
        return new ThreadViewHelper();
    }

    public function messageParser(): FeishuMessageParser
    {
        return $this->graph()['message_parser'];
    }

    public function contextHelper(): BotContextHelper
    {
        return $this->graph()['context_helper'];
    }

    public function errorHelper(): BotErrorHelper
    {
        return $this->graph()['error_helper'];
    }

    public function responseHelper(): BotResponseHelper
    {
        return $this->graph()['response_helper'];
    }

    public function jsonHelper(): BotJsonHelper
    {
        return $this->graph()['json_helper'];
    }

    public function rpcResponseRouter(): RpcResponseRouter
    {
        return $this->graph()['rpc_response_router'];
    }

    public function notificationRouter(): CodexNotificationRouter
    {
        return $this->graph()['codex_notification_router'];
    }

    public function rpcResultProjector(): RpcResultProjector
    {
        return $this->graph()['rpc_result_projector'];
    }

    public function notificationLifecycleRouter(): NotificationLifecycleRouter
    {
        return $this->graph()['notification_lifecycle_router'];
    }

    public function seedProject(PDO $pdo, string $projectKey, string $name, string $repoPath, string $defaultBranch = 'main'): void
    {
        $now = date('Y-m-d H:i:s');
        $stmt = $pdo->prepare(
            "INSERT INTO projects (project_key, name, repo_path, default_branch, current_model, current_thread_id, current_cwd, is_active, created_at, updated_at)
             VALUES (?, ?, ?, ?, NULL, NULL, ?, 1, ?, ?)"
        );
        $stmt->execute([$projectKey, $name, $repoPath, $defaultBranch, $repoPath, $now, $now]);
    }

    public function startThread(callable $handler): string
    {
        $taskResp = $handler(codex_bot_test_inbound('请创建一个测试任务'));
        $streamId = (string) ($taskResp['commands'][1]['stream_id'] ?? '');

        $handler([
            'mode' => 'websocket_upstream',
            'provider' => 'codex',
            'event_type' => 'codex.rpc.response',
            'payload' => json_encode([
                'stream_id' => $streamId,
                'method' => 'thread/start',
                'has_error' => false,
                'result' => ['thread' => ['id' => 'thread_ut_001']],
            ], JSON_UNESCAPED_UNICODE),
        ]);

        return $streamId;
    }

    public function createRegularTask(callable $handler, string $text = '请创建一个测试任务'): array
    {
        $resp = $handler(codex_bot_test_inbound($text));
        $streamId = (string) ($resp['commands'][1]['stream_id'] ?? '');
        $taskId = str_replace('codex:', '', $streamId);

        return [
            'response' => $resp,
            'stream_id' => $streamId,
            'task_id' => $taskId,
        ];
    }

    public function commandText(array $command): string
    {
        $content = json_decode((string) ($command['content'] ?? ''), true);
        if (!is_array($content)) {
            return '';
        }

        if (!empty($content['text']) && is_string($content['text'])) {
            return $content['text'];
        }

        $elements = $content['elements'] ?? [];
        if (is_array($elements) && !empty($elements[0]['content']) && is_string($elements[0]['content'])) {
            return $elements[0]['content'];
        }

        return '';
    }

    private function ensureBootstrapped(): void
    {
        if (!is_array($this->ctx) || getenv('VHTTPD_BOT_DB_PATH') === false || getenv('VHTTPD_BOT_DB_PATH') === '') {
            $this->bootstrap();
        }
    }
}
