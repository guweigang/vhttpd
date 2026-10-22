<?php
declare(strict_types=1);
namespace VHttpd\Upstream\WebSocket;

final class EventRouter
{
    /** @var list<EventHandler> */
    private array $handlers = [];
    public function addHandler(EventHandler $handler): self
    {
        $this->handlers[] = $handler;
        return $this;
    }
    public function dispatch(Event $event, ?CommandBus $bus = null): CommandBus
    {
        $bus ??= new CommandBus();
        foreach ($this->handlers as $handler) {
            if (!$handler->supports($event)) continue;
            $handler->handle($event, $bus);
            $bus->markHandled();
        }
        return $bus;
    }
}
