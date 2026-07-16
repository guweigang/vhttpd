<?php

declare(strict_types=1);

namespace VHttpd\Cache;

use RuntimeException;
use VHttpd\Wire\JsonClient;

final class Client
{
    private JsonClient $client;

    public function __construct(
        private readonly string $socketPath,
        private readonly string $namespace = 'default',
        private readonly float $connectTimeoutSeconds = 1.0,
        private readonly float $readTimeoutSeconds = 5.0,
    ) {
        $this->client = new JsonClient(
            $this->socketPath,
            'cache_gateway',
            $this->connectTimeoutSeconds,
            $this->readTimeoutSeconds,
        );
    }

    public static function fromEnv(
        string $socketEnv = 'VHTTPD_CACHE_SOCKET',
        string $namespaceEnv = 'VHTTPD_CACHE_NAMESPACE',
        string $defaultSocket = '/tmp/vhttpd-cache.sock',
        string $defaultNamespace = 'default',
    ): self {
        $socket = getenv($socketEnv);
        if (!is_string($socket) || $socket === '') {
            $socket = $_SERVER[$socketEnv] ?? '';
        }
        
        $namespace = getenv($namespaceEnv);
        if (!is_string($namespace) || $namespace === '') {
            $namespace = $_SERVER[$namespaceEnv] ?? '';
        }

        return new self(
            is_string($socket) && $socket !== '' ? $socket : $defaultSocket,
            is_string($namespace) && $namespace !== '' ? $namespace : $defaultNamespace,
        );
    }

    public function ping(): bool
    {
        $response = $this->call('ping', '');
        return (bool) ($response['pong'] ?? false);
    }

    public function get(string $key, ?string $default = null): ?string
    {
        $response = $this->call('get', $key);
        if (!(bool) ($response['found'] ?? false)) {
            return $default;
        }

        return (string) ($response['value'] ?? '');
    }

    public function set(string $key, string $value, int $ttlMs = 0): bool
    {
        $this->call('set', $key, [
            'value' => $value,
            'ttl_ms' => max(0, $ttlMs),
        ]);
        return true;
    }

    public function delete(string $key): bool
    {
        $this->call('delete', $key);
        return true;
    }

    public function exists(string $key): bool
    {
        $response = $this->call('exists', $key);
        return (bool) ($response['found'] ?? false);
    }

    /** @return list<string> */
    public function keys(): array
    {
        $response = $this->call('keys', '');
        $keys = $response['keys'] ?? null;
        if (is_array($keys)) {
            return array_values(array_filter($keys, 'is_string'));
        }

        $raw = (string) ($response['value'] ?? '[]');
        $decoded = json_decode($raw, true);
        if (!is_array($decoded)) {
            return [];
        }

        return array_values(array_filter($decoded, 'is_string'));
    }

    public function compareAndSwapSet(
        string $key,
        bool $expectedFound,
        string $expectedValue,
        string $value,
        int $ttlMs = 0,
    ): bool {
        $response = $this->call('patch', $key, [
            'expected_found' => $expectedFound,
            'expected_value' => $expectedValue,
            'value' => $value,
            'ttl_ms' => max(0, $ttlMs),
        ], false);

        return (bool) ($response['ok'] ?? false) && !(bool) ($response['conflict'] ?? false);
    }

    public function compareAndSwapDelete(string $key, bool $expectedFound, string $expectedValue): bool
    {
        $response = $this->call('patch', $key, [
            'expected_found' => $expectedFound,
            'expected_value' => $expectedValue,
            'delete_value' => true,
        ], false);

        return (bool) ($response['ok'] ?? false) && !(bool) ($response['conflict'] ?? false);
    }

    public function remember(string $key, int $ttlMs, callable $loader): string
    {
        $cached = $this->get($key);
        if ($cached !== null) {
            return $cached;
        }

        $value = (string) $loader();
        $this->set($key, $value, $ttlMs);
        return $value;
    }

    /** @param array<string,mixed> $extra
     *  @return array<string,mixed>
     */
    private function call(string $op, string $key, array $extra = [], bool $throwOnConflict = true): array
    {
        $request = array_merge([
            'version' => 1,
            'mode' => 'cache',
            'op' => $op,
            'namespace' => $this->namespace,
            'key' => $key,
        ], $extra);

        $response = $this->client->request($request);
        if ((bool) ($response['ok'] ?? false)) {
            return $response;
        }

        if (!$throwOnConflict && (bool) ($response['conflict'] ?? false)) {
            return $response;
        }

        $error = (string) ($response['error'] ?? 'cache gateway call failed');
        throw new RuntimeException($error === '' ? 'cache gateway call failed' : $error);
    }
}
