<?php
declare(strict_types=1);
namespace VHttpd\Upstream\WebSocket;

final class CommandFactory
{
    // Serializers only: credentials are captured by the caller, never acquired here.
    private static function providerCommand(string $type, string $provider, array $payload): Command
    {
        return new Command(['type' => $type, 'provider' => $provider] + $payload);
    }
    public static function providerMessageSend(string $provider, array $payload): Command
    {
        return self::providerCommand('provider.message.send', $provider, $payload);
    }
    public static function providerMessageUpdate(string $provider, array $payload): Command
    {
        return self::providerCommand('provider.message.update', $provider, $payload);
    }
    public static function streamAppend(string $provider, array $payload): Command
    {
        return self::providerCommand('stream.append', $provider, $payload);
    }
    public static function streamFinish(string $provider, array $payload): Command
    {
        return self::providerCommand('stream.finish', $provider, $payload);
    }
    public static function providerRpcCall(string $provider, string $method, array|string $params, string $streamId): Command
    {
        return self::providerCommand('provider.rpc.call', $provider, ['method' => $method,
            'params' => is_string($params) ? $params : json_encode($params, JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE),
            'stream_id' => $streamId]);
    }
    public static function sessionTurnStart(string $provider, string $streamId, string $taskType, string $prompt, array $metadata = []): Command
    {
        return self::providerCommand('session.turn.start', $provider, ['stream_id' => $streamId,
            'task_type' => $taskType, 'prompt' => $prompt, 'metadata' => $metadata]);
    }
}
