<?php

declare(strict_types=1);

namespace VPhp\Provider\Codex;

use VPhp\VHttpd\Upstream\WebSocket\Feishu\Command as FeishuCommand;

class StreamHandler
{
    /**
     * Handle an incoming Codex message and return a set of commands for vhttpd.
     *
     * @param Message $message
     * @param \PDO $db
     * @return array
     */
    public function handle(Message $message, \PDO $db): array
    {
        if ($message instanceof Response) {
            return $this->handleResponse($message, $db);
        }

        if ($message instanceof Notification) {
            return $this->handleNotification($message, $db);
        }

        if ($message instanceof ServerRequest) {
            return $this->handleServerRequest($message, $db);
        }

        return [];
    }

    protected function handleResponse(Response $resp, \PDO $db): array
    {
        $id = $resp->getId();
        $resultData = $resp->getResult();
        $hasError = $resp->hasError();
        $method = $resp->getMethod();
        
        // We need trace_id to know which task this response belongs to.
        // vhttpd includes trace_id in the event payload.
        // Let's assume the caller passes metadata.
        $metadata = $resp->getRaw()['metadata'] ?? [];
        $streamId = $metadata['stream_id'] ?? null;
        
        if (!$streamId) return [];
        $taskId = str_replace('codex:', '', $streamId);

        if ($hasError) {
             $errorMsg = $this->extractErrorMessage($resultData);
             $this->updateTaskStatus($db, $taskId, 'failed', $errorMsg, true);
             return [];
        }

        if ($method === 'thread/start' || $method === 'turn/start') {
            $threadId = $resultData['threadId'] ?? ($resultData['thread']['id'] ?? null);
            if ($threadId) {
                $db->prepare("UPDATE tasks SET thread_id = ?, status = 'streaming' WHERE task_id = ?")
                   ->execute([$threadId, $taskId]);
            }
        }

        return [];
    }

    private function updateTaskStatus(\PDO $db, string $id, string $status, ?string $error = null, bool $isTaskId = false): void
    {
        $field = $isTaskId ? "task_id" : "thread_id";
        $sql = "UPDATE tasks SET status = ?";
        $params = [$status];
        if ($error !== null) {
            $sql .= ", error_message = ?";
            $params[] = $error;
        }
        $sql .= " WHERE $field = ? AND status IN ('running', 'streaming', 'pending')";
        $stmt = $db->prepare($sql);
        $stmt->execute($params);
    }

    public function handleNotification(Notification $notif, \PDO $db): array
    {
        $method = $notif->getMethod();
        $params = $notif->getParams();
        
        $threadId = $params['threadId'] ?? ($params['thread_id'] ?? null);
        if (!$threadId && isset($params['thread']['id'])) {
            $threadId = $params['thread']['id'];
        }

        if (!$threadId) {
            return [];
        }

        $context = $this->resolveContext($db, $threadId);
        if (!$context) return [];

        $messageId = $context['response_message_id'];
        $streamId = $context['stream_id'];

        switch ($method) {
            case 'item/agentMessage/delta':
                $delta = $params['delta'] ?? '';
                if ($delta) {
                    return [
                        [
                            'type' => 'feishu.message.patch',
                            'target' => $messageId,
                            'stream_id' => $streamId,
                            'text' => $delta,
                            'metadata' => ['mode' => 'append']
                        ]
                    ];
                }
                break;

            case 'turn/completed':
            case 'item/completed':
                $this->updateTaskStatus($db, $threadId, 'completed');
                return [
                    [
                        'type' => 'feishu.message.flush',
                        'target' => $messageId,
                        'stream_id' => $streamId,
                        'message_type' => 'interactive',
                        'content' => json_encode([
                            'header' => ['title' => ['tag' => 'plain_text', 'content' => '✅ Codex 任务完成'], 'template' => 'green'],
                            'elements' => [
                                ['tag' => 'hr'],
                                ['tag' => 'note', 'content' => [['tag' => 'plain_text', 'content' => '🌟 以上为流式输出的完整内容']]]
                            ]
                        ]),
                        'metadata' => [
                            'status' => 'completed',
                            'mode' => 'finish'
                        ]
                    ]
                ];

            case 'error':
            case 'systemError':
            case 'thread/status/changed':
                $errorMsg = $this->extractErrorMessage($params);
                if ($errorMsg || ($params['status']['type'] ?? '') === 'systemError') {
                    $errorMsg = $errorMsg ?: "系统未知错误";
                    $this->updateTaskStatus($db, $threadId, 'failed', $errorMsg);
                    return [
                        [
                            'type' => 'feishu.message.update',
                            'target' => $messageId,
                            'stream_id' => $streamId,
                            'message_type' => 'interactive',
                            'content' => json_encode([
                                'elements' => [[
                                    'tag' => 'markdown',
                                    'content' => "❌ **Codex 思考中断**: $errorMsg"
                                ]]
                            ])
                        ]
                    ];
                }
                break;
        }

        return [];
    }

    protected function handleServerRequest(ServerRequest $request, \PDO $db): array
    {
        $method = $request->getMethod();
        $params = $request->getParams();
        
        if ($method === 'turn/approvalRequest') {
             // Handle approval
        }
        return [];
    }

    private function resolveContext(\PDO $db, string $threadId): ?array
    {
        $stmt = $db->prepare("SELECT s.response_message_id, t.task_id, t.stream_id 
                               FROM tasks t 
                               JOIN streams s ON t.task_id = s.task_id 
                               WHERE t.thread_id = ? 
                               ORDER BY t.created_at DESC LIMIT 1");
        $stmt->execute([$threadId]);
        return $stmt->fetch(\PDO::FETCH_ASSOC) ?: null;
    }


    private function extractErrorMessage(array $params): ?string
    {
        // 1. Check for rate limit exhausted
        if (isset($params['credits']) && $params['credits']['hasCredits'] === false) {
            return "您的 Codex 账号额度已耗尽 (Usage Limit)";
        }

        // 2. recursive scan
        $queue = [$params];
        while (!empty($queue)) {
            $curr = array_shift($queue);
            if (!is_array($curr)) continue;
            
            if (isset($curr['message']) && is_string($curr['message'])) return $curr['message'];
            if (isset($curr['error']) && is_string($curr['error'])) return $curr['error'];
            if (isset($curr['error']['message']) && is_string($curr['error']['message'])) return $curr['error']['message'];
            if (isset($curr['detail']) && is_string($curr['detail'])) return $curr['detail'];
            
            foreach ($curr as $v) {
                if (is_array($v)) $queue[] = $v;
            }
        }
        
        return null;
    }
}
