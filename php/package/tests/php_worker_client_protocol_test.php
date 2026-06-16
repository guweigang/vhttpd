<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/VHttpd/Wire/FrameCodec.php';
require_once __DIR__ . '/../src/VHttpd/Wire/JsonClient.php';
require_once __DIR__ . '/../src/VHttpd/PhpWorker/Request.php';
require_once __DIR__ . '/../src/VHttpd/PhpWorker/Response.php';
require_once __DIR__ . '/../src/VHttpd/PhpWorker/Client.php';

use VHttpd\PhpWorker\Client;
use VHttpd\PhpWorker\Request;
use VHttpd\Wire\FrameCodec;

if (!function_exists('pcntl_fork') || !extension_loaded('sockets')) {
    fwrite(STDERR, "skip: pcntl and sockets extensions are required\n");
    exit(0);
}

$socket = '/tmp/vhttpd-php-worker-client-' . getmypid() . '.sock';
@unlink($socket);

$pid = pcntl_fork();
if ($pid === -1) {
    fwrite(STDERR, "failed to fork\n");
    exit(1);
}

if ($pid === 0) {
    $server = socket_create(AF_UNIX, SOCK_STREAM, 0);
    if (!$server || !@socket_bind($server, $socket) || !@socket_listen($server)) {
        fwrite(STDERR, "server bind/listen failed: " . socket_strerror(socket_last_error($server)) . "\n");
        if ($server) {
            socket_close($server);
        }
        exit(1);
    }

    $accepted = @socket_accept($server);
    if (!$accepted) {
        fwrite(STDERR, "accept failed: " . socket_strerror(socket_last_error($server)) . "\n");
        socket_close($server);
        exit(1);
    }

    $conn = socket_export_stream($accepted);
    if (!is_resource($conn)) {
        fwrite(STDERR, "socket_export_stream failed\n");
        socket_close($accepted);
        socket_close($server);
        exit(1);
    }

    $request = json_decode(FrameCodec::read($conn), true);
    assertSame('cli-1', $request['id'] ?? null, 'id');
    assertSame('GET', $request['method'] ?? null, 'method');
    assertSame('/health', $request['path'] ?? null, 'path');

    FrameCodec::write($conn, json_encode([
        'id' => 'cli-1',
        'status' => 200,
        'headers' => ['content-type' => 'text/plain'],
        'body' => 'ok',
    ], JSON_THROW_ON_ERROR));

    fclose($conn);
    socket_close($server);
    @unlink($socket);
    exit(0);
}

for ($i = 0; $i < 50 && !file_exists($socket); ++$i) {
    usleep(20_000);
}

$client = new Client($socket);
$request = Request::http('GET', '/health');
$response = $client->request($request);

assertSame(200, $response->status, 'status');
assertSame('ok', $response->body, 'body');

$status = null;
pcntl_waitpid($pid, $status);
@unlink($socket);

if (!pcntl_wifexited($status) || pcntl_wexitstatus($status) !== 0) {
    fwrite(STDERR, "child failed\n");
    exit(1);
}

echo "ok\n";

function assertSame(mixed $expected, mixed $actual, string $label): void
{
    if ($expected !== $actual) {
        fwrite(STDERR, $label . " failed\nexpected: " . var_export($expected, true) . "\nactual: " . var_export($actual, true) . "\n");
        exit(1);
    }
}
