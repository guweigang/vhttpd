<?php

declare(strict_types=1);

namespace VHttpd\PhpWorker;

use SessionHandlerInterface;
use VHttpd\Cache\Client;

/**
 * Standard PHP SessionHandler implementation using vhttpd cachex client.
 * Permits standard native $_SESSION arrays to store data in the memory cache.
 */
final class SessionHandler implements SessionHandlerInterface
{
    public function __construct(
        private readonly Client $client,
        private readonly string $prefix = 'php_session:',
        private readonly int $ttlSeconds = 1440, // default PHP session gc lifetime (24 mins)
    ) {}

    public function open(string $path, string $name): bool
    {
        return true;
    }

    public function close(): bool
    {
        return true;
    }

    public function read(string $id): string
    {
        try {
            return $this->client->get($this->prefix . $id) ?? '';
        } catch (\Throwable) {
            return '';
        }
    }

    public function write(string $id, string $data): bool
    {
        try {
            return $this->client->set($this->prefix . $id, $data, $this->ttlSeconds * 1000);
        } catch (\Throwable) {
            return false;
        }
    }

    public function destroy(string $id): bool
    {
        try {
            return $this->client->delete($this->prefix . $id);
        } catch (\Throwable) {
            return false;
        }
    }

    public function gc(int $max_lifetime): int|false
    {
        // Cachex manages key expiration automatically via set TTL, manual GC is not needed.
        return 0;
    }
}
