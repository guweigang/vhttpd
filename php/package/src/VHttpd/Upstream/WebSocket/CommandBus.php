<?php
declare(strict_types=1);
namespace VHttpd\Upstream\WebSocket;

final class CommandBus
{
    private array $commands = [];
    private bool $handled = false;
    public function markHandled(): void { $this->handled = true; }
    public function send(array|Command $command): self
    {
        $this->commands[] = ($command instanceof Command ? $command : new Command($command))->toArray();
        $this->handled = true;
        return $this;
    }
    public function export(): array { return ['handled' => $this->handled, 'commands' => $this->commands]; }
}
