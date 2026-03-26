<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

final class FeishuMessageParser
{
    public function __construct(
        private BotJsonHelper $jsonHelper,
    ) {
    }

    public function extractPrompt(array $message): string
    {
        $messageType = trim((string) ($message['message_type'] ?? ''));
        $contentRaw = (string) ($message['content'] ?? '');
        $content = $this->jsonHelper->decode($contentRaw, 'feishu.message.content');

        if ($messageType === 'text') {
            return trim((string) ($content['text'] ?? ''));
        }

        if ($messageType === 'post') {
            if (isset($content['post']) && is_array($content['post'])) {
                return $this->extractPostPrompt($content['post']);
            }
            return $this->extractPostPrompt($content);
        }

        if (isset($content['post']) && is_array($content['post'])) {
            return $this->extractPostPrompt($content['post']);
        }

        if (isset($content['text']) && is_string($content['text'])) {
            return trim($content['text']);
        }

        return '';
    }

    private function extractPostPrompt(array $content): string
    {
        $localePost = $this->resolvePostBody($content);

        $parts = [];
        $title = trim((string) ($localePost['title'] ?? ''));
        if ($title !== '') {
            $parts[] = $title;
        }

        $lines = is_array($localePost['content'] ?? null) ? $localePost['content'] : [];
        foreach ($lines as $line) {
            if (!is_array($line)) {
                continue;
            }
            $segments = [];
            foreach ($line as $segment) {
                $text = $this->flattenPostSegment($segment);
                if (trim($text) !== '') {
                    $segments[] = $text;
                }
            }
            if ($segments !== []) {
                $parts[] = implode('', $segments);
            }
        }

        return trim(implode("\n", $parts));
    }

    private function resolvePostBody(array $content): array
    {
        if (isset($content['content']) && is_array($content['content'])) {
            return $content;
        }

        foreach ($content as $postBody) {
            if (!is_array($postBody)) {
                continue;
            }
            if (isset($postBody['content']) && is_array($postBody['content'])) {
                return $postBody;
            }
        }

        return [];
    }

    private function flattenPostSegment(mixed $segment): string
    {
        if (!is_array($segment)) {
            return '';
        }

        $tag = (string) ($segment['tag'] ?? '');
        if ($tag === 'text') {
            return (string) ($segment['text'] ?? '');
        }

        foreach (['text', 'content', 'name', 'user_name'] as $key) {
            if (isset($segment[$key]) && is_string($segment[$key]) && trim($segment[$key]) !== '') {
                return (string) $segment[$key];
            }
        }

        return '';
    }
}
