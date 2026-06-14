<?php

declare(strict_types=1);

namespace VHttpd\PhpWorker;

final class StreamResponse
{
    public function __construct(
        public readonly iterable $chunks,
        public readonly int $status = 200,
        public readonly array $headers = [],
        public readonly string $streamType = 'text',
        public readonly string $contentType = 'text/plain; charset=utf-8',
    ) {
    }

    public static function text(
        iterable $chunks,
        int $status = 200,
        string $contentType = 'text/plain; charset=utf-8',
        array $headers = [],
    ): self {
        return new self($chunks, $status, $headers, 'text', $contentType);
    }

    public static function sse(iterable $events, int $status = 200, array $headers = []): self
    {
        return new self($events, $status, $headers, 'sse', 'text/event-stream');
    }
}
