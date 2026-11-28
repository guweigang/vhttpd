<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Command;

use VHttpd\Upstream\WebSocket\Feishu\Command;

final class Factory
{
    public static function fromCommand(Command $command): Command
    {
        return $command;
    }
}
