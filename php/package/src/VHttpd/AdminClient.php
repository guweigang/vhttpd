<?php
declare(strict_types=1);

namespace VHttpd;

use VHttpd\Wire\JsonClient;

final class AdminClient
{
    private JsonClient $wire;

    public function __construct(string $socket)
    {
        $this->wire = new JsonClient($socket, 'internal_admin');
    }

    public static function fromEnvironment(): self
    {
        $socket = getenv('VHTTPD_INTERNAL_ADMIN_SOCKET');
        if (!is_string($socket) || $socket === '') {
            throw new \RuntimeException('VHTTPD_INTERNAL_ADMIN_SOCKET is required');
        }
        return new self($socket);
    }

    public function get(string $path, array $query = []): array
    {
        $response = $this->wire->request([
            'method' => 'GET',
            'path' => $path,
            'query' => (object) $query,
        ]);
        if ((int) ($response['status'] ?? 0) !== 200) {
            throw new \RuntimeException('internal admin request failed with status ' . ($response['status'] ?? 0));
        }
        $body = json_decode((string) ($response['body'] ?? ''), true, flags: JSON_THROW_ON_ERROR);
        if (!is_array($body)) {
            throw new \UnexpectedValueException('internal admin JSON body must be an object');
        }
        return $body;
    }
}
