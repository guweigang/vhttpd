<?php

declare(strict_types=1);

namespace VPhp\VSlim\WebSocket;

use VPhp\VHttpd\Attribute\Dispatchable;
use VPhp\VHttpd\PhpWorker\WebSocket\CommandSink;

#[Dispatchable('websocket')]
final class App
{
    /** @var null|callable */
    private $onOpen;
    /** @var null|callable */
    private $onMessage;
    /** @var null|callable */
    private $onClose;

    public function __construct(
        ?callable $onOpen = null,
        ?callable $onMessage = null,
        ?callable $onClose = null,
    ) {
        $this->onOpen = $onOpen;
        $this->onMessage = $onMessage;
        $this->onClose = $onClose;
    }

    /** @param array<string,mixed> $frame */
    public function handle(array $frame, CommandSink $conn): mixed
    {
        $event = (string) ($frame['event'] ?? '');
        return match ($event) {
            'open' => $this->onOpen !== null ? ($this->onOpen)($conn, $frame) : null,
            'message' => $this->onMessage !== null ? ($this->onMessage)(
                $conn,
                (string) ($frame['data'] ?? ''),
                $frame,
            ) : null,
            'close' => $this->onClose !== null ? ($this->onClose)(
                $conn,
                (int) ($frame['code'] ?? 1000),
                (string) ($frame['reason'] ?? ''),
                $frame,
            ) : null,
            default => null,
        };
    }
}
