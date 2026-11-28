<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Content;

use VHttpd\Upstream\WebSocket\Feishu\Record;

final class CardActionBlock extends Record
{
    public static function create(CardButton ...$buttons): self
    {
        return new self([
            'tag' => 'action',
            'actions' => array_map(static fn (CardButton $button): array => $button->toArray(), $buttons),
        ]);
    }
}
