<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\TaskRepository;

final class ThreadViewHelper
{
    public function compactText(string $text, int $limit = 48): string
    {
        $text = trim(preg_replace('/\s+/u', ' ', $text) ?? '');
        if ($text === '') {
            return '';
        }
        if (function_exists('mb_strlen') && function_exists('mb_substr')) {
            if (mb_strlen($text, 'UTF-8') > $limit) {
                return mb_substr($text, 0, $limit - 1, 'UTF-8') . '…';
            }
            return $text;
        }
        if (strlen($text) > $limit) {
            return substr($text, 0, $limit - 3) . '...';
        }
        return $text;
    }

    public function extractTextPreview(mixed $value): string
    {
        if (is_string($value)) {
            return $this->compactText($value);
        }
        if (!is_array($value)) {
            return '';
        }

        foreach (['title', 'summary', 'text', 'content', 'prompt', 'name'] as $key) {
            if (isset($value[$key]) && is_string($value[$key]) && trim($value[$key]) !== '') {
                return $this->compactText($value[$key]);
            }
        }

        foreach ($value as $item) {
            $preview = $this->extractTextPreview($item);
            if ($preview !== '') {
                return $preview;
            }
        }

        return '';
    }

    public function threadLabel(array $thread): string
    {
        foreach (['title', 'summary', 'name', 'topic'] as $key) {
            if (isset($thread[$key]) && is_string($thread[$key]) && trim($thread[$key]) !== '') {
                return $this->compactText($thread[$key]);
            }
        }

        $turns = $thread['turns'] ?? [];
        if (is_array($turns) && $turns !== []) {
            for ($i = count($turns) - 1; $i >= 0; $i--) {
                if (!is_array($turns[$i])) {
                    continue;
                }
                $preview = $this->extractTextPreview($turns[$i]);
                if ($preview !== '') {
                    return $preview;
                }
            }
        }

        $threadId = (string) ($thread['id'] ?? '');
        if ($threadId !== '') {
            return 'thread ' . substr($threadId, 0, 8);
        }

        return 'untitled';
    }

    public function missingThreadHint(): string
    {
        return "⚠️ **当前还没有绑定 Codex Thread**\n\n先发送 `/threads` 查看历史线程，再用 `/use <thread_id>` 选中一个。";
    }

    public function renderThreadRead(array $thread): string
    {
        $threadId = (string) ($thread['id'] ?? 'unknown');
        $md = "🧵 **当前 Thread 详情**\n\n";
        $md .= "• **Thread**: `{$threadId}`\n";
        $name = trim((string) ($thread['name'] ?? ''));
        if ($name !== '') {
            $md .= "• **名称**: " . $this->compactText($name, 120) . "\n";
        }
        $preview = trim((string) ($thread['preview'] ?? ''));
        if ($preview !== '') {
            $md .= "• **预览**: " . $this->compactText($preview, 120) . "\n";
        }
        if (!empty($thread['createdAt'])) {
            $md .= "• **创建时间**: `" . (string) $thread['createdAt'] . "`\n";
        }
        if (!empty($thread['updatedAt'])) {
            $md .= "• **更新时间**: `" . (string) $thread['updatedAt'] . "`\n";
        }
        if (!empty($thread['model'])) {
            $md .= "• **模型**: `" . (string) $thread['model'] . "`\n";
        }
        $md .= "\n如需更细的上下文，我们下一步再专门做“按 turn 分页读取”的命令。";
        return trim($md);
    }

    public function latestThreadTask(TaskRepository $taskRepo, string $threadId): ?array
    {
        if ($threadId === '') {
            return null;
        }
        try {
            return $taskRepo->findLatestByThreadId($threadId);
        } catch (\Throwable $e) {
            file_put_contents('php://stderr', "[PHP] latest_thread_task failed: " . $e->getMessage() . "\n");
            return null;
        }
    }

    public function recentThreadTasks(TaskRepository $taskRepo, string $threadId, int $limit = 3): array
    {
        if ($threadId === '') {
            return [];
        }
        try {
            return $taskRepo->findRecentByThreadId($threadId, $limit);
        } catch (\Throwable $e) {
            file_put_contents('php://stderr', "[PHP] recent_thread_tasks failed: " . $e->getMessage() . "\n");
            return [];
        }
    }

    public function renderThreadLatest(array $task, string $threadId): string
    {
        $md = "🕘 **当前 Thread 最近一次本地任务 / Turn 记录**\n\n";
        $md .= "• **Thread**: `{$threadId}`\n";
        $taskId = (string) ($task['task_id'] ?? 'unknown');
        $taskType = (string) ($task['task_type'] ?? 'ask');
        $typeLabel = $this->threadTaskTypeLabel($taskType);
        $summary = $this->threadTaskSummary($task);
        $md .= "\n> " . $summary . "\n\n";
        $md .= "• **Task**: `{$taskId}`\n";
        $md .= "• **类型**: `{$typeLabel}`\n";
        $md .= "• **状态**: `" . (string) ($task['status'] ?? 'unknown') . "`\n";

        $prompt = trim((string) ($task['prompt'] ?? ''));
        if ($prompt !== '' && $taskType !== 'use_thread') {
            $label = $this->threadTaskPromptLabel($taskType, true);
            $md .= "• **{$label}**: " . $this->compactText($prompt, 120) . "\n";
        }
        if (!empty($task['codex_turn_id'])) {
            $md .= "• **Turn**: `" . (string) $task['codex_turn_id'] . "`\n";
        }
        if (!empty($task['stream_id'])) {
            $md .= "• **Stream**: `" . (string) $task['stream_id'] . "`\n";
        }
        if (!empty($task['response_message_id'])) {
            $md .= "• **回复消息**: `" . (string) $task['response_message_id'] . "`\n";
        }
        if (!empty($task['updated_at'])) {
            $md .= "• **更新时间**: `" . (string) $task['updated_at'] . "`\n";
        }
        if (!empty($task['error_message'])) {
            $md .= "\n**最近错误**\n> " . $this->compactText((string) $task['error_message'], 180);
        }
        return trim($md);
    }

    public function renderThreadRecent(array $tasks, string $threadId): string
    {
        $md = "🕘 **当前 Thread 最近几次本地任务 / Turn 记录**\n\n";
        $md .= "• **Thread**: `{$threadId}`\n\n";
        foreach ($tasks as $idx => $task) {
            $number = $idx + 1;
            $taskId = (string) ($task['task_id'] ?? 'unknown');
            $taskType = (string) ($task['task_type'] ?? 'ask');
            $typeLabel = $this->threadTaskTypeLabel($taskType);
            $status = (string) ($task['status'] ?? 'unknown');
            $summary = $this->threadTaskSummary($task);
            $md .= "**{$number}. {$typeLabel}**\n";
            $md .= "> " . $summary . "\n";
            $md .= "• Task: `{$taskId}`\n";
            if (!empty($task['codex_turn_id'])) {
                $md .= "• Turn: `" . (string) $task['codex_turn_id'] . "`\n";
            }
            $md .= "• 状态: `{$status}`\n";
            $prompt = trim((string) ($task['prompt'] ?? ''));
            if ($prompt !== '' && $taskType !== 'use_thread') {
                $label = $this->threadTaskPromptLabel($taskType, false);
                $md .= "• {$label}: " . $this->compactText($prompt, 90) . "\n";
            }
            if (!empty($task['response_message_id'])) {
                $md .= "• 回复消息: `" . (string) $task['response_message_id'] . "`\n";
            }
            if (!empty($task['updated_at'])) {
                $md .= "• 时间: `" . (string) $task['updated_at'] . "`\n";
            }
            if (!empty($task['error_message'])) {
                $md .= "• 错误: " . $this->compactText((string) $task['error_message'], 90) . "\n";
            }
            $md .= "\n";
        }
        return trim($md);
    }

    private function threadTaskTypeLabel(string $taskType): string
    {
        return match ($taskType) {
            'ask' => '用户任务',
            'thread_read' => '读取 Thread',
            'use_thread' => '切换 Thread',
            'use_thread_latest' => '切换最新 Thread',
            default => $taskType,
        };
    }

    private function threadTaskPromptLabel(string $taskType, bool $isLatest = false): string
    {
        return match ($taskType) {
            'thread_read' => '读取动作',
            'use_thread' => '切换目标',
            'use_thread_latest' => '切换动作',
            default => $isLatest ? '最近输入' : '输入',
        };
    }

    private function threadTaskSummary(array $task): string
    {
        $taskType = (string) ($task['task_type'] ?? 'ask');
        $prompt = trim((string) ($task['prompt'] ?? ''));

        if ($prompt === '') {
            return match ($taskType) {
                'thread_read' => '读取当前 thread 详情',
                'use_thread' => '切换到指定 thread',
                'use_thread_latest' => '切换到最近一个可用 thread',
                default => '无额外输入',
            };
        }

        if ($taskType === 'thread_read') {
            return $this->compactText($prompt, 72);
        }

        if ($taskType === 'use_thread') {
            return '切换到 `' . $this->compactText($prompt, 32) . '`';
        }

        if ($taskType === 'use_thread_latest') {
            return '切换到最近一个可用 thread';
        }

        return $this->compactText($prompt, 72);
    }
}
