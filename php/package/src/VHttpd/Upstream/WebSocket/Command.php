<?php
declare(strict_types=1);
namespace VHttpd\Upstream\WebSocket;

final class Command implements \JsonSerializable
{
    public function __construct(private readonly array $fields)
    {
        if (!is_string($fields['type'] ?? null) || trim($fields['type']) === '') {
            throw new \InvalidArgumentException('Command type is required');
        }
    }
    public function toArray(): array { return $this->fields; }
    public function jsonSerialize(): array { return $this->fields; }
}
