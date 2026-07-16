<?php

declare(strict_types=1);

namespace VHttpd\PhpWorker;

final class StreamApp
{
    /** @var array<string,\Iterator<mixed>> */
    private array $sessions = [];

    /**
     * @param iterable<mixed>|callable $chunks
     * @param array<string,string> $headers
     */
    private function __construct(
        private readonly string $streamType,
        private readonly mixed $chunks,
        private readonly int $status,
        private readonly string $contentType,
        private readonly array $headers,
        private readonly int $batchSize,
        private readonly int $delayMs,
    ) {
    }

    /**
     * @param iterable<mixed>|callable $chunks
     * @param array<string,string> $headers
     */
    public static function fromSequence(
        string $streamType,
        iterable|callable $chunks,
        int $status = 200,
        string $contentType = 'text/plain; charset=utf-8',
        array $headers = [],
        int $batchSize = 1,
        int $delayMs = 0,
    ): self {
        $type = strtolower($streamType) === 'sse' ? 'sse' : 'text';
        $resolvedContentType = $contentType !== ''
            ? $contentType
            : ($type === 'sse' ? 'text/event-stream' : 'text/plain; charset=utf-8');

        return new self(
            $type,
            $chunks,
            $status > 0 ? $status : 200,
            $resolvedContentType,
            self::normalizeHeaders($headers),
            max(1, $batchSize),
            max(0, $delayMs),
        );
    }

    public static function fromStreamResponse(object $response, int $batchSize = 1, int $delayMs = 0): self
    {
        $streamType = (string) ($response->stream_type ?? $response->streamType ?? 'text');
        $status = (int) ($response->status ?? 200);
        $contentType = (string) ($response->content_type ?? $response->contentType ?? '');
        $headers = method_exists($response, 'headers') ? $response->headers() : ($response->headers ?? []);
        $chunks = method_exists($response, 'chunks') ? $response->chunks() : ($response->chunks ?? []);

        return self::fromSequence(
            $streamType,
            is_iterable($chunks) || is_callable($chunks) ? $chunks : [],
            $status,
            $contentType,
            is_array($headers) ? $headers : [],
            $batchSize,
            $delayMs,
        );
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    public function handle(array $frame): array
    {
        $event = (string) ($frame['event'] ?? 'next');
        $id = self::streamId($frame);

        if ($event === 'close') {
            unset($this->sessions[$id]);
            return $this->response($frame, true, [], true);
        }

        if ($event === 'open' || !isset($this->sessions[$id])) {
            $this->sessions[$id] = self::toIterator($this->chunks);
        } elseif ($this->delayMs > 0) {
            usleep($this->delayMs * 1000);
        }

        $iterator = $this->sessions[$id];
        $chunks = $this->nextChunks($iterator);
        $done = !$iterator->valid();
        if ($done) {
            unset($this->sessions[$id]);
        }

        return $this->response($frame, true, $chunks, $done);
    }

    /**
     * @return \Iterator<mixed>
     */
    private static function toIterator(mixed $chunks): \Iterator
    {
        if (is_callable($chunks)) {
            $chunks = $chunks();
        }
        if ($chunks instanceof \Iterator) {
            $chunks->rewind();
            return $chunks;
        }
        if ($chunks instanceof \IteratorAggregate) {
            $iterator = $chunks->getIterator();
            $iterator->rewind();
            return $iterator;
        }
        if (is_array($chunks)) {
            return new \ArrayIterator($chunks);
        }

        return new \ArrayIterator([]);
    }

    /**
     * @param \Iterator<mixed> $iterator
     * @return array<int,array<string,mixed>>
     */
    private function nextChunks(\Iterator $iterator): array
    {
        $chunks = [];
        for ($i = 0; $i < $this->batchSize && $iterator->valid(); ++$i) {
            $chunks[] = $this->normalizeChunk($iterator->current());
            $iterator->next();
        }
        return $chunks;
    }

    /**
     * @return array<string,mixed>
     */
    private function normalizeChunk(mixed $chunk): array
    {
        if ($this->streamType === 'sse') {
            if (is_array($chunk)) {
                return [
                    'event' => (string) ($chunk['event'] ?? $chunk['sse_event'] ?? ''),
                    'id' => (string) ($chunk['id'] ?? $chunk['sse_id'] ?? ''),
                    'data' => (string) ($chunk['data'] ?? ''),
                    'retry' => self::intValue($chunk['retry'] ?? $chunk['sse_retry'] ?? 0),
                ];
            }

            return [
                'event' => '',
                'id' => '',
                'data' => (string) $chunk,
                'retry' => 0,
            ];
        }

        return [
            'event' => '',
            'id' => '',
            'data' => (string) $chunk,
            'retry' => 0,
        ];
    }

    /**
     * @param array<string,mixed> $frame
     * @param array<int,array<string,mixed>> $chunks
     * @return array<string,mixed>
     */
    private function response(array $frame, bool $handled, array $chunks, bool $done): array
    {
        return [
            'mode' => 'stream',
            'strategy' => 'dispatch',
            'event' => (string) ($frame['event'] ?? ''),
            'id' => self::streamId($frame),
            'handled' => $handled,
            'done' => $done,
            'stream_type' => $this->streamType,
            'content_type' => $this->contentType,
            'headers' => $this->headers,
            'state' => [
                'stream_id' => self::streamId($frame),
            ],
            'chunks' => $chunks,
        ];
    }

    /**
     * @param array<string,mixed> $frame
     */
    private static function streamId(array $frame): string
    {
        $id = (string) ($frame['id'] ?? '');
        if ($id !== '') {
            return $id;
        }
        $requestId = (string) ($frame['request_id'] ?? '');
        return $requestId !== '' ? $requestId : 'stream';
    }

    /**
     * @param array<mixed,mixed> $headers
     * @return array<string,string>
     */
    private static function normalizeHeaders(array $headers): array
    {
        $out = [];
        foreach ($headers as $name => $value) {
            $key = strtolower(trim((string) $name));
            if ($key === '') {
                continue;
            }
            $out[$key] = is_array($value) ? implode(', ', array_map('strval', $value)) : (string) $value;
        }
        return $out;
    }

    private static function intValue(mixed $value): int
    {
        return is_numeric($value) ? (int) $value : 0;
    }
}
