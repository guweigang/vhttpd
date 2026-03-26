<?php

namespace CodexBot\Service;

use CodexBot\Repository\TaskRepository;
use CodexBot\Repository\StreamRepository;

class StreamService {
    private $taskRepo;
    private $streamRepo;

    public function __construct(TaskRepository $taskRepo, StreamRepository $streamRepo) {
        $this->taskRepo = $taskRepo;
        $this->streamRepo = $streamRepo;
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
        $shortRandom = substr(md5(uniqid()), 0, 6);
        
        $taskId = "task_{$timestamp}_{$shortRandom}";
        $streamId = "codex:{$taskId}";

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
            'status' => 'opened'
        ]);

        return [
            'task_id' => $taskId,
            'stream_id' => $streamId
        ];
    }
}
