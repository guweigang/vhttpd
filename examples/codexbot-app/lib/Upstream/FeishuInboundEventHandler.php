<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use VPhp\VHttpd\Upstream\WebSocket\CommandBus;
use VPhp\VHttpd\Upstream\WebSocket\Event;
use VPhp\VHttpd\Upstream\WebSocket\EventHandler;

final class FeishuInboundEventHandler implements EventHandler
{
    public function __construct(
        private BotResponseHelper $responseHelper,
        private FeishuInboundRouter $router,
    ) {
    }

    public function supports(Event $event): bool
    {
        return $event->matches('feishu', 'im.message.receive_v1');
    }

    public function handle(Event $event, CommandBus $bus): void
    {
        $response = $this->router->dispatch($event->payloadArray());
        $this->responseHelper->appendToBus($response, $bus);
    }
}
