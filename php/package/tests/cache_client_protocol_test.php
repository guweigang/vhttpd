<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/VHttpd/Wire/FrameCodec.php';
require_once __DIR__ . '/../src/VHttpd/Wire/JsonClient.php';
require_once __DIR__ . '/../src/VHttpd/Cache/Client.php';

use VHttpd\Cache\Client;

$socket = dirname(__DIR__, 3) . '/tmp/vcache-' . getmypid() . '.sock';
@mkdir(dirname($socket), 0777, true);
@unlink($socket);

$pid = pcntl_fork();
if ($pid === -1) {
    fwrite(STDERR, "fork failed\n");
    exit(1);
}

if ($pid === 0) {
    $server = stream_socket_server('unix://' . $socket, $errno, $errstr);
    if (!is_resource($server)) {
        exit(2);
    }

    $ok = true;
    for ($i = 0; $i < 2; $i++) {
        $conn = @stream_socket_accept($server, 5);
        if (!is_resource($conn)) {
            exit(3);
        }
        $raw = VHttpd\Wire\FrameCodec::read($conn);
        $request = json_decode($raw, true);
        if ($i === 0) {
            $ok = $ok
                && is_array($request)
                && $request['mode'] === 'cache'
                && $request['op'] === 'set'
                && $request['namespace'] === 'wp'
                && $request['key'] === 'hello'
                && $request['value'] === 'world'
                && $request['ttl_ms'] === 250;
            VHttpd\Wire\FrameCodec::write($conn, json_encode(['ok' => $ok], JSON_UNESCAPED_UNICODE));
        } else {
            $ok = $ok
                && is_array($request)
                && $request['mode'] === 'cache'
                && $request['op'] === 'keys'
                && $request['namespace'] === 'wp'
                && $request['key'] === '';
            VHttpd\Wire\FrameCodec::write($conn, json_encode([
                'ok' => $ok,
                'found' => true,
                'keys' => ['hello', 'other'],
            ], JSON_UNESCAPED_UNICODE));
        }
        fclose($conn);
    }
    fclose($server);
    exit($ok ? 0 : 4);
}

for ($i = 0; $i < 50 && !file_exists($socket); $i++) {
    usleep(10_000);
}

$client = new Client($socket, 'wp');
$client->set('hello', 'world', 250);
$keys = $client->keys();
pcntl_waitpid($pid, $status);
@unlink($socket);

if (!pcntl_wifexited($status) || pcntl_wexitstatus($status) !== 0 || $keys !== ['hello', 'other']) {
    fwrite(STDERR, "cache client protocol test failed: keys=" . json_encode($keys) . "\n");
    exit(1);
}

echo "OK\n";
