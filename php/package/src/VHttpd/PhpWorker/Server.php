<?php

declare(strict_types=1);

namespace VHttpd\PhpWorker;

use Throwable;

function parseSocketFromArgv(array $argv): string
{
    foreach ($argv as $index => $arg) {
        if ($arg === '--socket' && isset($argv[$index + 1])) {
            return (string) $argv[$index + 1];
        }
        if (str_starts_with((string) $arg, '--socket=')) {
            return substr((string) $arg, strlen('--socket='));
        }
    }

    $socket = getenv('VHTTPD_WORKER_SOCKET');
    if (is_string($socket) && $socket !== '') {
        return $socket;
    }

    throw new \RuntimeException('vhttpd worker socket is required');
}

final class Server
{
    /** @var callable */
    private $app;

    public function __construct(
        private readonly string $socketPath,
        private readonly string $defaultApp,
    ) {
        $appPath = getenv('VHTTPD_APP');
        if (!is_string($appPath) || $appPath === '') {
            $appPath = $this->defaultApp;
        }
        if (!is_file($appPath)) {
            throw new \RuntimeException('vhttpd app entry not found: ' . $appPath);
        }

        $app = require $appPath;
        if (!is_callable($app)) {
            throw new \RuntimeException('vhttpd app entry must return a callable');
        }
        $this->app = $app;
    }

    public function run(): void
    {
        if ($this->socketPath === '') {
            throw new \RuntimeException('vhttpd worker socket is empty');
        }

        if (file_exists($this->socketPath) || is_link($this->socketPath)) {
            @unlink($this->socketPath);
        }

        if (!extension_loaded('sockets')) {
            throw new \RuntimeException('php sockets extension is required for vhttpd worker sockets');
        }

        $server = @socket_create(AF_UNIX, SOCK_STREAM, 0);
        if (!$server) {
            throw new \RuntimeException('failed to create worker socket: ' . socket_strerror(socket_last_error()));
        }
        if (!@socket_bind($server, $this->socketPath)) {
            $error = socket_strerror(socket_last_error($server));
            socket_close($server);
            throw new \RuntimeException("failed to bind worker socket {$this->socketPath}: {$error}");
        }
        if (!@socket_listen($server)) {
            $error = socket_strerror(socket_last_error($server));
            socket_close($server);
            throw new \RuntimeException("failed to listen on worker socket {$this->socketPath}: {$error}");
        }

        while (true) {
            $conn = @socket_accept($server);
            if (!$conn) {
                continue;
            }
            $this->handleConnection($conn);
            socket_close($conn);
        }
    }

    /**
     * @param \Socket $conn
     */
    private function handleConnection($conn): void
    {
        try {
            $raw = self::readFrame($conn);
            $payload = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
            if (!is_array($payload)) {
                throw new \RuntimeException('worker payload must be a JSON object');
            }

            $result = ($this->app)($payload, $payload);
            self::writeFrame($conn, json_encode(self::normalizeResponse($payload, $result), JSON_THROW_ON_ERROR));
        } catch (Throwable $e) {
            if (str_contains($e->getMessage(), 'unexpected EOF')) {
                return;
            }
            try {
                self::writeFrame($conn, json_encode(self::errorResponse($e), JSON_THROW_ON_ERROR));
            } catch (Throwable) {
                return;
            }
        }
    }

    /**
     * @param \Socket $conn
     */
    private static function readFrame($conn): string
    {
        $header = self::readExact($conn, 4);
        $unpacked = unpack('Nsize', $header);
        $size = (int) ($unpacked['size'] ?? 0);
        if ($size <= 0 || $size > 16 * 1024 * 1024) {
            throw new \RuntimeException('invalid worker frame size: ' . $size);
        }

        return self::readExact($conn, $size);
    }

    /**
     * @param \Socket $conn
     */
    private static function readExact($conn, int $size): string
    {
        $buf = '';
        while (strlen($buf) < $size) {
            $chunk = socket_read($conn, $size - strlen($buf), PHP_BINARY_READ);
            if ($chunk === false || $chunk === '') {
                throw new \RuntimeException('unexpected EOF while reading worker frame');
            }
            $buf .= $chunk;
        }

        return $buf;
    }

    /**
     * @param \Socket $conn
     */
    private static function writeFrame($conn, string $payload): void
    {
        $data = pack('N', strlen($payload)) . $payload;
        $written = 0;
        $size = strlen($data);
        while ($written < $size) {
            $n = socket_write($conn, substr($data, $written), $size - $written);
            if ($n === false || $n === 0) {
                throw new \RuntimeException('failed to write worker frame');
            }
            $written += $n;
        }
    }

    private static function normalizeResponse(array $request, mixed $result): array
    {
        if ($result instanceof StreamResponse) {
            return self::normalizeStreamResponse($request, $result);
        }
        if (!is_array($result)) {
            $result = [
                'status' => 200,
                'body' => (string) $result,
            ];
        }

        $headers = self::normalizeHeaders($result['headers'] ?? []);
        $contentType = (string) ($result['content_type'] ?? $result['contentType'] ?? '');
        if ($contentType !== '' && !isset($headers['content-type'])) {
            $headers['content-type'] = $contentType;
        }

        return [
            'id' => (string) ($request['id'] ?? ''),
            'status' => (int) ($result['status'] ?? 200),
            'headers' => $headers,
            'body' => (string) ($result['body'] ?? ''),
        ];
    }

    private static function normalizeStreamResponse(array $request, StreamResponse $response): array
    {
        $body = '';
        foreach ($response->chunks as $chunk) {
            $body .= (string) $chunk;
        }
        $headers = self::normalizeHeaders($response->headers);
        if (!isset($headers['content-type'])) {
            $headers['content-type'] = $response->contentType;
        }

        return [
            'id' => (string) ($request['id'] ?? ''),
            'status' => $response->status,
            'headers' => $headers,
            'body' => $body,
        ];
    }

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
            $key = strtolower((string) $name);
            $out[$key] = is_array($value) ? implode(', ', array_map('strval', $value)) : (string) $value;
        }

        return $out;
    }

    private static function errorResponse(Throwable $e): array
    {
        return [
            'id' => '',
            'status' => 500,
            'headers' => [
                'content-type' => 'text/plain; charset=utf-8',
                'x-vhttpd-error-class' => $e::class,
            ],
            'body' => 'Worker Error: ' . $e->getMessage(),
        ];
    }
}
