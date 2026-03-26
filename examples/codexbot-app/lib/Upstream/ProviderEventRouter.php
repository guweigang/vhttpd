<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\StreamRepository;
use CodexBot\Service\TaskStateService;

final class ProviderEventRouter
{
    public function __construct(
        private StreamRepository $streamRepo,
        private TaskStateService $taskStateService,
        private RpcResponseRouter $rpcResponseRouter,
        private CodexNotificationRouter $codexNotificationRouter,
    ) {
    }

    public function dispatch(string $provider, string $eventType, array $payload, array $request): ?array
    {
        if ($provider !== 'codex' && $provider !== 'feishu') {
            return null;
        }

        $streamId = $payload['stream_id'] ?? $request['trace_id'] ?? '';
        $method = $payload['method'] ?? '';

        if ($eventType === 'codex.rpc.response') {
            return $this->rpcResponseRouter->dispatch($payload, (string) $method, (string) $streamId);
        }

        if ($eventType === 'codex.turn.completed') {
            $status = $payload['status'] ?? '';
            $taskId = str_replace('codex:', '', $streamId);
            $finalStatus = ($status === 'completed') ? 'completed' : 'failed';

            if ($finalStatus === 'completed') {
                $this->taskStateService->markCompleted($taskId, $streamId);
            } else {
                $this->taskStateService->markFailed($taskId, $streamId);
            }

            return ['handled' => true];
        }

        if ($eventType === 'codex.notification') {
            return $this->codexNotificationRouter->dispatch($payload, $request, (string) $streamId);
        }

        if ($eventType === 'feishu.message.sent' || $eventType === 'feishu.message.updated') {
            $messageId = $payload['message_id'] ?? '';
            if ($streamId && $messageId) {
                $this->streamRepo->bindResponseMessageId($streamId, $messageId);
            }
        }

        return null;
    }
}
