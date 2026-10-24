<?php
declare(strict_types=1);

$root = dirname(__DIR__, 2);
foreach (['Db.php', 'Repository/StreamRepository.php', 'Repository/TaskRepository.php', 'Service/TaskStateService.php', 'Upstream/ProviderEventRouter.php'] as $file) {
    require_once $root . '/examples/codexbot-app/lib/' . $file;
}
function check(bool $condition, string $why = 'generation receipt regression'): void {
    if (!$condition) throw new RuntimeException($why);
}
$path = tempnam(sys_get_temp_dir(), 'vhttpd_wire_generation_');
$previous = getenv('VHTTPD_BOT_DB_PATH');
putenv('VHTTPD_BOT_DB_PATH=' . $path);
try {
    $db = CodexBot\Db::getConnection();
    $db->exec("INSERT INTO projects (project_key,name,repo_path,created_at,updated_at) VALUES ('project','project','/tmp','now','now')");
    $repo = new CodexBot\Repository\StreamRepository();
    $tasks = new CodexBot\Repository\TaskRepository();
    $state = new CodexBot\Service\TaskStateService($tasks, $repo);
    $reflection = new ReflectionClass(CodexBot\Upstream\ProviderEventRouter::class);
    $router = $reflection->newInstanceWithoutConstructor();
    $reflection->getProperty('streamRepo')->setValue($router, $repo);
    $make = function (string $id) use ($db, $repo): array {
        $stmt = $db->prepare("INSERT INTO tasks (task_id,project_key,platform,channel_id,stream_id,task_type,prompt,status,created_at,updated_at) VALUES (?,'project','feishu','chat',?,'task','prompt','queued','now','now')");
        $stmt->execute([$id, $id]);
        $publication = bin2hex(random_bytes(32));
        $repo->create(['stream_id' => $id, 'task_id' => $id, 'platform' => 'feishu', 'channel_id' => 'chat', 'stream_generation' => 'issued-' . $id, 'stream_publication_id' => $publication]);
        return ['stream_id' => $id, 'message_id' => 'message', 'stream_generation' => 'issued-' . $id, 'instance' => 'main', 'publication_id' => $publication, 'publication_sequence' => 1];
    };
    $deliver = fn (array $receipt, string $provider = 'feishu', array $request = []) => $router->dispatch($provider, 'feishu.message.sent', $receipt, $request);
    $unchanged = function (array $before, string $why) use ($repo): void { check($repo->findByStreamId($before['stream_id']) === $before, $why); };
    $first = $make('stream');
    $before = $repo->findByStreamId('stream');
    foreach (['stream_id', 'message_id', 'stream_generation', 'instance', 'publication_id', 'publication_sequence'] as $field) {
        $invalid = $first; unset($invalid[$field]); $deliver($invalid, 'feishu', ['trace_id' => 'stream']);
        $unchanged($before, 'missing ' . $field . ' acquired authority');
    }
    foreach (['0', 0, -1, 1.5, true, null, [], PHP_INT_MAX . '0'] as $sequence) {
        $deliver(array_replace($first, ['publication_sequence' => $sequence]));
        $unchanged($before, 'malformed sequence acquired authority');
    }
    foreach (['instance' => 'other', 'publication_id' => str_repeat('f', 64)] as $field => $value) {
        $deliver(array_replace($first, [$field => $value])); $unchanged($before, 'wrong scope acquired authority');
    }
    $deliver($first, 'codex'); $unchanged($before, 'other provider acquired authority');
    $deliver($first);
    check($repo->findMessageIdByStreamId('stream') === 'message');
    $packet = json_encode(['metadata' => ['stream_generation' => $tasks->resolveStreamContext('stream')['stream_generation']]]);
    $deliver(array_replace($first, ['message_id' => 'segment-3', 'publication_sequence' => 3]));
    $latest = $repo->findByStreamId('stream');
    foreach ([1, 2, 3] as $seq) {
        $deliver(array_replace($first, ['message_id' => 'late-' . $seq, 'publication_sequence' => $seq]));
        $unchanged($latest, 'reordered or duplicate segment rolled binding back');
    }
    $deliver(array_replace($first, ['stream_generation' => 'wrong', 'publication_sequence' => 4]));
    $unchanged($latest, 'same publication changed confirmed generation');
    $pending = $repo->prepareBindingPublication('stream', 'segment-3', $first['stream_generation'], $first['publication_id']);
    check(is_array($pending));
    check($repo->prepareBindingPublication('stream', 'segment-3', $first['stream_generation'], $first['publication_id']) === null, 'stale reservation displaced newer pending rebind');
    $waiting = $repo->findByStreamId('stream');
    $deliver(array_replace($first, ['publication_sequence' => 100]));
    $unchanged($waiting, 'old receipt completed new pending rebind');
    $rebound = array_replace($first, ['message_id' => 'same-physical-id', 'stream_generation' => 'bound-generation', 'publication_id' => $pending['publication_id'], 'publication_sequence' => 1]);
    $deliver($rebound);
    $current = $repo->findByStreamId('stream');
    check($current['stream_generation'] === 'bound-generation' && $current['response_message_id'] === 'same-physical-id');
    $deliver($first); $unchanged($current, 'initial receipt replaced rebind');
    check(json_decode($packet, true)['metadata']['stream_generation'] === $first['stream_generation']);
    // A second real PDO/SQLite connection delivers an already queued receipt.
    $other = new CodexBot\Repository\StreamRepository();
    $reflectionRepo = new ReflectionClass($other);
    $otherDb = new PDO('sqlite:' . $path); $otherDb->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $reflectionRepo->getProperty('db')->setValue($other, $otherDb);
    $state->markCancelled('stream', 'stream');
    $cancelled = $repo->findByStreamId('stream');
    check(!$other->acceptSentReceipt(array_replace($rebound, ['publication_sequence' => 2])));
    $unchanged($cancelled, 'cancelled resource restored');
    check($cancelled['stream_publication_id'] === '');
    check($repo->prepareBindingPublication('stream', 'same-physical-id', 'bound-generation', $pending['publication_id']) === null);
    $repo->updateStatus('stream', 'opened'); // reopening a row must not restore withdrawn authority
    $reopened = $repo->findByStreamId('stream');
    $deliver(array_replace($rebound, ['publication_sequence' => 999])); $unchanged($reopened, 'reopened row regained old publication');
    foreach (['cancelled', 'failed', 'completed'] as $terminal) {
        $r = $make('before-' . $terminal);
        $repo->updateStatus($r['stream_id'], $terminal);
        $closed = $repo->findByStreamId($r['stream_id']);
        $deliver($r); $unchanged($closed, 'late first receipt restored terminal stream');
    }
    $taskOnly = $make('task-only');
    $tasks->updateStatus('task-only', 'cancelled');
    $closed = $repo->findByStreamId('task-only'); $deliver($taskOnly); $unchanged($closed, 'task cancellation window admitted receipt');
    $deleted = $make('deleted');
    $db->exec("DELETE FROM streams WHERE stream_id = 'deleted'");
    $deliver($deleted); check($repo->findByStreamId('deleted') === null, 'receipt recreated deleted row');
    $early = $make('early-segment');
    $deliver(array_replace($early, ['message_id' => 'segment-2', 'publication_sequence' => 2]));
    $saved = $repo->findByStreamId('early-segment'); $deliver($early); $unchanged($saved, 'initial receipt overwrote earlier delivered successor');
    $router->dispatch('feishu', 'feishu.message.updated', array_replace($early, ['message_id' => 'old']), []);
    $unchanged($saved, 'updated event acquired authority');
    if (isset($argv[1])) {
        $wire = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
        check(count($wire) === 3, 'missing real V receipt chain');
        $make('wire');
        $stmt = $db->prepare('UPDATE streams SET stream_publication_id = ?, stream_generation = ? WHERE stream_id = ?');
        $stmt->execute([$wire[0]['publication_id'], 'issued-before-bind', 'wire']);
        $deliver($wire[0]);
        check($repo->findByStreamId('wire')['stream_generation'] === $wire[0]['stream_generation']);
        $pending = $repo->prepareBindingPublication('wire', $wire[0]['message_id'], $wire[0]['stream_generation'], $wire[0]['publication_id']);
        // Use the nonce captured by the actual V rebind command fixture.
        $stmt = $db->prepare('UPDATE streams SET stream_publication_id = ? WHERE stream_id = ? AND stream_publication_id = ?');
        $stmt->execute([$wire[1]['publication_id'], 'wire', $pending['publication_id']]);
        $deliver($wire[2]); // rollover can overtake the rebind receipt in the executor queue
        $savedWire = $repo->findByStreamId('wire');
        check($savedWire['response_message_id'] === 'successor' && $savedWire['stream_generation'] === $wire[1]['stream_generation']);
        $deliver($wire[1]); $deliver($wire[0]); $unchanged($savedWire, 'real V wire receipt rolled binding back');
        $state->markCancelled('wire', 'wire');
        $savedWire = $repo->findByStreamId('wire');
        foreach ($wire as $receipt) $deliver($receipt);
        $unchanged($savedWire, 'real V wire receipt restored revoked resource');
        echo "PASS: actual V sent receipt serialization to PHP SQLite CAS\n";
    }
    // A legacy row gains empty authority; migrating must never authorize an old packet.
    $legacy = $make('legacy');
    unset($other, $otherDb);
    foreach (['stream_generation', 'stream_publication_id', 'stream_receipt_sequence', 'stream_instance'] as $column) $db->exec('ALTER TABLE streams DROP COLUMN ' . $column);
    CodexBot\Db::resetConnectionForTests(); unset($db, $repo, $tasks, $router, $state);
    $db = CodexBot\Db::getConnection();
    $repo = new CodexBot\Repository\StreamRepository();
    $row = $repo->findByStreamId('legacy');
    check($row['stream_publication_id'] === '' && $row['stream_generation'] === '');
    check(!$repo->acceptSentReceipt($legacy));
    echo "PASS: PHP sent publication reservation/CAS, reordered segments, rebind, terminal withdrawal, deletion, two-connection SQLite and fail-closed migration\n";
} finally {
    CodexBot\Db::resetConnectionForTests(); unset($db, $repo, $other, $otherDb);
    foreach ([$path, $path . '-wal', $path . '-shm'] as $file) if (is_file($file)) unlink($file);
    putenv($previous === false ? 'VHTTPD_BOT_DB_PATH' : 'VHTTPD_BOT_DB_PATH=' . $previous);
}
