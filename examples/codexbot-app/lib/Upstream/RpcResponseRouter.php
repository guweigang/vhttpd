<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\StreamRepository;
use CodexBot\Repository\TaskRepository;
use CodexBot\Service\CodexSessionService;
use CodexBot\Service\TaskStateService;
use CodexBot\Service\CommandFactory;

final class RpcResponseRouter
{
    public function __construct(
        private TaskRepository $taskRepo,
        private StreamRepository $streamRepo,
        private ProjectRepository $projectRepo,
        private CodexSessionService $sessionService,
        private TaskStateService $taskStateService,
        private BotErrorHelper $errorHelper,
        private BotResponseHelper $responseHelper,
        private RpcResultProjector $projector,
    ) {
    }

    public function dispatch(array $payload, string $method, string $streamId): ?array
    {
        $taskId = str_replace('codex:', '', $streamId);
        if ($taskId !== '') {
            $task = $this->taskRepo->findByTaskId($taskId);
            if (($task['status'] ?? '') === 'cancelled') {
                return ['handled' => true];
            }
        }

        $hasError = (bool) ($payload['has_error'] ?? false);
        $resultData = $payload['result'] ?? [];

        file_put_contents(
            'php://stderr',
            "[PHP] RPC Response: method={$method}, error=" . ($hasError ? 'YES' : 'NO') .
            ", result=" . json_encode($resultData) . "\n"
        );

        if ($hasError) {
            return $this->handleError($method, is_array($resultData) ? $resultData : [], $streamId);
        }

        $threadStartResumeResponse = $this->projector->handleThreadStartResume(
            $method,
            $hasError,
            is_array($resultData) ? $resultData : [],
            $streamId,
        );
        if ($threadStartResumeResponse !== null) {
            return $threadStartResumeResponse;
        }

        $threadReadResponse = $this->projector->handleThreadRead(
            $method,
            $hasError,
            is_array($resultData) ? $resultData : [],
            $streamId,
        );
        if ($threadReadResponse !== null) {
            return $threadReadResponse;
        }

        $this->projector->handleTurnStart(
            $method,
            $hasError,
            $payload,
            $streamId,
        );

        $configValueResponse = $this->projector->renderConfigValue(
            $method,
            $streamId,
            is_array($resultData) ? $resultData : [],
        );
        if ($configValueResponse !== null) {
            return $configValueResponse;
        }

        return $this->projector->renderList(
            $method,
            $streamId,
            is_array($resultData) ? $resultData : [],
        );
    }

    private function handleError(string $method, array $resultData, string $streamId): array
    {
        $taskId = str_replace('codex:', '', $streamId);
        $errMsg = null;

        if ($method === 'codex.error_burst') {
            foreach ($resultData as $rawJson) {
                $item = json_decode((string) $rawJson, true);
                if (!$item) {
                    continue;
                }

                $candidate = $item['error']['message']
                    ?? ($item['message']
                        ?? ($item['params']['error']['message']
                            ?? ($item['params']['msg'] ?? null)));
                if ($candidate && is_string($candidate) && $candidate !== '') {
                    $errMsg = $candidate;
                    break;
                }
            }
        } else {
            $errMsg = $resultData['error']['message'] ?? ($resultData['message'] ?? null);
        }

        if (empty($errMsg)) {
            $errMsg = '发生未知错误';
        }

        if ($this->errorHelper->isThreadNotFound($errMsg)) {
            $task = $taskId !== '' ? $this->taskRepo->findByTaskId($taskId) : null;
            if ($task && !empty($task['project_key'])) {
                $this->sessionService->updateThread((string) $task['project_key'], null, $task['cwd'] ?? null);
            }
            $errMsg .= "\n\n已自动清除当前绑定线程，请重新发送 `/threads` 选择可用会话。";
        }

        return $this->responseHelper->command(
            CommandFactory::feishuMessageUpdate([
                'stream_id' => $streamId,
                'message_type' => 'interactive',
                'content' => $this->errorHelper->buildErrorCard($errMsg),
            ])
        );
    }
}
