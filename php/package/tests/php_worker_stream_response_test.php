<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/VHttpd/Wire/FrameCodec.php';
require_once __DIR__ . '/../src/VHttpd/PhpWorker/StreamResponse.php';
require_once __DIR__ . '/../src/VHttpd/PhpWorker/StreamApp.php';
require_once __DIR__ . '/../src/VHttpd/PhpWorker/Server.php';

use VHttpd\PhpWorker\Server;
use VHttpd\Wire\FrameCodec;

if (!function_exists('pcntl_fork') || !extension_loaded('sockets')) {
    fwrite(STDERR, "skip: pcntl and sockets extensions are required\n");
    exit(0);
}

$socket = '/tmp/vhttpd-php-worker-stream-' . getmypid() . '.sock';
$appFile = '/tmp/vhttpd-php-worker-stream-app-' . getmypid() . '.php';
@unlink($socket);

file_put_contents($appFile, <<<'PHP'
<?php
use VHttpd\PhpWorker\StreamResponse;

return static function (array $request): StreamResponse {
    return StreamResponse::text((static function (): iterable {
        yield "he";
        yield "llo";
    })(), 200, 'text/plain; charset=utf-8', ['x-test' => 'stream']);
};
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

$conn = @stream_socket_client('unix://' . $socket, $errno, $errstr, 1.0);
if (!is_resource($conn)) {
    pcntl_waitpid($pid, $status, WNOHANG);
    fwrite(STDERR, "connect failed: {$errstr} ({$errno})\n");
    exit(1);
}

FrameCodec::write($conn, json_encode([
    'id' => 'stream-1',
    'method' => 'GET',
    'path' => '/download',
], JSON_THROW_ON_ERROR));

$start = json_decode(FrameCodec::read($conn), true);
$chunk1 = json_decode(FrameCodec::read($conn), true);
$chunk2 = json_decode(FrameCodec::read($conn), true);
$end = json_decode(FrameCodec::read($conn), true);
fclose($conn);

posix_kill($pid, SIGTERM);
pcntl_waitpid($pid, $status);
@unlink($socket);
@unlink($appFile);

assertSame('stream', $start['mode'] ?? null, 'start mode');
assertSame('start', $start['event'] ?? null, 'start event');
assertSame(200, $start['status'] ?? null, 'start status');
assertSame('text', $start['stream_type'] ?? null, 'start stream_type');
assertSame('stream', $start['headers']['x-test'] ?? null, 'start header');
assertSame('chunk', $chunk1['event'] ?? null, 'chunk1 event');
assertSame(base64_encode('he'), $chunk1['data_base64'] ?? null, 'chunk1 data');
assertSame('chunk', $chunk2['event'] ?? null, 'chunk2 event');
assertSame(base64_encode('llo'), $chunk2['data_base64'] ?? null, 'chunk2 data');
assertSame('end', $end['event'] ?? null, 'end event');

echo "ok\n";

function assertSame(mixed $expected, mixed $actual, string $label): void
{
    if ($expected !== $actual) {
        fwrite(STDERR, $label . " failed\nexpected: " . var_export($expected, true) . "\nactual: " . var_export($actual, true) . "\n");
        exit(1);
    }
}
