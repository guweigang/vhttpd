<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Content;

use VHttpd\Upstream\WebSocket\Feishu\Record;

final class CardMarkdown extends Record
{
    public static function create(string $text): self
    {
        return new self(['tag' => 'markdown', 'content' => $text]);
    }
}
