<?php

namespace CodexBot\Service;

use VHttpd\Feishu\CreationLease;

use VHttpd\Upstream\WebSocket\CommandFactory as PackageCommandFactory;

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
        if (trim((string) ($payload['stream_id'] ?? '')) === '' || empty($payload['metadata']['stream_generation']) || empty($payload['metadata']['creation_token'])) {
            throw new \LogicException('Feishu send requires captured creation context');
        }
        return ['type' => 'provider.message.send', 'provider' => 'feishu'] + $payload;
    }

    public static function feishuMessageUpdate(array $payload, array $context = []): array {
        if ($context !== [] && ($context['stream_id'] ?? '') !== ($payload['stream_id'] ?? '')) {
            throw new \InvalidArgumentException('Update context does not match stream');
        }
        $payload['instance'] = $context['stream_instance'] ?? $payload['instance'] ?? 'main';
        $payload['metadata'] = array_replace($payload['metadata'] ?? [], [
            'stream_generation' => (string) ($context['stream_generation'] ?? $payload['metadata']['stream_generation'] ?? ''),
        ]);
        // Serialize the captured wire command without consulting mutable registries.
        return ['type' => 'provider.message.update', 'provider' => 'feishu'] + $payload;
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

    public static function feishuSendText(string $chatId, string $text, string $streamId = '', int $jsonFlags = 0, ?CreationLease $creation = null): array {
        $payload = [
            'target_type' => 'chat_id',
            'target' => $chatId,
            'message_type' => 'text',
            'content' => json_encode(['text' => $text], $jsonFlags),
        ];
        if ($streamId !== '') {
            $payload['stream_id'] = $streamId;
        }
        if ($streamId !== '') {
            if ($creation === null) throw new \LogicException('Stream creation requires captured credentials');
            return $creation->command(['type' => 'provider.message.send', 'provider' => 'feishu'] + $payload);
        }
        throw new \LogicException('Reply creation requires an explicit trusted context');
    }

    public static function feishuSendMarkdown(string $chatId, string $markdown, string $streamId = '', int $jsonFlags = 0, ?CreationLease $creation = null): array {
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
        if ($streamId !== '') {
            if ($creation === null) throw new \LogicException('Stream creation requires captured credentials');
            return $creation->command(['type' => 'provider.message.send', 'provider' => 'feishu'] + $payload);
        }
        throw new \LogicException('Reply creation requires an explicit trusted context');
    }

    public static function feishuUpdateMarkdown(array|string $stream, string $markdown, int $jsonFlags = 0): array {
        $context = is_array($stream) ? $stream : [];
        return self::feishuMessageUpdate([
            'stream_id' => is_array($stream) ? (string) ($stream['stream_id'] ?? '') : $stream,
            'message_type' => 'interactive',
            'content' => json_encode([
                'elements' => [
                    ['tag' => 'markdown', 'content' => $markdown],
                ],
            ], $jsonFlags),
        ], $context);
    }

    public static function codexRpcSend(string $method, array|string $params, string $streamId): array {
        return self::codexRpcCall($method, $params, $streamId);
    }

    public static function codexTurnStart(string $streamId, string $taskType, string $prompt, array $metadata = []): array {
        return self::codexSessionTurnStart($streamId, $taskType, $prompt, $metadata);
    }

    public static function feishuSessionClear(string $streamId, string $generation, string $instance = 'main'): array {
        return ['type' => 'session.clear', 'provider' => 'feishu', 'instance' => $instance, 'stream_id' => $streamId, 'metadata' => ['stream_generation' => $generation]];
    }

    public static function adminRestartAllWorkers(): array {
        return [
            'type' => 'admin.worker.restart_all',
        ];
    }
}
