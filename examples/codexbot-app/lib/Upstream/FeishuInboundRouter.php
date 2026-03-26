<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\ProjectChannelRepository;

final class FeishuInboundRouter
{
    public function __construct(
        private ProjectChannelRepository $channelRepo,
        private FeishuCommandRouter $commandRouter,
        private FeishuMessageParser $messageParser,
    ) {
    }

    public function dispatch(array $payload): ?array
    {
        $eventType = (string) ($payload['header']['event_type'] ?? '');
        $tenantKey = (string) ($payload['header']['tenant_key'] ?? '');
        $sender = $payload['event']['sender']['sender_id']['open_id'] ?? '';
        $chatId = $payload['event']['message']['chat_id'] ?? '';
        $message = is_array($payload['event']['message'] ?? null) ? $payload['event']['message'] : [];
        $messageType = (string) ($message['message_type'] ?? '');
        $text = $this->messageParser->extractPrompt($message);

        file_put_contents(
            'php://stderr',
            "[PHP] Feishu inbound raw: event_type={$eventType}, tenant_key={$tenantKey}, " .
            'message=' . json_encode($message, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n"
        );

        file_put_contents(
            'php://stderr',
            "[PHP] Feishu inbound normalized: type={$messageType}, text_len=" . strlen($text) .
            ", preview=" . substr($text, 0, 160) . "\n"
        );

        $project = $this->channelRepo->findProjectByTarget('feishu', $chatId);
        $project = $this->commandRouter->refreshProjectContext($project);

        if ($text === '') {
            return ['commands' => []];
        }

        return $this->commandRouter->dispatch($text, $project, $chatId, $sender, $payload);
    }
}
