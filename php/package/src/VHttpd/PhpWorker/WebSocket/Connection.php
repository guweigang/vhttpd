<?php
declare(strict_types=1);

namespace VHttpd\PhpWorker\WebSocket;

use VHttpd\Wire\FrameCodec;

final class Connection implements CommandSink
{
    private array $frames = [];
    private bool $accepted = false;
    private bool $rejected = false;
    private bool $closed = false;

    /** @param resource|null $stream */
    public function __construct(
        private mixed $stream,
        public readonly string $id,
        private readonly ?\Closure $current = null,
    ) {}

    public function id(): string { return $this->id; }

    public function accept(): void
    {
        if (!$this->accepted && !$this->rejected && !$this->closed) {
            $this->accepted = true;
            $this->emit('accept');
        }
    }

    public function reject(int $status = 403, string $reason = ''): void
    {
        if (!$this->accepted && !$this->rejected) {
            $this->rejected = true;
            $this->emit('reject', compact('status', 'reason'));
        }
    }

    public function send(string $data, string $opcode = 'text'): void
    {
        if ($this->current !== null && ($active = ($this->current)()) !== $this) {
            if ($active !== null) {
                if ($active->id === $this->id) {
                    $active->send($data, $opcode);
                } else {
                    $active->sendTo($this->id, $data, $opcode);
                }
            }
            return;
        }
        $this->emit('send', compact('data', 'opcode'));
    }

    public function close(int $code = 1000, string $reason = ''): void
    {
        if (!$this->closed) {
            $this->closed = true;
            $this->emit('close', compact('code', 'reason'));
        }
    }

    public function join(string $room): void { $this->emit('join', compact('room')); }
    public function leave(string $room): void { $this->emit('leave', compact('room')); }
    public function setMeta(string $key, string $value): void { $this->emit('set_meta', compact('key', 'value')); }
    public function clearMeta(string $key): void { $this->emit('clear_meta', compact('key')); }
    public function setPresence(string $value): void { $this->setMeta('presence', $value); }

    public function broadcast(string $room, string $data, string $opcode = 'text', string $exceptId = ''): void
    {
        $this->emit('broadcast', compact('room', 'data', 'opcode') + ['except_id' => $exceptId]);
    }

    public function sendTo(string $targetId, string $data, string $opcode = 'text'): void
    {
        $this->emit('send_to', compact('data', 'opcode') + ['target_id' => $targetId]);
    }

    public function done(): void { $this->emit('done'); }

    public function frames(): array { return $this->frames; }
    public function accepted(): bool { return $this->accepted; }
    public function rejected(): bool { return $this->rejected; }
    public function closed(): bool { return $this->closed; }

    private function emit(string $event, array $data = []): void
    {
        $frame = ['mode' => 'websocket', 'event' => $event, 'id' => $this->id] + $data;
        if (is_resource($this->stream)) {
            FrameCodec::write($this->stream, json_encode($frame, JSON_THROW_ON_ERROR));
            return;
        }
        $this->frames[] = $frame;
    }
}
