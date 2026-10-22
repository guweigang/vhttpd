<?php
declare(strict_types=1);
namespace VHttpd\Feishu;

final class CreationLease
{
    public function __construct(
        public readonly array $request,
        public readonly string $generation,
        public readonly string $token,
    ) {
        if ($generation === '' || !preg_match('/^[a-f0-9]{64}$/D', $token)
            || !is_string($request['stream_id'] ?? null) || trim($request['stream_id']) === ''
            || !is_string($request['instance'] ?? null)
            || !in_array($request['kind'] ?? '', ['send', 'bind'], true)
            || !is_string($request['message_id'] ?? null)
            || (($request['kind'] === 'bind') !== ($request['message_id'] !== ''))
            || !is_string($request['epoch'] ?? null) || !preg_match('/^[a-f0-9]{64}$/D', $request['epoch'])
            || !is_string($request['request_id'] ?? null) || !preg_match('/^[a-f0-9]{64}$/D', $request['request_id'])
            || !is_int($request['issued_at'] ?? null)) {
            throw new \UnexpectedValueException('Invalid Feishu creation credentials');
        }
    }

    public function command(array $command): array
    {
        $bind = ($this->request['kind'] ?? '') === 'bind';
        if (($command['provider'] ?? '') !== 'feishu'
            || ($command['stream_id'] ?? '') !== $this->request['stream_id']
            || ($command['type'] ?? '') !== ($bind ? 'session.bind' : 'provider.message.send')
            || (isset($command['instance']) && $command['instance'] !== $this->request['instance'])
            || ($bind && (($command['target_type'] ?? '') !== 'message_id' || ($command['target'] ?? '') !== $this->request['message_id']))
            || ($bind && ($command['metadata']['stream_generation'] ?? '') !== '')) {
            throw new \InvalidArgumentException('Creation credentials do not match command ownership');
        }
        $command['instance'] = $this->request['instance'];
        $command['metadata']['publication_id'] = $this->request['request_id'];
        $command['metadata'] = array_replace($command['metadata'] ?? [], $bind
            ? ['creation_generation' => $this->generation, 'creation_token' => $this->token, 'stream_generation' => '']
            : ['stream_generation' => $this->generation, 'creation_token' => $this->token]);
        return $command;
    }
}
