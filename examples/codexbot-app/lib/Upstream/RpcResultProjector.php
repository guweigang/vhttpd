<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\StreamRepository;
use CodexBot\Repository\TaskRepository;
use CodexBot\Service\CodexSessionService;
use CodexBot\Service\CommandFactory;
use CodexBot\Service\TaskStateService;

final class RpcResultProjector
{
    public function __construct(
        private TaskRepository $taskRepo,
        private StreamRepository $streamRepo,
        private ProjectRepository $projectRepo,
        private CodexSessionService $sessionService,
        private TaskStateService $taskStateService,
        private BotContextHelper $contextHelper,
        private BotJsonHelper $jsonHelper,
        private BotResponseHelper $responseHelper,
        private ThreadViewHelper $threadViewHelper,
    ) {
    }

    public function handleThreadStartResume(string $method, bool $hasError, array $resultData, string $streamId): ?array
    {
        if (($method !== 'thread/start' && $method !== 'thread/resume') || $hasError) {
            return null;
        }

        $threadId = $resultData['thread']['id'] ?? ($resultData['threadId'] ?? '');
        $taskId = str_replace('codex:', '', $streamId);
        $task = $this->taskRepo->findByTaskId($taskId);
        if (!$task || !$threadId) {
            return null;
        }

        $project = $this->projectRepo->findByProjectKey((string) $task['project_key']);
        $cwd = $project['current_cwd'] ?: $project['repo_path'];
        $this->sessionService->updateThread((string) $task['project_key'], (string) $threadId, (string) $cwd);
        $this->taskRepo->bindThread($taskId, (string) $threadId);
        $this->contextHelper->clearPendingThreadSelections((string) $task['project_key']);

        return $this->responseHelper->commands([
            CommandFactory::codexSessionTurnStart(
                $streamId,
                (string) ($task['task_type'] ?? 'ask'),
                (string) ($task['prompt'] ?? ''),
                [
                    'thread_id' => $threadId,
                    'cwd' => $cwd,
                ]
            )
        ]);
    }

    public function handleThreadRead(string $method, bool $hasError, array $resultData, string $streamId): ?array
    {
        if ($method !== 'thread/read' || $hasError) {
            return null;
        }

        $thread = $resultData['thread'] ?? $resultData;
        if (!is_array($thread) || $thread === []) {
            return null;
        }

        $resolvedThreadId = trim((string) ($thread['id'] ?? ($thread['threadId'] ?? '')));
        $taskId = str_replace('codex:', '', $streamId);
        $task = $taskId !== '' ? $this->taskRepo->findByTaskId($taskId) : null;
        if ($task && !empty($task['project_key']) && !empty($task['thread_id'])) {
            $requestedThreadId = trim((string) ($task['thread_id'] ?? ''));
            $project = $this->projectRepo->findByProjectKey((string) $task['project_key']);
            $cwd = $project ? (($project['current_cwd'] ?: $project['repo_path']) ?: '') : '';
            $effectiveThreadId = $resolvedThreadId !== '' ? $resolvedThreadId : $requestedThreadId;

            if ($resolvedThreadId !== '' && $requestedThreadId !== '' && $resolvedThreadId !== $requestedThreadId) {
                file_put_contents(
                    'php://stderr',
                    "[PHP] thread/read returned different thread id: requested={$requestedThreadId} resolved={$resolvedThreadId}\n"
                );
            }

            if ($effectiveThreadId !== '') {
                if ($taskId !== '') {
                    $this->taskRepo->bindThread($taskId, $effectiveThreadId);
                }
                $this->sessionService->updateThread((string) $task['project_key'], $effectiveThreadId, $cwd);
                $this->contextHelper->clearPendingThreadSelections((string) $task['project_key']);
            }
        }
        if ($taskId !== '') {
            $this->taskStateService->markCompleted($taskId, $streamId);
        }

        $md = $this->threadViewHelper->renderThreadRead($thread);
        return $this->responseHelper->command(CommandFactory::feishuUpdateMarkdown($streamId, $md, JSON_UNESCAPED_UNICODE));
    }

    public function handleTurnStart(string $method, bool $hasError, array $payload, string $streamId): void
    {
        if ($method !== 'turn/start' || $hasError) {
            return;
        }

        $rawContent = $payload['raw_response'] ?? null;
        $raw = is_array($rawContent)
            ? $rawContent
            : (is_string($rawContent) ? $this->jsonHelper->decode($rawContent, 'codex.raw_response') : []);
        $turnId = $raw['result']['turn']['id'] ?? '';
        $taskId = str_replace('codex:', '', $streamId);
        if ($taskId !== '') {
            $task = $this->taskRepo->findByTaskId($taskId);
            if ($task && !empty($task['project_key']) && !empty($task['thread_id'])) {
                $this->sessionService->updateThread(
                    (string) $task['project_key'],
                    (string) $task['thread_id'],
                    (string) ($task['cwd'] ?? '')
                );
            }
        }
        if ($taskId !== '' && $turnId !== '') {
            $this->taskRepo->bindCodexTurn($taskId, (string) $turnId);
        }
        $this->taskStateService->markStreaming($taskId);
    }

    public function renderList(string $method, string $streamId, array $resultData): ?array
    {
        if (!in_array($method, ['thread/list', 'model/list', 'app/list', 'mcpServerStatus/list', 'mcp/list_roots'], true)) {
            return null;
        }

        if ($method === 'thread/list' && $streamId !== '') {
            $stream = $this->streamRepo->findByStreamId($streamId);
            $task = $stream && !empty($stream['task_id'])
                ? $this->taskRepo->findByTaskId((string) $stream['task_id'])
                : null;
            $projectForThreads = null;
            if ($task && !empty($task['project_key'])) {
                $projectForThreads = $this->projectRepo->findByProjectKey((string) $task['project_key']);
            }

            if ($task && (($task['task_type'] ?? '') === 'use_thread_latest')) {
                $threads = $resultData['data'] ?? [];
                $taskId = (string) ($task['task_id'] ?? '');
                if ($taskId !== '') {
                    $this->taskStateService->markCompleted($taskId, $streamId);
                }

                if (!is_array($threads) || $threads === [] || !is_array($threads[0] ?? null)) {
                    return $this->responseHelper->command(CommandFactory::feishuUpdateMarkdown(
                        $streamId,
                        "⚠️ **当前项目下没有可用的历史 Thread**\n\n你可以先在这个项目里直接发任务开启一个新线程，再回来使用 `/use latest`。",
                        JSON_UNESCAPED_UNICODE
                    ));
                }

                $latestThread = $threads[0];
                $latestThreadId = trim((string) ($latestThread['id'] ?? ''));
                if ($latestThreadId === '') {
                    return $this->responseHelper->command(CommandFactory::feishuUpdateMarkdown(
                        $streamId,
                        "⚠️ **最近线程返回不完整**\n\n这次没有拿到可用的 thread_id，请先发送 `/threads` 手动检查。",
                        JSON_UNESCAPED_UNICODE
                    ));
                }

                $this->contextHelper->createPendingThreadSelection(
                    (string) $task['project_key'],
                    $latestThreadId,
                    (string) $task['platform'],
                    (string) $task['channel_id'],
                    $task['user_id'] ?? null,
                    $task['request_message_id'] ?? null
                );

                $title = $this->threadViewHelper->threadLabel($latestThread);
                $md = "🧪 **已暂存最近一个 Codex Thread**\n\n" .
                    "• **Thread**: `{$latestThreadId}`\n" .
                    "• **标题**: {$title}\n\n" .
                    "下一次你直接发任务，或发送 `/thread` 时，我们会先尝试恢复这个线程；只有恢复成功后，才会正式绑定为当前会话。";

                return $this->responseHelper->command(CommandFactory::feishuUpdateMarkdown($streamId, $md, JSON_UNESCAPED_UNICODE));
            }
        } else {
            $projectForThreads = null;
        }

        $md = '';
        if ($method === 'thread/list') {
            $threads = $resultData['data'] ?? [];
            $projectKey = (string) ($projectForThreads['project_key'] ?? '');
            $md = "🧵 **Codex 最近会话列表**";
            if ($projectKey !== '') {
                $md .= "（项目：`{$projectKey}`）";
            }
            $md .= "\n\n";
            if ($threads === []) {
                $md .= "当前项目下还没有历史线程。\n\n你可以先直接发一条任务，开启这个项目自己的新线程。";
            }
            foreach ($threads as $t) {
                $threadId = $t['id'] ?? 'unknown';
                $title = $this->threadViewHelper->threadLabel(is_array($t) ? $t : []);
                $md .= "• `{$threadId}` - _{$title}_\n";
            }
        } elseif ($method === 'model/list') {
            $models = $resultData['data'] ?? [];
            $md = "🤖 **Codex 可用模型列表**\n\n";
            foreach ($models as $m) {
                $modelId = trim((string) ($m['id'] ?? 'unknown'));
                $modelName = trim((string) ($m['name'] ?? ''));
                if ($modelName !== '') {
                    $md .= "• **{$modelId}** ({$modelName})\n";
                } else {
                    $md .= "• **{$modelId}**\n";
                }
            }
        } elseif ($method === 'app/list' || $method === 'mcpServerStatus/list' || $method === 'mcp/list_roots') {
            $items = $resultData['data'] ?? $resultData['apps'] ?? $resultData['servers'] ?? $resultData['roots'] ?? [];
            $md = "**结果列表**\n\n";
            foreach ($items as $item) {
                $md .= "• " . ($item['name'] ?? $item['id'] ?? '未知') . "\n";
            }
        }

        if ($md !== '') {
            return $this->responseHelper->command(CommandFactory::feishuUpdateMarkdown($streamId, $md));
        }

        return null;
    }

    public function renderConfigValue(string $method, string $streamId, array $resultData): ?array
    {
        if ($method !== 'config/read') {
            return null;
        }

        $taskId = str_replace('codex:', '', $streamId);
        $task = $taskId !== '' ? $this->taskRepo->findByTaskId($taskId) : null;
        if ($taskId !== '') {
            $this->taskStateService->markCompleted($taskId, $streamId);
        }

        $path = trim((string) ($resultData['key'] ?? ($resultData['path'] ?? ($task['prompt'] ?? 'config'))));
        $value = $resultData['value']
            ?? ($resultData['data']['value'] ?? null)
            ?? ($path !== '' && array_key_exists($path, $resultData) ? $resultData[$path] : null)
            ?? ($path !== '' && isset($resultData['data']) && is_array($resultData['data']) && array_key_exists($path, $resultData['data']) ? $resultData['data'][$path] : null);
        if (is_array($value)) {
            $value = $value['id'] ?? $value['name'] ?? json_encode($value, JSON_UNESCAPED_UNICODE);
        }
        $valueText = trim((string) ($value ?? ''));
        if ($valueText === '') {
            $valueText = '未设置';
        }

        $md = "🪪 **Codex 当前配置值**\n\n" .
            "• **Path**: `{$path}`\n" .
            "• **Value**: `{$valueText}`";

        return $this->responseHelper->command(CommandFactory::feishuUpdateMarkdown($streamId, $md, JSON_UNESCAPED_UNICODE));
    }
}
