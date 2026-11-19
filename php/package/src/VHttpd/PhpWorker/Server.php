<?php

declare(strict_types=1);

namespace VHttpd\PhpWorker;

use Throwable;
use VHttpd\Attribute\Dispatchable;
use VHttpd\PhpWorker\WebSocket\Connection;
use VHttpd\Upstream\Plan;
use VHttpd\Wire\FrameCodec;

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
    /** @var array<string,callable> */
    private array $handlers;
    private ?Connection $activeWebSocket = null;
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

        $this->handlers = self::normalizeApp(require $appPath);
        if ($this->handlers === []) {
            throw new \RuntimeException('vhttpd app entry must provide a worker handler');
        }
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
                    // Wake as soon as the next dispatch connection arrives, while
                    // retaining the bounded parent-liveness check during idle time.
                    $read = [$server];
                    $write = null;
                    $except = null;
                    @socket_select($read, $write, $except, 0, 200_000);
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

    /** @return array<string,callable> */
    private static function normalizeApp(mixed $app): array
    {
        $methods = [
            'http' => ['dispatchEnvelopeWorker'],
            'stream' => ['handleStream', 'handle_stream'],
            'mcp' => ['handleMcp', 'handle_mcp'],
            'websocket' => ['handleWebSocket', 'handle_websocket'],
            'websocket_upstream' => ['handleWebSocketUpstream', 'handle_websocket_upstream'],
        ];
        $handlers = [];
        if (is_object($app)) {
            $attributes = (new \ReflectionObject($app))->getAttributes(Dispatchable::class);
            foreach ($attributes as $attribute) {
                $kind = $attribute->newInstance()->kind;
                if (!isset($methods[$kind])) {
                    throw new \InvalidArgumentException('unknown worker dispatch kind: ' . $kind);
                }
                $handlers[$kind] = self::handler($app, [...$methods[$kind], 'handle'])
                    ?? throw new \InvalidArgumentException('missing worker handler for ' . $kind);
            }
            foreach ($methods as $kind => $names) {
                $handler = self::handler($app, $names);
                if ($handler !== null) {
                    $handlers[$kind] ??= $handler;
                }
            }
        }
        if (is_callable($app)) {
            $handlers['http'] ??= $app;
        } elseif (is_array($app)) {
            foreach ($methods as $kind => $names) {
                $candidate = $app[$kind] ?? null;
                $handler = is_callable($candidate)
                    ? $candidate
                    : self::handler($candidate, [...$names, 'handle']);
                if ($handler !== null) {
                    $handlers[$kind] = $handler;
                }
            }
        }
        if (isset($handlers['http'])) {
            $handlers['stream'] ??= $handlers['http'];
        }
        return $handlers;
    }

    private static function handler(mixed $app, array $methods): ?callable
    {
        foreach ($methods as $method) {
            if (is_object($app) && is_callable([$app, $method])) {
                $bound = $app->{$method}(...);
                $signature = new \ReflectionMethod($app, $method);
                if (!$signature->isVariadic() && $signature->getNumberOfParameters() === 1) {
                    return static fn (array $payload): mixed => $bound($payload);
                }
                return $bound;
            }
        }
        return null;
    }

    private function invoke(string $kind, array $payload, mixed $context): mixed
    {
        if (!isset($this->handlers[$kind])) {
            return null;
        }
        $handler = $this->handlers[$kind];
        return in_array($kind, ['http', 'websocket', 'stream'], true) ? $handler($payload, $context) : $handler($payload);
    }

    public function dispatchRequest(array $request): array
    {
        $mode = (string) ($request['mode'] ?? '');
        if ($mode === 'websocket_dispatch') {
            $conn = $this->dispatchWebSocket($request);
            return [
                'mode' => $mode,
                'event' => 'result',
                'id' => (string) ($request['id'] ?? ''),
                'accepted' => $conn->accepted(),
                'closed' => $conn->closed(),
                'commands' => $conn->frames(),
            ];
        }
        if ($mode === 'mcp' || $mode === 'websocket_upstream') {
            $result = $this->invoke($mode, $request, $request);
            if ($result !== null && !is_array($result)) {
                throw new \UnexpectedValueException($mode . ' worker result must be an array');
            }
            return [
                'mode' => $mode,
                'event' => 'result',
                'id' => (string) ($request['id'] ?? ''),
            ] + ($result ?? ['handled' => false, 'commands' => []]);
        }
        if ($mode === 'stream') {
            return self::normalizeStreamDispatchResponse($request, $this->invoke('stream', $request, $request));
        }
        return self::normalizeResponse($request, $this->invoke('http', $request, $request));
    }

    private function dispatchWebSocket(array $request): Connection
    {
        $conn = new Connection(null, (string) ($request['id'] ?? ''),
            fn (): ?Connection => $this->activeWebSocket);
        $open = ($request['event'] ?? '') === 'open';
        if (!isset($this->handlers['websocket'])) {
            if ($open) {
                $conn->reject(404, 'WebSocket handler not found');
            }
            return $conn;
        }
        // Native apps can retain the connection from the open event for room
        // broadcasts. Route those sends through the current dispatch.
        $this->activeWebSocket = $conn;
        try {
            $result = $this->invoke('websocket', $request, $conn);
            if ($open && $result === false) {
                $conn->reject();
            } elseif ($open && !$conn->rejected() && !$conn->closed()) {
                $conn->accept();
            }
            if (is_string($result) && !$conn->rejected() && !$conn->closed()) {
                $conn->send($result);
            }
        } finally {
            $this->activeWebSocket = null;
        }
        return $conn;
    }

    /** @param \Socket|resource $conn */
    private function handleWebSocketFrame($conn, array $request): void
    {
        $dispatch = $this->dispatchWebSocket($request);
        $frames = $dispatch->frames();
        // A handler can queue commands during open before deciding to accept.
        // Emit the handshake decision before delivering its commands.
        if (($request['event'] ?? '') === 'open') {
            $handshake = array_filter($frames, static fn (array $frame): bool =>
                in_array($frame['event'], ['accept', 'reject'], true));
            $frames = array_merge($handshake, array_diff_key($frames, $handshake));
        }
        $frames[] = ['mode' => 'websocket', 'event' => 'done', 'id' => (string) ($request['id'] ?? '')];
        foreach ($frames as $frame) {
            $raw = json_encode($frame, JSON_THROW_ON_ERROR);
            if (is_resource($conn)) {
                FrameCodec::write($conn, $raw);
            } else {
                self::writeFrame($conn, $raw);
            }
        }
    }

    /** @param \Socket $conn */
    private function handleConnection($conn): void
    {
        $payload = [];
        try {
            do {
                $payload = json_decode(self::readFrame($conn), true, 512, JSON_THROW_ON_ERROR);
                if (!is_array($payload)) {
                    throw new \RuntimeException('worker payload must be a JSON object');
                }
                $mode = $payload['mode'] ?? '';
                if ($mode === 'websocket') {
                    $this->handleWebSocketFrame($conn, $payload);
                }
            } while ($mode === 'websocket' && ($payload['event'] ?? '') !== 'close');
            if ($mode === 'websocket') {
                return;
            }

            if (in_array($mode, ['mcp', 'websocket_dispatch', 'websocket_upstream'], true)) {
                self::writeJsonFrame($conn, $this->dispatchRequest($payload));
                return;
            }
            $result = $this->invoke($mode === 'stream' ? 'stream' : 'http', $payload, $payload);
            if ($result instanceof Plan) {
                self::writeJsonFrame($conn, $result->frame((string) ($payload['id'] ?? '')));
                return;
            }
            if ($result instanceof \VSlim\Stream\Response) {
                $result = new StreamResponse($result->chunks(), $result->status, $result->headers(),
                    $result->streamType, $result->contentType);
            }
            if ($result instanceof StreamResponse) {
                self::writeStreamResponse($conn, $payload, $result);
                return;
            }
            $response = $mode === 'stream'
                ? self::normalizeStreamDispatchResponse($payload, $result)
                : self::normalizeResponse($payload, $result);
            self::writeJsonFrame($conn, $response);
        } catch (Throwable $e) {
            if (str_contains($e->getMessage(), 'unexpected EOF')) {
                return;
            }
            try {
                $mode = $payload['mode'] ?? '';
                if ($mode === 'stream') {
                    self::writeJsonFrame($conn, self::streamErrorResponse($payload, $e));
                } elseif (in_array($mode, ['mcp', 'websocket_dispatch', 'websocket_upstream'], true)) {
                    self::writeJsonFrame($conn, [
                        'mode' => $mode,
                        'event' => 'error',
                        'id' => (string) ($payload['id'] ?? ''),
                        'handled' => true,
                        'status' => 500,
                        'error' => $e->getMessage(),
                        'error_class' => $e::class,
                    ]);
                } else {
                    self::writeJsonFrame($conn, self::errorResponse($e));
                }
            } catch (Throwable) {
                return;
            }
        }
    }

    /** @param \Socket $conn */
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
        if ($result instanceof \VSlim\VHttpd\Response) {
            $result = ['status' => $result->status, 'content_type' => $result->contentType,
                'headers' => $result->headers(), 'body' => $result->body];
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
