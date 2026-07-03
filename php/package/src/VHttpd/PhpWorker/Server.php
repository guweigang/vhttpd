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
    private readonly int $parentPid;

    public function __construct(
        private readonly string $socketPath,
        private readonly string $defaultApp,
    ) {
        $parentPid = getenv('VHTTPD_PARENT_PID');
        $this->parentPid = is_string($parentPid) && ctype_digit($parentPid) ? (int) $parentPid : 0;

        $appPath = getenv('VHTTPD_APP');
        if (!is_string($appPath) || $appPath === '') {
            $appPath = $this->defaultApp;
        }
        if (!is_file($appPath)) {
            throw new \RuntimeException('vhttpd app entry not found: ' . $appPath);
        }

        $app = self::normalizeApp(require $appPath);
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
        socket_set_nonblock($server);

        while (!$this->parentProcessExited()) {
            $conn = @socket_accept($server);
            if (!$conn) {
                if (self::isWouldBlock(socket_last_error($server))) {
                    socket_clear_error($server);
                    usleep(200_000);
                    continue;
                }
                continue;
            }
            socket_set_block($conn);
            $this->handleConnection($conn);
            socket_close($conn);
        }
        socket_close($server);
        if (file_exists($this->socketPath) || is_link($this->socketPath)) {
            @unlink($this->socketPath);
        }
    }

    private function parentProcessExited(): bool
    {
        if ($this->parentPid <= 0 || !function_exists('posix_kill')) {
            return false;
        }

        return !@posix_kill($this->parentPid, 0);
    }

    private static function isWouldBlock(int $error): bool
    {
        $wouldBlock = [];
        foreach (['SOCKET_EAGAIN', 'SOCKET_EWOULDBLOCK'] as $constant) {
            if (defined($constant)) {
                $wouldBlock[] = constant($constant);
            }
        }

        return $error === 0 || in_array($error, $wouldBlock, true);
    }

    private static function normalizeApp(mixed $app): mixed
    {
        if (is_callable($app)) {
            return $app;
        }
        if (!is_array($app)) {
            return $app;
        }

        $http = $app['http'] ?? null;
        $stream = $app['stream'] ?? null;
        if (!is_callable($http) && !is_callable($stream)) {
            return $app;
        }

        return static function (array $payload, array $envelope = []) use ($http, $stream): mixed {
            $mode = (string) ($payload['mode'] ?? '');
            if ($mode === 'stream' && is_callable($stream)) {
                return $stream($payload);
            }
            if (is_callable($http)) {
                return $http($payload, $envelope);
            }

            return [
                'mode' => 'stream',
                'strategy' => 'dispatch',
                'event' => 'open',
                'id' => (string) ($payload['id'] ?? ''),
                'handled' => false,
                'done' => true,
                'stream_type' => 'sse',
                'content_type' => 'text/event-stream',
                'headers' => [],
                'state' => [],
                'chunks' => [],
            ];
        };
    }

    /**
     * @param \Socket $conn
     */
    private function handleConnection($conn): void
    {
        $payload = [];
        try {
            $raw = self::readFrame($conn);
            $payload = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
            if (!is_array($payload)) {
                throw new \RuntimeException('worker payload must be a JSON object');
            }

            $result = ($this->app)($payload, $payload);
            if ($result instanceof StreamResponse) {
                self::writeStreamResponse($conn, $payload, $result);
                return;
            }
            if (($payload['mode'] ?? '') === 'stream') {
                self::writeFrame($conn, json_encode(self::normalizeStreamDispatchResponse($payload, $result), JSON_THROW_ON_ERROR));
                return;
            }
            self::writeFrame($conn, json_encode(self::normalizeResponse($payload, $result), JSON_THROW_ON_ERROR));
        } catch (Throwable $e) {
            if (str_contains($e->getMessage(), 'unexpected EOF')) {
                return;
            }
            try {
                if (($payload['mode'] ?? '') === 'stream') {
                    self::writeFrame($conn, json_encode(self::streamErrorResponse($payload, $e), JSON_THROW_ON_ERROR));
                    return;
                }
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
        if ($result instanceof Response) {
            $payload = $result->toArray();
            if ((string) ($payload['id'] ?? '') === '') {
                $payload['id'] = (string) ($request['id'] ?? '');
            }
            return $payload;
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

    private static function normalizeStreamDispatchResponse(array $request, mixed $result): array
    {
        if (!is_array($result)) {
            $result = [];
        }

        return [
            'mode' => 'stream',
            'strategy' => (string) ($result['strategy'] ?? $request['strategy'] ?? 'dispatch'),
            'event' => (string) ($result['event'] ?? $request['event'] ?? ''),
            'id' => (string) ($result['id'] ?? $request['id'] ?? ''),
            'handled' => (bool) ($result['handled'] ?? false),
            'done' => (bool) ($result['done'] ?? true),
            'stream_type' => (string) ($result['stream_type'] ?? 'sse'),
            'content_type' => (string) ($result['content_type'] ?? 'text/event-stream'),
            'headers' => self::normalizeHeaders($result['headers'] ?? []),
            'state' => self::normalizeStringMap($result['state'] ?? []),
            'chunks' => self::normalizeStreamChunks($result['chunks'] ?? []),
            'error' => (string) ($result['error'] ?? ''),
            'error_class' => (string) ($result['error_class'] ?? ''),
        ];
    }

    private static function normalizeStreamChunks(mixed $chunks): array
    {
        if (!is_array($chunks)) {
            return [];
        }

        $out = [];
        foreach ($chunks as $chunk) {
            if (!is_array($chunk)) {
                $chunk = ['data' => (string) $chunk];
            }
            $retry = $chunk['retry'] ?? 0;
            $out[] = [
                'event' => (string) ($chunk['event'] ?? ''),
                'id' => (string) ($chunk['id'] ?? ''),
                'data' => (string) ($chunk['data'] ?? ''),
                'retry' => is_numeric($retry) ? (int) $retry : 0,
            ];
        }

        return $out;
    }

    private static function normalizeStringMap(mixed $value): array
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

    /**
     * @param \Socket $conn
     * @param array<string,mixed> $request
     */
    private static function writeStreamResponse($conn, array $request, StreamResponse $response): void
    {
        $headers = self::normalizeHeaders($response->headers);
        if (!isset($headers['content-type'])) {
            $headers['content-type'] = $response->contentType;
        }

        self::writeJsonFrame($conn, [
            'id' => (string) ($request['id'] ?? ''),
            'mode' => 'stream',
            'event' => 'start',
            'status' => $response->status,
            'stream_type' => $response->streamType,
            'content_type' => $response->contentType,
            'headers' => $headers,
        ]);

        foreach ($response->chunks as $chunk) {
            self::writeJsonFrame($conn, self::streamChunkFrame($request, $response, $chunk));
        }

        self::writeJsonFrame($conn, [
            'id' => (string) ($request['id'] ?? ''),
            'mode' => 'stream',
            'event' => 'end',
            'stream_type' => $response->streamType,
        ]);
    }

    /**
     * @param array<string,mixed> $request
     * @return array<string,mixed>
     */
    private static function streamChunkFrame(array $request, StreamResponse $response, mixed $chunk): array
    {
        $frame = [
            'id' => (string) ($request['id'] ?? ''),
            'mode' => 'stream',
            'event' => 'chunk',
            'stream_type' => $response->streamType,
        ];

        if ($response->streamType === 'sse') {
            if (is_array($chunk)) {
                $frame['data'] = (string) ($chunk['data'] ?? '');
                $frame['sse_id'] = (string) ($chunk['id'] ?? $chunk['sse_id'] ?? '');
                $frame['sse_event'] = (string) ($chunk['event'] ?? $chunk['sse_event'] ?? '');
                $retry = $chunk['retry'] ?? $chunk['sse_retry'] ?? 0;
                $frame['sse_retry'] = is_numeric($retry) ? (int) $retry : 0;
                return $frame;
            }
            $frame['data'] = (string) $chunk;
            return $frame;
        }

        $frame['data_base64'] = base64_encode((string) $chunk);
        return $frame;
    }

    /**
     * @param \Socket $conn
     * @param array<string,mixed> $payload
     */
    private static function writeJsonFrame($conn, array $payload): void
    {
        self::writeFrame($conn, json_encode($payload, JSON_THROW_ON_ERROR));
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

    private static function streamErrorResponse(array $request, Throwable $e): array
    {
        return [
            'mode' => 'stream',
            'strategy' => (string) ($request['strategy'] ?? 'dispatch'),
            'event' => 'error',
            'id' => (string) ($request['id'] ?? ''),
            'handled' => true,
            'done' => true,
            'stream_type' => 'sse',
            'content_type' => 'text/event-stream',
            'headers' => [],
            'state' => [],
            'chunks' => [],
            'error' => $e->getMessage(),
            'error_class' => $e::class,
        ];
    }
}
