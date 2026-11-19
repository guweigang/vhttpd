<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Content;

use VHttpd\Upstream\WebSocket\Feishu\Record;

final class CardButton extends Record
{
    public static function primary(PlainText $text, CardActionValue $value): self
    {
        return new self([
            'tag' => 'button', 'type' => 'primary',
            'text' => $text->toArray(), 'value' => $value->toArray(),
        ]);
    }
}
