<?php

namespace CodexBot\Service;

use CodexBot\Repository\TaskRepository;
use VHttpd\Feishu\CreationClient;
use CodexBot\Db;
use CodexBot\Repository\StreamRepository;

class StreamService {
    private $taskRepo;
    private $streamRepo;

    public function __construct(TaskRepository $taskRepo, StreamRepository $streamRepo, private ?CreationClient $creationClient = null) {
        $this->taskRepo = $taskRepo;
        $this->streamRepo = $streamRepo;
    }

    public function issueCreation(string $streamId, string $instance = 'main'): \VHttpd\Feishu\CreationLease {
        return ($this->creationClient ??= CreationClient::fromEnvironment())->issue($streamId, $instance);
    }

    public function createStreamTask(array $context): array {
        $platform = $context['platform'];
        $channelId = $context['channel_id'];
        $projectKey = $context['project_key'];
        $prompt = $context['prompt'];
        $userId = $context['user_id'] ?? null;
        $msgId = $context['request_message_id'] ?? null;
        $threadId = $context['thread_id'] ?? null;
        $taskType = $context['task_type'] ?? 'ask';

        $timestamp = date('Ymd_His');
        $shortRandom = bin2hex(random_bytes(8));
        
        $taskId = "task_{$timestamp}_{$shortRandom}";
        $streamId = "codex:{$taskId}";

        $creation = $platform === 'feishu' ? $this->issueCreation($streamId, (string) ($context['instance'] ?? 'main')) : null;
        $db = null;
        $started = false;
        $savepoint = 'creation_' . bin2hex(random_bytes(8));
        try {
            $db = Db::getConnection();
            $db->exec('SAVEPOINT ' . $savepoint);
            $started = true;
            // 1. Create Task Record
            $this->taskRepo->create([
                'task_id' => $taskId,
                'project_key' => $projectKey,
                'thread_id' => $threadId,
                'platform' => $platform,
                'channel_id' => $channelId,
                'user_id' => $userId,
                'request_message_id' => $msgId,
                'stream_id' => $streamId,
                'task_type' => $taskType,
                'prompt' => $prompt,
                'status' => 'queued'
            ]);

            // 2. Create Stream Record
            $this->streamRepo->create([
                'stream_id' => $streamId,
                'task_id' => $taskId,
                'platform' => $platform,
                'channel_id' => $channelId,
                'status' => 'opened',
                'stream_generation' => $creation?->generation ?? '',
                'stream_instance' => $context['instance'] ?? 'main',
                'stream_publication_id' => $creation?->request['request_id'] ?? '',
                'stream_creation_token' => $creation?->token ?? '',
                'stream_creation_request' => $creation === null ? '{}' : json_encode($creation->request, JSON_THROW_ON_ERROR)
            ]);

            $db->exec('RELEASE SAVEPOINT ' . $savepoint);
        } catch (\Throwable $error) {
            if ($started) {
                try {
                    $db->exec('ROLLBACK TO SAVEPOINT ' . $savepoint);
                    $db->exec('RELEASE SAVEPOINT ' . $savepoint);
                } catch (\Throwable) { /* Preserve the original write failure. */ }
            }
            if ($creation !== null) { try { $this->creationClient->revoke($creation); } catch (\Throwable) { /* Bounded server expiry releases an unreachable grant. */ } }
            throw $error;
        }
        return [
            'creation' => $creation,
            'task_id' => $taskId,
            'stream_id' => $streamId
        ];
    }
}
