<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\StreamRepository;
use CodexBot\Repository\TaskRepository;
use CodexBot\Service\CommandFactory;
use CodexBot\Service\TaskStateService;

final class CodexNotificationRouter
{
    public function __construct(
        private TaskRepository $taskRepo,
        private StreamRepository $streamRepo,
        private TaskStateService $taskStateService,
        private BotErrorHelper $errorHelper,
        private BotResponseHelper $responseHelper,
        private NotificationLifecycleRouter $lifecycleRouter,
    ) {
    }

    public function dispatch(array $payload, array $request, string $streamId): ?array
    {
        file_put_contents('php://stderr', "[PHP] [v5] Received codex.notification\n");

        $taskId = str_replace('codex:', '', $streamId);
        if ($taskId !== '') {
            $task = $this->taskRepo->findByTaskId($taskId);
            if (($task['status'] ?? '') === 'cancelled') {
                return ['handled' => true];
            }
        }

        $method = $payload['method'] ?? '';
        $params = $payload['params'] ?? [];
        $threadId = $params['threadId'] ?? ($params['thread_id'] ?? ($params['thread']['id'] ?? ''));
        $turnId = $params['turnId'] ?? ($params['turn_id'] ?? ($params['id'] ?? ''));

        $channelHint = '';
        if (isset($payload['channel_id']) && is_string($payload['channel_id'])) {
            $channelHint = trim($payload['channel_id']);
        }
        if ($channelHint === '' && isset($payload['channelId']) && is_string($payload['channelId'])) {
            $channelHint = trim($payload['channelId']);
        }
        if ($channelHint === '' && is_array($request['metadata'] ?? null)) {
            $channelHint = trim((string) (($request['metadata']['channel_id'] ?? '')));
        }

        $lifecycleResponse = $this->lifecycleRouter->dispatch(
            $method,
            is_array($params) ? $params : [],
            $streamId,
            (string) $threadId,
            (string) $turnId,
            $channelHint,
        );
        if ($lifecycleResponse !== null) {
            return $lifecycleResponse;
        }

        return $this->handleError(
            $method,
            is_array($params) ? $params : [],
            $streamId,
            $channelHint
        );
    }

    private function handleError(string $method, array $params, string $streamId, string $channelHint): ?array
    {
        $isSystemError = ($method === 'thread/status/changed' && ($params['status']['type'] ?? '') === 'systemError');
        $isLimitUpdate = (strpos($method, 'rateLimits/updated') !== false);
        if ($method !== 'error' && $method !== 'codex/event/error' && !$isSystemError && !$isLimitUpdate) {
            return null;
        }

        $errorMsg = null;

        if ($isLimitUpdate) {
            $credits = $params['credits'] ?? ($params['msg']['credits'] ?? null);
            if ($credits && isset($credits['hasCredits']) && $credits['hasCredits'] === false) {
                $errorMsg = '您的 Codex 账号额度已耗尽 (Usage Limit)';
            } else {
                return ['handled' => true];
            }
        } else {
            $possibleLocations = [
                $params['error'] ?? null,
                $params['msg'] ?? null,
                $params['status']['error'] ?? null,
                $params['status']['message'] ?? null,
                $params['message'] ?? null,
            ];

            foreach ($possibleLocations as $loc) {
                if (is_string($loc) && $loc !== '') {
                    $errorMsg = $loc;
                    break;
                }
                if (is_array($loc)) {
                    $errorMsg = $loc['message'] ?? ($loc['msg'] ?? ($loc['detail'] ?? null));
                    if ($errorMsg) {
                        break;
                    }
                }
            }
        }

        if ($isSystemError && empty($errorMsg)) {
            usleep(100000);
            try {
                $threadId = $params['threadId'] ?? ($params['thread_id'] ?? '');
                if ($threadId) {
                    $row = $this->taskRepo->findLatestErrorByThreadId($threadId);
                    if (
                        $row
                        && $row['status'] === 'failed'
                        && !empty($row['error_message'])
                        && strpos((string) $row['error_message'], 'System Error') === false
                    ) {
                        return ['handled' => true];
                    }
                }
            } catch (\Exception $e) {
            }

            $errorMsg = '❌ 任务由于服务端异常中断 (System Error)';
        }

        if ($isLimitUpdate) {
            $credits = $params['credits'] ?? ($params['msg']['credits'] ?? null);
            if ($credits && isset($credits['hasCredits']) && $credits['hasCredits'] === false) {
                $errorMsg = '💳 **您的 Codex 账号额度已耗尽 (Usage Limit)**';
                file_put_contents('php://stderr', "[PHP] Detected Out of Credits from notification!\n");
            } else {
                return ['handled' => true];
            }
        }

        if (empty($errorMsg)) {
            $errorMsg = '发生未知错误';
        }

        if ($streamId === '') {
            return $this->handleRecoveryError($params, $channelHint, $errorMsg);
        }

        $msgId = $this->streamRepo->findMessageIdByStreamId($streamId);
        return $this->responseHelper->command(CommandFactory::feishuMessageUpdate([
            'stream_id' => $streamId,
            'target' => $msgId ?: '',
            'message_type' => 'interactive',
            'content' => $this->errorHelper->buildErrorCard($errorMsg),
        ]));
    }

    private function handleRecoveryError(array $params, string $channelHint, string $errorMsg): array
    {
        $turnId = $params['turnId'] ?? ($params['turn_id'] ?? ($params['id'] ?? ''));
        $threadId = $params['threadId'] ?? ($params['thread_id'] ?? '');

        try {
            $lastTaskId = null;
            $chatId = null;
            $messageId = null;
            $streamId = '';
            $row = $this->taskRepo->resolveRecoveryContext((string) $turnId, (string) $threadId, $channelHint);

            if ($row) {
                $streamId = (string) $row['stream_id'];
                $lastTaskId = $row['task_id'];
                $chatId = $row['channel_id'];
                $messageId = $row['response_message_id'];
                file_put_contents(
                    'php://stderr',
                    "[PHP] Recovered context: stream={$streamId} chat={$chatId} msg={$messageId}\n"
                );
            } else {
                file_put_contents(
                    'php://stderr',
                    "[PHP] Skip unsafe fallback: no context by turn/thread for notification recovery\n"
                );
            }

            if ($lastTaskId) {
                $this->taskStateService->markFailed((string) $lastTaskId, $streamId, $errorMsg);
            }

            $commands = [];
            if ($streamId !== '') {
                $commands[] = CommandFactory::feishuMessageUpdate([
                    'stream_id' => $streamId,
                    'target' => $messageId,
                    'message_type' => 'interactive',
                    'content' => $this->errorHelper->buildErrorCard($errorMsg),
                ]);
            }

            if ($chatId) {
                $commands[] = CommandFactory::feishuSend([
                    'target_type' => 'chat_id',
                    'target' => $chatId,
                    'message_type' => 'text',
                    'content' => json_encode(['text' => "⚠️ **Codex 运行时警告**\n\n您的任务遭遇错误：\n{$errorMsg}"]),
                ]);
            }

            if ($commands !== []) {
                return $this->responseHelper->commands($commands);
            }
        } catch (\Exception $e) {
            file_put_contents('php://stderr', "[PHP] DB Error in notification: " . $e->getMessage() . "\n");
        }

        file_put_contents(
            'php://stderr',
            "[PHP] WARNING: Completely failed to recover stream/chat for error alert. params=" . json_encode($params) . "\n"
        );
        return ['handled' => true];
    }
}
