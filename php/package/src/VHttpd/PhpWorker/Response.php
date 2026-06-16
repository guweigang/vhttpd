<?php

declare(strict_types=1);

namespace VHttpd\PhpWorker;

final class Response
{
    /** @param array<string,string> $headers */
    public function __construct(
        public readonly string $id = '',
        public readonly int $status = 200,
        public readonly array $headers = [],
        public readonly string $body = '',
    ) {
    }

    /** @param array<string,mixed> $payload */
    public static function fromArray(array $payload): self
    {
        return new self(
            (string) ($payload['id'] ?? ''),
            (int) ($payload['status'] ?? 200),
            self::normalizeHeaders($payload['headers'] ?? []),
            (string) ($payload['body'] ?? ''),
        );
    }

    /** @param array<string,string> $headers */
    public static function text(string $body, int $status = 200, array $headers = [], string $id = ''): self
    {
        if (!isset($headers['content-type'])) {
            $headers['content-type'] = 'text/plain; charset=utf-8';
        }
        return new self($id, $status, $headers, $body);
    }

    /** @param array<string,string> $headers */
    public static function html(string $body, int $status = 200, array $headers = [], string $id = ''): self
    {
        if (!isset($headers['content-type'])) {
            $headers['content-type'] = 'text/html; charset=utf-8';
        }
        return new self($id, $status, $headers, $body);
    }

    /** @param array<string,mixed> $data
     *  @param array<string,string> $headers
     */
    public static function json(array $data, int $status = 200, array $headers = [], string $id = ''): self
    {
        if (!isset($headers['content-type'])) {
            $headers['content-type'] = 'application/json; charset=utf-8';
        }
        return new self($id, $status, $headers, json_encode($data, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR));
    }

    /** @return array<string,mixed> */
    public function toArray(): array
    {
        return [
            'id' => $this->id,
            'status' => $this->status,
            'headers' => self::normalizeHeaders($this->headers),
            'body' => $this->body,
        ];
    }

    /** @return array<string,string> */
    private static function normalizeHeaders(mixed $headers): array
    {
        if (!is_array($headers)) {
            return [];
        }

        $out = [];
        foreach ($headers as $name => $value) {
            if (!is_string($name) && !is_int($name)) {
                continue;
            }
            $out[strtolower((string) $name)] = is_array($value) ? implode(', ', array_map('strval', $value)) : (string) $value;
        }

        return $out;
    }
}
