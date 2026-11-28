<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu;

abstract class Record implements \JsonSerializable
{
    protected function __construct(protected readonly array $fields) {}

    public function toArray(): array { return $this->fields; }
    public function jsonSerialize(): array { return $this->toArray(); }
    public function toDebugArray(): array { return $this->toArray(); }

    protected function textField(string $name): string { return (string) ($this->fields[$name] ?? ''); }

    protected static function requireField(array $fields, string $name): void
    {
        if (!is_string($fields[$name] ?? null) || trim($fields[$name]) === '') {
            throw new \InvalidArgumentException($name . ' is required');
        }
    }
}
