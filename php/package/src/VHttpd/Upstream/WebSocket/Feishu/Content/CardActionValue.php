<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Content;

use VHttpd\Upstream\WebSocket\Feishu\Record;

final class CardActionValue extends Record
{
    public static function action(string $name, array $fields = []): self
    {
        return new self(['action' => $name] + $fields);
    }
}
