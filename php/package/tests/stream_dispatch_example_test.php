<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/VHttpd/PhpWorker/StreamApp.php';
require_once __DIR__ . '/../src/VSlim/Stream/Factory.php';

$app = require __DIR__ . '/../../../examples/stream-dispatch-app.php';
$stream = $app['stream'];

function frame(string $event, string $id): array
{
    return ['event' => $event, 'id' => $id, 'path' => '/events/sse'];
}

function collect(callable $stream, string $id): array
{
    $response = $stream(frame('open', $id));
    $chunks = $response['chunks'];
    for ($i = 0; !$response['done'] && $i < 10; $i++) {
        $response = $stream(frame('next', $id));
        $chunks = array_merge($chunks, $response['chunks']);
    }
    if (!$response['done']) {
        throw new RuntimeException('stream did not finish');
    }
    return array_column($chunks, 'data');
}

$expected = ['0', '1', '2', '3', '4', 'stream complete'];
foreach (['first', 'second'] as $id) {
    if (collect($stream, $id) !== $expected) {
        throw new RuntimeException('each completed connection must receive the whole stream');
    }
}

// A disconnected reader must not consume the sequence for its replacement.
$stream(frame('open', 'interrupted'));
$stream(frame('close', 'interrupted'));
if (collect($stream, 'reconnected') !== $expected) {
    throw new RuntimeException('reconnected stream must start from the first event');
}

// Concurrent connections must have independent iterators.
$first = $stream(frame('open', 'concurrent-a'));
$second = $stream(frame('open', 'concurrent-b'));
if (($first['chunks'][0]['data'] ?? null) !== '0'
    || ($second['chunks'][0]['data'] ?? null) !== '0') {
    throw new RuntimeException('concurrent streams must both start at zero');
}
$stream(frame('close', 'concurrent-a'));
$stream(frame('close', 'concurrent-b'));
echo "ok: stream dispatch reopen, reconnect and independent readers\n";
