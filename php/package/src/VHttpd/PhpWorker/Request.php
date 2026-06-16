<?php

declare(strict_types=1);

namespace VHttpd\PhpWorker;

final class Request
{
    /** @param array<string,string> $headers
     *  @param array<string,mixed> $query
     */
    public function __construct(
        public readonly string $id,
        public readonly string $method,
        public readonly string $path,
        public readonly array $query = [],
        public readonly array $headers = [],
        public readonly string $body = '',
    ) {
    }

    /** @param array<string,mixed> $payload */
    public static function fromArray(array $payload): self
    {
        return new self(
            (string) ($payload['id'] ?? ''),
            strtoupper((string) ($payload['method'] ?? 'GET')),
            (string) ($payload['path'] ?? '/'),
            self::stringMap($payload['query'] ?? []),
            self::stringMap($payload['headers'] ?? []),
            (string) ($payload['body'] ?? ''),
        );
    }

    /** @param array<string,string> $headers
     *  @param array<string,mixed> $query
     */
    public static function http(
        string $method,
        string $path,
        array $query = [],
        array $headers = [],
        string $body = '',
        string $id = 'cli-1',
    ): self {
        return new self($id, strtoupper($method), $path, $query, $headers, $body);
    }

    /** @return array<string,mixed> */
    public function toArray(): array
    {
        return [
            'id' => $this->id,
            'method' => $this->method,
            'path' => $this->path,
            'query' => $this->query,
            'headers' => $this->headers,
            'body' => $this->body,
        ];
    }

    /** @return array<string,string> */
    private static function stringMap(mixed $value): array
    {
        if (!is_array($value)) {
            return [];
        }

        $out = [];
        foreach ($value as $key => $item) {
            if (!is_string($key) && !is_int($key)) {
                continue;
            }
            $out[(string) $key] = is_array($item) ? implode(', ', array_map('strval', $item)) : (string) $item;
        }
        return $out;
    }
}
