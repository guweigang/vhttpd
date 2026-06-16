<?php

declare(strict_types=1);

namespace VHttpd\DbGateway;

use RuntimeException;
use VHttpd\Wire\JsonClient;

final class Client
{
    private JsonClient $client;

    public function __construct(
        private readonly string $socketPath,
        private readonly string $pool = 'default',
        private readonly float $connectTimeoutSeconds = 1.0,
        private readonly float $readTimeoutSeconds = 5.0,
    ) {
        $this->client = new JsonClient(
            $this->socketPath,
            'db_gateway',
            $this->connectTimeoutSeconds,
            $this->readTimeoutSeconds,
        );
    }

    public static function fromEnv(
        string $socketEnv = 'VHTTPD_DB_SOCKET',
        string $poolEnv = 'VHTTPD_DB_POOL',
        string $timeoutEnv = 'VHTTPD_DB_TIMEOUT_MS',
        string $defaultSocket = '/tmp/vhttpd_db.sock',
        string $defaultPool = 'default',
    ): self {
        $socket = getenv($socketEnv);
        $pool = getenv($poolEnv);
        $timeout = getenv($timeoutEnv);
        $timeoutSeconds = is_string($timeout) && ctype_digit($timeout)
            ? max(1, (int) $timeout) / 1000
            : 5.0;

        return new self(
            is_string($socket) && $socket !== '' ? $socket : $defaultSocket,
            is_string($pool) && $pool !== '' ? $pool : $defaultPool,
            1.0,
            $timeoutSeconds,
        );
    }

    public function connect(): void
    {
        $this->client->connect();
    }

    public function close(): void
    {
        $this->client->close();
    }

    /** @return array<string,mixed> */
    public function ping(int $timeoutMs = 1000): array
    {
        return $this->call('ping', '', [], '', $timeoutMs);
    }

    public function beginTransaction(int $timeoutMs = 1000): string
    {
        $response = $this->call('begin_transaction', '', [], '', $timeoutMs);
        $sessionId = (string) ($response['session_id'] ?? '');
        if ($sessionId === '') {
            throw new RuntimeException('db_begin_missing_session_id');
        }

        return $sessionId;
    }

    /** @return array<string,mixed> */
    public function commit(string $sessionId, int $timeoutMs = 1000): array
    {
        return $this->call('commit', '', [], $sessionId, $timeoutMs);
    }

    /** @return array<string,mixed> */
    public function rollback(string $sessionId, int $timeoutMs = 1000): array
    {
        return $this->call('rollback', '', [], $sessionId, $timeoutMs);
    }

    /** @param array<int,mixed> $params
     *  @return array<string,mixed>
     */
    public function query(string $sql, array $params = [], string $sessionId = '', int $timeoutMs = 1000): array
    {
        return $this->call('query', $sql, $params, $sessionId, $timeoutMs);
    }

    /** @param array<int,mixed> $params
     *  @return array<string,mixed>
     */
    public function execute(string $sql, array $params = [], string $sessionId = '', int $timeoutMs = 1000): array
    {
        return $this->call('execute', $sql, $params, $sessionId, $timeoutMs);
    }

    public function escape(string $value, string $sessionId = '', int $timeoutMs = 1000): string
    {
        $response = $this->call('escape', '', [$value], $sessionId, $timeoutMs);
        return (string) ($response['escaped'] ?? '');
    }

    /** @param array<int,mixed> $params
     *  @return array<string,mixed>
     */
    public function call(string $op, string $sql = '', array $params = [], string $sessionId = '', int $timeoutMs = 1000): array
    {
        $request = [
            'version' => 1,
            'mode' => 'db',
            'op' => $op,
            'pool' => $this->pool,
            'timeout_ms' => $timeoutMs,
            'session_id' => $sessionId,
            'sql' => $sql,
            'params' => array_map(static fn (mixed $value): string => (string) $value, array_values($params)),
        ];

        $response = $this->client->request($request);
        if ((bool) ($response['ok'] ?? false)) {
            return $response;
        }

        $error = $response['error'] ?? 'db gateway call failed';
        $message = is_array($error)
            ? (string) ($error['message'] ?? 'db gateway call failed')
            : (string) $error;
        throw new RuntimeException($message === '' ? 'db gateway call failed' : $message);
    }
}
