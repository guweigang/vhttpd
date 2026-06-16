<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/VHttpd/Wire/FrameCodec.php';
require_once __DIR__ . '/../src/VHttpd/Wire/JsonClient.php';
require_once __DIR__ . '/../src/VHttpd/DbGateway/Client.php';
require_once __DIR__ . '/../src/VHttpd/DbGateway/PDOStatement.php';
require_once __DIR__ . '/../src/VHttpd/DbGateway/PDO.php';

use VHttpd\Wire\FrameCodec;
use VHttpd\DbGateway\PDO;

if (!function_exists('pcntl_fork') || !extension_loaded('sockets')) {
    fwrite(STDERR, "skip: pcntl and sockets extensions are required\n");
    exit(0);
}

$socket = '/tmp/vhttpd-db-gateway-' . getmypid() . '.sock';
@unlink($socket);

$pid = pcntl_fork();
if ($pid === -1) {
    fwrite(STDERR, "failed to fork\n");
    exit(1);
}

if ($pid === 0) {
    $server = socket_create(AF_UNIX, SOCK_STREAM, 0);
    if (!$server) {
        fwrite(STDERR, "server socket_create failed\n");
        exit(1);
    }
    if (!@socket_bind($server, $socket) || !@socket_listen($server)) {
        fwrite(STDERR, "server bind/listen failed: " . socket_strerror(socket_last_error($server)) . "\n");
        socket_close($server);
        exit(1);
    }

    $expected = ['query', 'begin_transaction', 'execute', 'commit'];
    foreach ($expected as $op) {
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

        $raw = FrameCodec::read($conn);
        $request = json_decode($raw, true);
        assertSame('db', $request['mode'] ?? null, 'mode');
        assertSame($op, $request['op'] ?? null, 'op');
        assertSame('default', $request['pool'] ?? null, 'pool');

        if ($op === 'query') {
            assertSame('SELECT id FROM users WHERE id = ?', $request['sql'] ?? null, 'query sql');
            assertSame(['123'], $request['params'] ?? null, 'query params');
            $response = ['ok' => true, 'driver' => 'mysql', 'rows' => [['id' => '123']], 'affected_rows' => 0, 'last_insert_id' => 0, 'session_id' => ''];
        } elseif ($op === 'begin_transaction') {
            $response = ['ok' => true, 'driver' => 'mysql', 'session_id' => 'tx_1'];
        } elseif ($op === 'execute') {
            assertSame('tx_1', $request['session_id'] ?? null, 'execute session');
            assertSame('UPDATE users SET name = ? WHERE id = ?', $request['sql'] ?? null, 'execute sql');
            assertSame(['Ada', '123'], $request['params'] ?? null, 'execute params');
            $response = ['ok' => true, 'driver' => 'mysql', 'affected_rows' => 1, 'last_insert_id' => 0, 'session_id' => 'tx_1'];
        } else {
            assertSame('tx_1', $request['session_id'] ?? null, 'commit session');
            $response = ['ok' => true, 'driver' => 'mysql'];
        }

        FrameCodec::write($conn, json_encode($response, JSON_THROW_ON_ERROR));
        fclose($conn);
    }

    socket_close($server);
    @unlink($socket);
    exit(0);
}

for ($i = 0; $i < 50 && !file_exists($socket); ++$i) {
    usleep(20_000);
}

$db = new PDO($socket);
$stmt = $db->query('SELECT id FROM users WHERE id = ?', [123]);
assertSame(['id' => '123'], $stmt->fetch(), 'fetch row');

$db->beginTransaction();
assertSame(1, $db->execute('UPDATE users SET name = ? WHERE id = ?', ['Ada', 123]), 'affected rows');
$db->commit();

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
