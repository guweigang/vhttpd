<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

final class BotErrorHelper
{
    public function isThreadNotFound(?string $errorMessage): bool
    {
        if (!is_string($errorMessage) || $errorMessage === '') {
            return false;
        }

        return stripos($errorMessage, 'thread not found:') !== false;
    }

    public function isRateLimitError(?string $errorMessage): bool
    {
        if (!is_string($errorMessage) || $errorMessage === '') {
            return false;
        }

        $haystack = strtolower($errorMessage);
        return str_contains($haystack, 'usage limit')
            || str_contains($haystack, 'rate limit')
            || str_contains($haystack, 'rate_limit')
            || str_contains($haystack, 'quota')
            || str_contains($haystack, '额度已耗尽');
    }

    public function isSystemError(?string $errorMessage): bool
    {
        if (!is_string($errorMessage) || $errorMessage === '') {
            return false;
        }

        $haystack = strtolower($errorMessage);
        return str_contains($haystack, 'system error')
            || str_contains($haystack, '服务端异常')
            || str_contains($haystack, 'server error');
    }

    public function formatUserError(string $errorMessage): array
    {
        $message = trim($errorMessage);
        $note = '💡 提示：如遇会话上下文异常，请发送 /new 重置会话。';

        if ($message === '') {
            return [
                'title' => '❌ Codex 运行失败',
                'body' => '这次没有拿到明确错误信息，建议直接重试一次；如果还是失败，再发送 /new 重置会话。',
                'note' => $note,
            ];
        }

        if ($this->isThreadNotFound($message)) {
            return [
                'title' => '🔄 当前 Thread 已失效',
                'body' => "这个 thread 当前已无法继续恢复：\n\n> {$message}\n\n我建议先发送 /threads 查看可用线程，再用 /use 重新切换。",
                'note' => '💡 提示：这通常表示历史 thread 已不可恢复，重新选一个可用 thread 会更稳。',
            ];
        }

        if ($this->isRateLimitError($message)) {
            return [
                'title' => '⏳ Codex 当前触发额度或频率限制',
                'body' => "这次请求没有执行成功：\n\n> {$message}\n\n建议稍后重试，或检查当前账号额度与速率限制状态。",
                'note' => '💡 提示：如果刚才连续跑了很多任务，这类限制通常会自动恢复。',
            ];
        }

        if ($this->isSystemError($message)) {
            return [
                'title' => '⚠️ Codex 服务暂时异常',
                'body' => "这次任务被服务端异常打断了：\n\n> {$message}\n\n可以先直接重试；如果连续失败，再发送 /new 重置会话。",
                'note' => $note,
            ];
        }

        return [
            'title' => '❌ Codex 运行失败',
            'body' => "这次任务没有成功完成：\n\n> {$message}",
            'note' => $note,
        ];
    }

    public function buildErrorCard(string $errorMessage): string
    {
        $view = $this->formatUserError($errorMessage);

        return json_encode([
            'elements' => [
                ['tag' => 'markdown', 'content' => $view['title'] . "\n\n" . $view['body']],
                ['tag' => 'hr'],
                ['tag' => 'note', 'elements' => [['tag' => 'plain_text', 'content' => $view['note']]]],
            ],
        ], JSON_UNESCAPED_UNICODE);
    }
}
