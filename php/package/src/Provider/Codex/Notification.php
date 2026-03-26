<?php

declare(strict_types=1);

namespace VPhp\Provider\Codex;

class Notification extends Message
{
    public function getEventName(): ?string
    {
        return $this->getMethod();
    }
}
