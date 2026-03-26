<?php

declare(strict_types=1);

namespace VPhp\Provider\Codex;

class Response extends Message
{
    public function getResult(): mixed
    {
        return $this->raw['result'] ?? null;
    }

    public function getError(): ?array
    {
        return $this->raw['error'] ?? null;
    }

    public function hasError(): bool
    {
        return isset($this->raw['error']);
    }
}
