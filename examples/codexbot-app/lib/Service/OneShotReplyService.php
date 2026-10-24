<?php
declare(strict_types=1);
namespace CodexBot\Service;

use VHttpd\Feishu\CreationClient;

// Trusted reply construction, separate from pure command serialization.
final class OneShotReplyService
{
    public function __construct(private ?CreationClient $client = null, private string $instance = 'main') {}

    public function forInstance(string $instance): self
    {
        return new self($this->client, $instance === '' ? 'main' : $instance);
    }

    public function text(string $target, string $text, int $flags = 0): array
    {
        return $this->command(['target_type'=>'chat_id', 'target'=>$target, 'message_type'=>'text', 'content'=>json_encode(['text'=>$text], $flags | JSON_THROW_ON_ERROR)]);
    }

    public function markdown(string $target, string $text, int $flags = 0): array
    {
        return $this->command(['target_type'=>'chat_id', 'target'=>$target, 'message_type'=>'interactive', 'content'=>json_encode(['elements'=>[['tag'=>'markdown', 'content'=>$text]]], $flags | JSON_THROW_ON_ERROR)]);
    }

    public function command(array $payload): array
    {
        // A captured/replayed command is never input to a fresh issuance.
        foreach (['stream_id','type','provider'] as $key) {
            if (array_key_exists($key, $payload)) throw new \InvalidArgumentException('Reply payload already has command ownership');
        }
        foreach (['stream_id','stream_generation','creation_generation','creation_token','publication_id'] as $key) {
            if (array_key_exists($key, $payload['metadata'] ?? [])) throw new \InvalidArgumentException('Reply payload already has creation context');
        }
        // Reject unserializable payloads before acquiring any authority.
        json_encode($payload, JSON_THROW_ON_ERROR);
        $scope = 'feishu:reply:' . bin2hex(random_bytes(16));
        $client = $this->client ??= CreationClient::fromEnvironment();
        $lease = $client->issue($scope, (string) ($payload['instance'] ?? $this->instance));
        try {
            $command = $lease->command(['type'=>'provider.message.send','provider'=>'feishu','stream_id'=>$scope] + $payload);
            $command['metadata']['one_shot_reply'] = '1';
            return $command;
        } catch (\Throwable $error) {
            try { $client->revoke($lease); } catch (\Throwable) { /* Expiry bounds unreachable grants. */ }
            throw $error;
        }
    }

    public static function completeCommands(array $commands): array
    {
        $result = [];
        foreach ($commands as $command) {
            $once = ($command['metadata']['one_shot_reply'] ?? '') === '1';
            if ($once) {
                if (($command['type'] ?? '') !== 'provider.message.send' || ($command['provider'] ?? '') !== 'feishu'
                    || empty($command['stream_id']) || empty($command['metadata']['stream_generation']) || empty($command['metadata']['creation_token'])) {
                    throw new \InvalidArgumentException('Reply cleanup requires captured send ownership');
                }
                unset($command['metadata']['one_shot_reply']);
            }
            $result[] = $command;
            if ($once) $result[] = CommandFactory::feishuSessionClear($command['stream_id'], $command['metadata']['stream_generation'], $command['instance'] ?? 'main');
        }
        return $result;
    }
}
