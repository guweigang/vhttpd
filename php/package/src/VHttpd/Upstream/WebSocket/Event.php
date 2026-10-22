<?php
declare(strict_types=1);
namespace VHttpd\Upstream\WebSocket;

final class Event
{
    private function __construct(private readonly array $request) {}

    public static function fromDispatchRequest(array $request): self { return new self($request); }
    public function request(): array { return $this->request; }
    public function provider(): string { return (string) ($this->request['provider'] ?? ''); }
    public function eventType(): string { return (string) ($this->request['event_type'] ?? ''); }
    public function matches(string $provider, string $eventType): bool
    {
        return $this->provider() === $provider && $this->eventType() === $eventType;
    }
    public function payloadArray(): array
    {
        $payload = $this->request['payload'] ?? [];
        if (is_string($payload)) $payload = json_decode($payload, true);
        return is_array($payload) ? $payload : [];
    }
}
