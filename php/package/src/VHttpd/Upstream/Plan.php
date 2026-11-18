<?php
declare(strict_types=1);

namespace VHttpd\Upstream;

final class Plan implements \JsonSerializable
{
    private function __construct(private readonly array $fields) {}

    public static function http(
        string $url,
        string $method,
        array $requestHeaders,
        string $body,
        string $codec,
        string $mapper,
        string $outputStreamType,
        string $outputContentType,
        array $responseHeaders = [],
        string $fixturePath = '',
        string $name = '',
        array $meta = [],
    ): self {
        return new self([
            'transport' => 'http',
            'url' => $url,
            'method' => $method,
            'request_headers' => $requestHeaders,
            'body' => $body,
            'codec' => $codec,
            'mapper' => $mapper,
            'output_stream_type' => $outputStreamType,
            'output_content_type' => $outputContentType,
            'response_headers' => $responseHeaders,
            'fixture_path' => $fixturePath,
            'name' => $name,
            'meta' => $meta,
        ]);
    }

    public function toArray(): array
    {
        return $this->fields;
    }

    public function frame(string $id): array
    {
        return [
            'mode' => 'upstream_plan',
            'strategy' => 'upstream_plan',
            'event' => 'start',
            'id' => $id,
            'request_headers' => (object) $this->fields['request_headers'],
            'response_headers' => (object) $this->fields['response_headers'],
            'meta' => (object) $this->fields['meta'],
        ] + $this->fields;
    }

    public function jsonSerialize(): array
    {
        return $this->toArray();
    }
}
