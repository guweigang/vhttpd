<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use VPhp\VHttpd\Upstream\WebSocket\CommandBus;
use VPhp\VHttpd\Upstream\WebSocket\Event;
use VPhp\VHttpd\Upstream\WebSocket\EventHandler;

final class ProviderUpstreamEventHandler implements EventHandler
{
    public function __construct(
        private BotResponseHelper $responseHelper,
        private ProviderEventRouter $router,
    ) {
    }

    public function supports(Event $event): bool
    {
        return in_array($event->provider(), ['codex', 'feishu'], true);
    }

    public function handle(Event $event, CommandBus $bus): void
    {
        $response = $this->router->dispatch(
            $event->provider(),
            $event->eventType(),
            $event->payloadArray(),
            $event->request(),
        );
        $this->responseHelper->appendToBus($response, $bus);
    }
}
