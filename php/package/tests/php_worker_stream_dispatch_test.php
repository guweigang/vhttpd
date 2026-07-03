<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/VHttpd/Wire/FrameCodec.php';
require_once __DIR__ . '/../src/VHttpd/PhpWorker/StreamApp.php';
require_once __DIR__ . '/../src/VHttpd/PhpWorker/Server.php';

use VHttpd\PhpWorker\Server;
use VHttpd\Wire\FrameCodec;

if (!function_exists('pcntl_fork') || !extension_loaded('sockets')) {
    fwrite(STDERR, "skip: pcntl and sockets extensions are required\n");
    exit(0);
}

$socket = '/tmp/vhttpd-php-worker-dispatch-' . getmypid() . '.sock';
$appFile = '/tmp/vhttpd-php-worker-dispatch-app-' . getmypid() . '.php';
@unlink($socket);

file_put_contents($appFile, <<<'PHP'
<?php
use VHttpd\PhpWorker\StreamApp;

$stream = StreamApp::fromSequence('sse', [
    ['event' => 'tick', 'data' => 'one'],
    ['event' => 'done', 'data' => 'complete'],
], 200, 'text/event-stream', ['x-stream-source' => 'dispatch']);

return [
    'http' => static function (array $request): array {
        return [
            'status' => 200,
            'headers' => ['content-type' => 'application/json; charset=utf-8'],
            'body' => json_encode(['path' => $request['path'] ?? ''], JSON_THROW_ON_ERROR),
        ];
    },
    'stream' => static fn (array $frame): array => $stream->handle($frame),
];
PHP);

$pid = pcntl_fork();
if ($pid === -1) {
    fwrite(STDERR, "failed to fork\n");
    exit(1);
}

if ($pid === 0) {
    try {
        (new Server($socket, $appFile))->run();
    } catch (Throwable $e) {
        fwrite(STDERR, $e->getMessage() . "\n");
        exit(1);
    }
    exit(0);
}

for ($i = 0; $i < 100 && !file_exists($socket); ++$i) {
    usleep(20_000);
}

$conn = connect($socket);
FrameCodec::write($conn, json_encode([
    'id' => 'http-1',
    'method' => 'GET',
    'path' => '/meta',
], JSON_THROW_ON_ERROR));
$http = json_decode(FrameCodec::read($conn), true);
fclose($conn);

$conn = connect($socket);
FrameCodec::write($conn, json_encode([
    'mode' => 'stream',
    'strategy' => 'dispatch',
    'event' => 'open',
    'id' => 'dispatch-1',
    'method' => 'GET',
    'path' => '/events/sse',
], JSON_THROW_ON_ERROR));
$open = json_decode(FrameCodec::read($conn), true);
fclose($conn);

$conn = connect($socket);
FrameCodec::write($conn, json_encode([
    'mode' => 'stream',
    'strategy' => 'dispatch',
    'event' => 'next',
    'id' => 'dispatch-1',
    'method' => 'GET',
    'path' => '/events/sse',
    'state' => $open['state'] ?? [],
], JSON_THROW_ON_ERROR));
$next = json_decode(FrameCodec::read($conn), true);
fclose($conn);

$conn = connect($socket);
FrameCodec::write($conn, json_encode([
    'mode' => 'stream',
    'strategy' => 'dispatch',
    'event' => 'close',
    'id' => 'dispatch-1',
    'state' => $next['state'] ?? [],
], JSON_THROW_ON_ERROR));
$close = json_decode(FrameCodec::read($conn), true);
fclose($conn);

posix_kill($pid, SIGTERM);
pcntl_waitpid($pid, $status);
@unlink($socket);
@unlink($appFile);

assertSame(200, $http['status'] ?? null, 'http status');
assertSame('{"path":"\/meta"}', $http['body'] ?? null, 'http body');
assertSame(true, $open['handled'] ?? null, 'open handled');
assertSame(false, $open['done'] ?? null, 'open done');
assertSame('sse', $open['stream_type'] ?? null, 'open stream type');
assertSame('dispatch', $open['headers']['x-stream-source'] ?? null, 'open header');
assertSame('tick', $open['chunks'][0]['event'] ?? null, 'open first event');
assertSame('one', $open['chunks'][0]['data'] ?? null, 'open first data');
assertSame(true, $next['done'] ?? null, 'next done');
assertSame('done', $next['chunks'][0]['event'] ?? null, 'next event');
assertSame('complete', $next['chunks'][0]['data'] ?? null, 'next data');
assertSame(true, $close['done'] ?? null, 'close done');

echo "ok\n";

function connect(string $socket)
{
    $conn = @stream_socket_client('unix://' . $socket, $errno, $errstr, 1.0);
    if (!is_resource($conn)) {
        fwrite(STDERR, "connect failed: {$errstr} ({$errno})\n");
        exit(1);
    }
    return $conn;
}

function assertSame(mixed $expected, mixed $actual, string $label): void
{
    if ($expected !== $actual) {
        fwrite(STDERR, $label . " failed\nexpected: " . var_export($expected, true) . "\nactual: " . var_export($actual, true) . "\n");
        exit(1);
    }
}
