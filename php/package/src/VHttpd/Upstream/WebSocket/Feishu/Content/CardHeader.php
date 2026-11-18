<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Content;

use VHttpd\Upstream\WebSocket\Feishu\Record;

final class CardHeader extends Record
{
    public static function create(PlainText $title): self
    {
        return new self(['title' => $title->toArray()]);
    }
}
