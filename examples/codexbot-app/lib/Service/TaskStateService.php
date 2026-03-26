<?php

namespace CodexBot\Service;

use CodexBot\Repository\TaskRepository;
use CodexBot\Repository\StreamRepository;

class TaskStateService {
    private $taskRepo;
    private $streamRepo;

    public function __construct(TaskRepository $taskRepo, StreamRepository $streamRepo) {
        $this->taskRepo = $taskRepo;
        $this->streamRepo = $streamRepo;
    }

    public function markStreaming(string $taskId): void {
        if ($taskId === '') {
            return;
        }
        if ($this->isCancelledTask($taskId)) {
            return;
        }
        $this->taskRepo->updateStatus($taskId, 'streaming');
    }

    public function markCompleted(?string $taskId, ?string $streamId): void {
        $taskId = trim((string) ($taskId ?? ''));
        $streamId = trim((string) ($streamId ?? ''));
        if ($this->isCancelledTask($taskId)) {
            return;
        }
        if ($taskId !== '') {
            $this->taskRepo->updateStatus($taskId, 'completed');
        }
        if ($streamId !== '') {
            $this->streamRepo->updateStatus($streamId, 'completed');
        }
    }

    public function markFailed(?string $taskId, ?string $streamId, ?string $errorMessage = null): void {
        $taskId = trim((string) ($taskId ?? ''));
        $streamId = trim((string) ($streamId ?? ''));
        if ($this->isCancelledTask($taskId)) {
            return;
        }
        if ($taskId !== '') {
            $this->taskRepo->updateStatus($taskId, 'failed', $errorMessage);
        }
        if ($streamId !== '') {
            $this->streamRepo->updateStatus($streamId, 'failed');
        }
    }

    public function markCancelled(?string $taskId, ?string $streamId, ?string $errorMessage = null): void {
        $taskId = trim((string) ($taskId ?? ''));
        $streamId = trim((string) ($streamId ?? ''));
        if ($taskId !== '') {
            $this->taskRepo->updateStatus($taskId, 'cancelled', $errorMessage);
        }
        if ($streamId !== '') {
            $this->streamRepo->updateStatus($streamId, 'cancelled');
        }
    }

    public function markFromContext(?array $context, string $status, ?string $errorMessage = null): void {
        if (!is_array($context) || $context === []) {
            return;
        }
        $taskId = (string) ($context['task_id'] ?? '');
        $streamId = (string) ($context['stream_id'] ?? '');
        if ($status === 'completed') {
            $this->markCompleted($taskId, $streamId);
            return;
        }
        if ($status === 'failed') {
            $this->markFailed($taskId, $streamId, $errorMessage);
            return;
        }
        if ($status === 'streaming' && $taskId !== '') {
            $this->markStreaming($taskId);
        }
    }

    private function isCancelledTask(string $taskId): bool {
        if ($taskId === '') {
            return false;
        }

        $task = $this->taskRepo->findByTaskId($taskId);
        return (($task['status'] ?? '') === 'cancelled');
    }
}
