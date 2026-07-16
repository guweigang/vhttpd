<?php

declare(strict_types=1);

namespace VHttpd\DbGateway;

use RuntimeException;

class PDO
{
    private ?Client $client = null;
    private ?string $sessionId = null;
    private ?string $lastInsertId = null;

    public function __construct(
        private string $socketPath,
        private string $pool = 'default',
        private float $connectTimeoutSeconds = 1.0,
        private float $readTimeoutSeconds = 5.0,
    ) {
    }

    public function __destruct()
    {
        $this->close();
    }

    public function connect(): void
    {
        if ($this->client === null) {
            $this->client = new Client(
                $this->socketPath,
                $this->pool,
                $this->connectTimeoutSeconds,
                $this->readTimeoutSeconds,
            );
        }
        $this->client->connect();
    }

    public function close(): void
    {
        $this->client?->close();
        $this->client = null;
        $this->sessionId = null;
    }

    public function inTransaction(): bool
    {
        return $this->sessionId !== null;
    }

    public function beginTransaction(): bool
    {
        if ($this->sessionId !== null) {
            throw new RuntimeException('transaction_already_started');
        }

        $this->sessionId = $this->client()->beginTransaction();
        return true;
    }

    public function commit(): bool
    {
        if ($this->sessionId === null) {
            throw new RuntimeException('no_active_transaction');
        }
        $this->client()->commit($this->sessionId);
        $this->sessionId = null;
        return true;
    }

    public function rollBack(): bool
    {
        if ($this->sessionId === null) {
            throw new RuntimeException('no_active_transaction');
        }
        $this->client()->rollback($this->sessionId);
        $this->sessionId = null;
        return true;
    }

    public function prepare(string $sql): PDOStatement
    {
        return new PDOStatement($this, $sql);
    }

    public function query(string $sql, ?array $params = null): PDOStatement
    {
        $stmt = $this->prepare($sql);
        $stmt->execute($params ?? []);
        return $stmt;
    }

    public function exec(string $sql, ?array $params = null): int
    {
        return $this->execute($sql, $params ?? []);
    }

    public function execute(string $sql, array $bindings = [], int $timeoutMs = 1000): int
    {
        $result = $this->gatewayExecute($sql, $bindings, $timeoutMs);
        return (int) ($result['affected_rows'] ?? 0);
    }

    /** @return array<string,mixed> */
    public function gatewayExecute(string $sql, array $bindings = [], int $timeoutMs = 1000): array
    {
        $result = $this->client()->execute($sql, array_values($bindings), $this->sessionId ?? '', $timeoutMs);
        $this->lastInsertId = isset($result['last_insert_id']) ? (string) $result['last_insert_id'] : null;
        return $result;
    }

    /** @return array<string,mixed> */
    public function gatewayQuery(string $sql, array $bindings = [], int $timeoutMs = 1000): array
    {
        return $this->client()->query($sql, array_values($bindings), $this->sessionId ?? '', $timeoutMs);
    }

    public function isQuerySql(string $sql): bool
    {
        $prefix = strtoupper(strtok(ltrim($sql), " \t\r\n(") ?: '');
        return in_array($prefix, ['SELECT', 'SHOW', 'DESCRIBE', 'EXPLAIN', 'WITH', 'PRAGMA'], true);
    }

    public function lastInsertId(): ?string
    {
        return $this->lastInsertId;
    }

    public function ping(): bool
    {
        $this->client()->ping();
        return true;
    }

    private function client(): Client
    {
        $this->connect();
        return $this->client ?? throw new RuntimeException('db_gateway_client_not_initialized');
    }
}
