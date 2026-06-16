<?php

declare(strict_types=1);

namespace VHttpd\Wire;

use RuntimeException;

final class JsonClient
{
    /** @var resource|null */
    private $conn = null;

    public function __construct(
        private readonly string $socketPath,
        private readonly string $errorPrefix = 'wire',
        private readonly float $connectTimeoutSeconds = 1.0,
        private readonly float $readTimeoutSeconds = 5.0,
    ) {
    }

    public function __destruct()
    {
        $this->close();
    }

    public function connect(): void
    {
        if (is_resource($this->conn)) {
            return;
        }

        $errno = 0;
        $errstr = '';
        $conn = @stream_socket_client('unix://' . $this->socketPath, $errno, $errstr, $this->connectTimeoutSeconds);
        if (!is_resource($conn)) {
            throw new RuntimeException("{$this->errorPrefix}_connect_failed: {$errstr} ({$errno})");
        }

        stream_set_blocking($conn, true);
        stream_set_timeout(
            $conn,
            (int) floor($this->readTimeoutSeconds),
            (int) (($this->readTimeoutSeconds - floor($this->readTimeoutSeconds)) * 1_000_000),
        );
        $this->conn = $conn;
    }

    public function close(): void
    {
        if (!is_resource($this->conn)) {
            return;
        }
        @fclose($this->conn);
        $this->conn = null;
    }

    /** @param array<string,mixed> $request
     *  @return array<string,mixed>
     */
    public function request(array $request): array
    {
        $this->connect();
        if (!is_resource($this->conn)) {
            throw new RuntimeException('connection_not_open');
        }

        try {
            $json = json_encode($request, JSON_UNESCAPED_UNICODE);
            if (!is_string($json)) {
                throw new RuntimeException('json_encode_failed');
            }

            FrameCodec::write($this->conn, $json);
            $raw = FrameCodec::read($this->conn);
            if ($raw === '') {
                throw new RuntimeException("{$this->errorPrefix}_empty_response");
            }

            $response = json_decode($raw, true);
            if (!is_array($response)) {
                throw new RuntimeException("{$this->errorPrefix}_invalid_response_json");
            }

            return $response;
        } finally {
            $this->close();
        }
    }
}
