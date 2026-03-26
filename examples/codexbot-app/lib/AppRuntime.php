<?php

declare(strict_types=1);

namespace CodexBot;

use CodexBot\Admin\AdminHttpApp;
use CodexBot\Upstream\UpstreamGraphFactory;
use VPhp\VHttpd\Upstream\WebSocket\CommandBus;
use VPhp\VHttpd\Upstream\WebSocket\Event;

final class AppRuntime
{
    private ?array $upstreamGraph = null;

    public function __construct(
        private ?UpstreamGraphFactory $graphFactory = null,
        private ?AdminHttpApp $adminHttpApp = null,
    ) {
        $this->graphFactory ??= new UpstreamGraphFactory();
        $this->adminHttpApp ??= new AdminHttpApp();
    }

    public function __invoke(mixed $request, array $envelope = []): array
    {
        return $this->handle($request, $envelope);
    }

    public function handle(mixed $request, array $envelope = []): array
    {
        $req = is_array($request) ? $request : $envelope;
        $mode = (string) ($req['mode'] ?? '');

        if ($mode === 'websocket_upstream') {
            return $this->handleWebSocketUpstream($req);
        }

        return $this->handleHttp($req);
    }

    public function handlers(): array
    {
        return [
            'http' => $this,
            'websocket_upstream' => $this,
        ];
    }

    private function handleWebSocketUpstream(array $request): array
    {
        $provider = (string) ($request['provider'] ?? '');
        $eventType = (string) ($request['event_type'] ?? '');
        $payloadRaw = (string) ($request['payload'] ?? '');

        file_put_contents(
            'php://stderr',
            "[PHP] Provider: {$provider}, Event: {$eventType}, Payload: " . substr($payloadRaw, 0, 200) . "...\n"
        );

        $event = Event::fromDispatchRequest($request);
        $bus = $this->upstreamGraph()['event_router']->dispatch($event, new CommandBus());
        return $bus->export();
    }

    private function handleHttp(array $request): array
    {
        return $this->adminHttpApp->handle($request);
    }

    private function upstreamGraph(): array
    {
        if (!is_array($this->upstreamGraph)) {
            $this->upstreamGraph = $this->graphFactory->create();
        }

        return $this->upstreamGraph;
    }
}
