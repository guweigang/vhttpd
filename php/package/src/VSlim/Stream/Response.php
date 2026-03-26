<?php

declare(strict_types=1);

namespace VPhp\VSlim\Stream;

final class Response
{
    public string $stream_type;
    public int $status;
    public string $content_type;

    /** @var array<string,string> */
    private array $headers;

    /** @var iterable<mixed>|callable */
    private mixed $chunks;

    /**
     * @param iterable<mixed>|callable $chunks
     * @param array<string,string> $headers
     */
    private function __construct(
        string $streamType,
        iterable|callable $chunks,
        int $status,
        string $contentType,
        array $headers = [],
    ) {
        $this->stream_type = strtolower($streamType) === 'sse' ? 'sse' : 'text';
        $this->status = $status > 0 ? $status : 200;
        $this->content_type = $contentType !== ''
            ? $contentType
            : ($this->stream_type === 'sse'
                ? 'text/event-stream'
                : 'text/plain; charset=utf-8');
        $this->headers = self::normalizeHeaders($headers + ['content-type' => $this->content_type]);
        $this->chunks = $chunks;
    }

    /**
     * @param iterable<mixed>|callable $chunks
     */
    public static function text(iterable|callable $chunks): self
    {
        return self::textWith($chunks, 200, 'text/plain; charset=utf-8', []);
    }

    /**
     * @param iterable<mixed>|callable $chunks
     * @param array<string,string> $headers
     */
    public static function textWith(
        iterable|callable $chunks,
        int $status = 200,
        string $contentType = 'text/plain; charset=utf-8',
        array $headers = [],
    ): self {
        return new self('text', $chunks, $status, $contentType, $headers);
    }

    /**
     * @param iterable<mixed>|callable $events
     */
    public static function sse(iterable|callable $events): self
    {
        return self::sseWith($events, 200, []);
    }

    /**
     * @param iterable<mixed>|callable $events
     * @param array<string,string> $headers
     */
    public static function sseWith(iterable|callable $events, int $status = 200, array $headers = []): self
    {
        return new self('sse', $events, $status, 'text/event-stream', $headers);
    }

    public function header(string $name): string
    {
        return $this->headers[self::normalizeHeaderName($name)] ?? '';
    }

    /** @return array<string,string> */
    public function headers(): array
    {
        return $this->headers;
    }

    public function has_header(string $name): bool
    {
        return array_key_exists(self::normalizeHeaderName($name), $this->headers);
    }

    public function set_header(string $name, string $value): self
    {
        $normalized = self::normalizeHeaderName($name);
        $this->headers[$normalized] = $value;
        if ($normalized === 'content-type') {
            $this->content_type = $value;
        }
        return $this;
    }

    /** @return iterable<mixed> */
    public function chunks(): iterable
    {
        $chunks = $this->chunks;
        if (is_callable($chunks)) {
            $chunks = $chunks();
        }
        if (!is_iterable($chunks)) {
            return [];
        }
        return $chunks;
    }

    private static function normalizeHeaderName(string $name): string
    {
        return strtolower(trim($name));
    }

    /**
     * @param array<string,string> $headers
     * @return array<string,string>
     */
    private static function normalizeHeaders(array $headers): array
    {
        $normalized = [];
        foreach ($headers as $name => $value) {
            $clean = self::normalizeHeaderName((string) $name);
            if ($clean === '') {
                continue;
            }
            $normalized[$clean] = (string) $value;
        }
        return $normalized;
    }
}
