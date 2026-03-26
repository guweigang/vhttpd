<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use VPhp\VHttpd\Upstream\WebSocket\CommandBus;

final class BotResponseHelper
{
    public function commands(array $commands): array
    {
        $bus = new CommandBus();
        foreach ($commands as $command) {
            $bus->send($command);
        }

        return $bus->export();
    }

    public function command(array $command): array
    {
        return $this->commands([$command]);
    }

    public function appendToBus(?array $response, CommandBus $bus): bool
    {
        if (!is_array($response)) {
            return false;
        }

        $commands = $response['commands'] ?? null;
        if (is_array($commands)) {
            foreach ($commands as $command) {
                if (is_array($command)) {
                    $bus->send($command);
                }
            }
        }

        return true;
    }
}
