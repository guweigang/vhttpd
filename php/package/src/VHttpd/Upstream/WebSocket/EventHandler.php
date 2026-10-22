<?php
declare(strict_types=1);
namespace VHttpd\Upstream\WebSocket;

interface EventHandler
{
    public function supports(Event $event): bool;
    public function handle(Event $event, CommandBus $bus): void;
}
