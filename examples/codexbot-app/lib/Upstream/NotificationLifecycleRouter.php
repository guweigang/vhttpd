<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\TaskRepository;
use CodexBot\Service\CommandFactory;
use CodexBot\Service\TaskStateService;

final class NotificationLifecycleRouter
{
    public function __construct(
        private TaskRepository $taskRepo,
        private TaskStateService $taskStateService,
        private BotContextHelper $contextHelper,
        private BotErrorHelper $errorHelper,
        private BotResponseHelper $responseHelper,
    ) {
    }

    public function dispatch(
        string $method,
        array $params,
        string $streamId,
        string $threadId,
        string $turnId,
        string $channelHint
    ): ?array {
        if ($method === 'item/agentMessage/delta') {
            $delta = (string) ($params['delta'] ?? '');
            if ($delta !== '') {
                $context = $this->contextHelper->resolveStreamContext($streamId, $threadId, $turnId, $channelHint);
                if (($context['status'] ?? '') === 'cancelled') {
                    return ['handled' => true];
                }
                if ($context && !empty($context['response_message_id'])) {
                    return $this->responseHelper->command(CommandFactory::feishuStreamAppend([
                        'target' => $context['response_message_id'],
                        'stream_id' => $context['stream_id'],
                        'text' => $delta,
                        'metadata' => ['mode' => 'append'],
                    ]));
                }
            }
            return ['handled' => true];
        }

        if ($method === 'turn/failed') {
            $context = $this->contextHelper->resolveStreamContext($streamId, $threadId, $turnId, $channelHint);
            if (($context['status'] ?? '') === 'cancelled') {
                return ['handled' => true];
            }
            $turn = $params['turn'] ?? [];
            $turnError = is_array($turn) ? ($turn['error']['message'] ?? ($turn['error']['msg'] ?? null)) : null;
            $errorMsg = is_string($turnError) && $turnError !== ''
                ? $turnError
                : '这次 turn 在执行过程中失败了。';

            if ($context) {
                $this->taskStateService->markFromContext($context, 'failed');
                if (!empty($context['response_message_id'])) {
                    return $this->responseHelper->command(CommandFactory::feishuMessageUpdate([
                        'stream_id' => $context['stream_id'],
                        'target' => $context['response_message_id'],
                        'message_type' => 'interactive',
                        'content' => $this->errorHelper->buildErrorCard($errorMsg),
                    ]));
                }
            }
            return ['handled' => true];
        }

        if ($method === 'turn/completed') {
            $context = $this->contextHelper->resolveStreamContext($streamId, $threadId, $turnId, $channelHint);
            if (($context['status'] ?? '') === 'cancelled') {
                return ['handled' => true];
            }
            if ($context) {
                $this->taskStateService->markFromContext($context, 'completed');
            }
            return ['handled' => true];
        }

        if ($method === 'item/completed') {
            $context = $this->contextHelper->resolveStreamContext($streamId, $threadId, $turnId, $channelHint);
            if (($context['status'] ?? '') === 'cancelled') {
                return ['handled' => true];
            }
            if ($context) {
                $this->taskStateService->markFromContext($context, 'completed');
                if (!empty($context['response_message_id'])) {
                    return $this->responseHelper->command(CommandFactory::feishuStreamFinish([
                        'target' => $context['response_message_id'],
                        'stream_id' => $context['stream_id'],
                        'message_type' => 'interactive',
                        'content' => json_encode([
                            'elements' => [
                                ['tag' => 'markdown', 'content' => '{{content}}'],
                                ['tag' => 'note', 'elements' => [['tag' => 'plain_text', 'content' => '已完成']]],
                            ],
                        ]),
                        'metadata' => [
                            'status' => 'completed',
                            'mode' => 'finish',
                        ],
                    ]));
                }
            }
            return ['handled' => true];
        }

        return null;
    }
}
