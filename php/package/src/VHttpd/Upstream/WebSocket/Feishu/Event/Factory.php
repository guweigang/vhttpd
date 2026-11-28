<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Event;

use VHttpd\Upstream\WebSocket\Feishu\Event;

final class Factory
{
    public static function fromEvent(Event $event): ?CardActionEvent
    {
        return $event instanceof CardActionEvent ? $event : null;
    }
}
