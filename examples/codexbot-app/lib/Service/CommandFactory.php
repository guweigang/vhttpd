<?php

namespace CodexBot\Service;

use VPhp\VHttpd\Upstream\WebSocket\CommandFactory as PackageCommandFactory;

final class CommandFactory {
    public static function providerMessageSend(string $provider, array $payload): array {
        return PackageCommandFactory::providerMessageSend($provider, $payload)->toArray();
    }

    public static function providerMessageUpdate(string $provider, array $payload): array {
        return PackageCommandFactory::providerMessageUpdate($provider, $payload)->toArray();
    }

    public static function streamAppend(string $provider, array $payload): array {
        return PackageCommandFactory::streamAppend($provider, $payload)->toArray();
    }

    public static function streamFinish(string $provider, array $payload): array {
        return PackageCommandFactory::streamFinish($provider, $payload)->toArray();
    }

    public static function providerRpcCall(string $provider, string $method, array|string $params, string $streamId): array {
        return PackageCommandFactory::providerRpcCall($provider, $method, $params, $streamId)->toArray();
    }

    public static function sessionTurnStart(string $provider, string $streamId, string $taskType, string $prompt, array $metadata = []): array {
        return PackageCommandFactory::sessionTurnStart($provider, $streamId, $taskType, $prompt, $metadata)->toArray();
    }

    public static function feishuMessageSend(array $payload): array {
        return self::providerMessageSend('feishu', $payload);
    }

    public static function feishuMessageUpdate(array $payload): array {
        return self::providerMessageUpdate('feishu', $payload);
    }

    public static function feishuStreamAppend(array $payload): array {
        return self::streamAppend('feishu', $payload);
    }

    public static function feishuStreamFinish(array $payload): array {
        return self::streamFinish('feishu', $payload);
    }

    public static function codexRpcCall(string $method, array|string $params, string $streamId): array {
        return self::providerRpcCall('codex', $method, $params, $streamId);
    }

    public static function codexSessionTurnStart(string $streamId, string $taskType, string $prompt, array $metadata = []): array {
        return self::sessionTurnStart('codex', $streamId, $taskType, $prompt, $metadata);
    }

    public static function feishuSend(array $payload): array {
        return self::feishuMessageSend($payload);
    }

    public static function feishuUpdate(array $payload): array {
        return self::feishuMessageUpdate($payload);
    }

    public static function feishuPatch(array $payload): array {
        return self::feishuStreamAppend($payload);
    }

    public static function feishuFlush(array $payload): array {
        return self::feishuStreamFinish($payload);
    }

    public static function feishuSendText(string $chatId, string $text, string $streamId = '', int $jsonFlags = 0): array {
        $payload = [
            'target_type' => 'chat_id',
            'target' => $chatId,
            'message_type' => 'text',
            'content' => json_encode(['text' => $text], $jsonFlags),
        ];
        if ($streamId !== '') {
            $payload['stream_id'] = $streamId;
        }
        return self::feishuSend($payload);
    }

    public static function feishuSendMarkdown(string $chatId, string $markdown, string $streamId = '', int $jsonFlags = 0): array {
        $payload = [
            'target_type' => 'chat_id',
            'target' => $chatId,
            'message_type' => 'interactive',
            'content' => json_encode([
                'elements' => [
                    ['tag' => 'markdown', 'content' => $markdown],
                ],
            ], $jsonFlags),
        ];
        if ($streamId !== '') {
            $payload['stream_id'] = $streamId;
        }
        return self::feishuSend($payload);
    }

    public static function feishuUpdateMarkdown(string $streamId, string $markdown, int $jsonFlags = 0): array {
        return self::feishuUpdate([
            'stream_id' => $streamId,
            'message_type' => 'interactive',
            'content' => json_encode([
                'elements' => [
                    ['tag' => 'markdown', 'content' => $markdown],
                ],
            ], $jsonFlags),
        ]);
    }

    public static function codexRpcSend(string $method, array|string $params, string $streamId): array {
        return self::codexRpcCall($method, $params, $streamId);
    }

    public static function codexTurnStart(string $streamId, string $taskType, string $prompt, array $metadata = []): array {
        return self::codexSessionTurnStart($streamId, $taskType, $prompt, $metadata);
    }

    public static function adminRestartAllWorkers(): array {
        return [
            'type' => 'admin.worker.restart_all',
        ];
    }
}
