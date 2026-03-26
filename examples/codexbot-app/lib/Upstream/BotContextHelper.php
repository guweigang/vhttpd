<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\TaskRepository;

final class BotContextHelper
{
    public function __construct(
        private TaskRepository $taskRepo,
    ) {
    }

    public function resolveStreamContext(
        ?string $streamId,
        ?string $threadId = null,
        ?string $turnId = null,
        ?string $channelId = null
    ): ?array {
        try {
            return $this->taskRepo->resolveStreamContext($streamId, $threadId, $turnId, $channelId);
        } catch (\Throwable $e) {
            file_put_contents('php://stderr', "[PHP] resolve_stream_context failed: " . $e->getMessage() . "\n");
        }

        return null;
    }

    public function findPendingThreadSelection(string $projectKey): ?array
    {
        try {
            return $this->taskRepo->findPendingThreadSelection($projectKey);
        } catch (\Throwable $e) {
            file_put_contents('php://stderr', "[PHP] find_pending_thread_selection failed: " . $e->getMessage() . "\n");
            return null;
        }
    }

    public function preferredThreadId(?array $project): ?string
    {
        if (!is_array($project) || $project === []) {
            return null;
        }

        $projectKey = (string) ($project['project_key'] ?? '');
        if ($projectKey !== '') {
            $pendingSelection = $this->findPendingThreadSelection($projectKey);
            $pendingThreadId = trim((string) ($pendingSelection['thread_id'] ?? ''));
            if ($pendingThreadId !== '') {
                return $pendingThreadId;
            }
        }

        $currentThreadId = trim((string) ($project['current_thread_id'] ?? ''));
        return $currentThreadId !== '' ? $currentThreadId : null;
    }

    public function resolvePendingThreadSelection(string $projectKey, string $threadId): void
    {
        if ($projectKey === '' || $threadId === '') {
            return;
        }

        try {
            $this->taskRepo->resolvePendingThreadSelection($projectKey, $threadId);
        } catch (\Throwable $e) {
            file_put_contents('php://stderr', "[PHP] resolve_pending_thread_selection failed: " . $e->getMessage() . "\n");
        }
    }

    public function createPendingThreadSelection(
        string $projectKey,
        string $threadId,
        string $platform,
        string $channelId,
        ?string $userId,
        ?string $requestMessageId
    ): string {
        $timestamp = date('Ymd_His');
        $shortRandom = substr(md5(uniqid('', true)), 0, 6);
        $taskId = "use_{$timestamp}_{$shortRandom}";
        $this->taskRepo->create([
            'task_id' => $taskId,
            'project_key' => $projectKey,
            'thread_id' => $threadId,
            'platform' => $platform,
            'channel_id' => $channelId,
            'user_id' => $userId,
            'request_message_id' => $requestMessageId,
            'stream_id' => null,
            'task_type' => 'use_thread',
            'prompt' => $threadId,
            'status' => 'pending_bind',
        ]);
        return $taskId;
    }

    public function clearPendingThreadSelections(string $projectKey): void
    {
        if ($projectKey === '') {
            return;
        }

        try {
            $this->taskRepo->clearPendingThreadSelections($projectKey);
        } catch (\Throwable $e) {
            file_put_contents('php://stderr', "[PHP] clear_pending_thread_selections failed: " . $e->getMessage() . "\n");
        }
    }
}
