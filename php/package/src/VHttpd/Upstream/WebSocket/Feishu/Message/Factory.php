<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Message;

use VHttpd\Upstream\WebSocket\Feishu\Message;

final class Factory
{
    public static function fromMessage(Message $message): Message
    {
        return $message;
    }
}
