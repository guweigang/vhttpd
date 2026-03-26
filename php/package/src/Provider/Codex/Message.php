<?php

declare(strict_types=1);

namespace VPhp\Provider\Codex;

/**
 * Base class for all Codex JSON-RPC messages.
 */
abstract class Message
{
    protected array $raw;

    public function __construct(array $raw)
    {
        $this->raw = $raw;
    }

    public function getRaw(): array
    {
        return $this->raw;
    }

    public function getMethod(): ?string
    {
        return $this->raw['method'] ?? null;
    }

    public function getId(): mixed
    {
        return $this->raw['id'] ?? null;
    }

    public function getParams(): array
    {
        return $this->raw['params'] ?? [];
    }

    public function isNotification(): bool
    {
        return isset($this->raw['method']) && !isset($this->raw['id']);
    }

    public function isRequest(): bool
    {
        return isset($this->raw['method']) && isset($this->raw['id']);
    }

    public function isResponse(): bool
    {
        return !isset($this->raw['method']) && isset($this->raw['id']);
    }
}
