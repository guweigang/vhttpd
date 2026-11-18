<?php
declare(strict_types=1);

namespace VHttpd\PhpWorker\WebSocket;

interface CommandSink
{
    public function id(): string;
    public function accept(): void;
    public function reject(int $status = 403, string $reason = ''): void;
    public function send(string $data, string $opcode = 'text'): void;
    public function close(int $code = 1000, string $reason = ''): void;
    public function join(string $room): void;
    public function leave(string $room): void;
    public function setMeta(string $key, string $value): void;
    public function clearMeta(string $key): void;
    public function setPresence(string $value): void;
    public function broadcast(string $room, string $data, string $opcode = 'text', string $exceptId = ''): void;
    public function sendTo(string $targetId, string $data, string $opcode = 'text'): void;
}
