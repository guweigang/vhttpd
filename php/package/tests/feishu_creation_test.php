<?php
declare(strict_types=1);
require __DIR__ . '/../src/VHttpd/Feishu/CreationLease.php';
require __DIR__ . '/../src/VHttpd/Feishu/CreationClient.php';
use VHttpd\Feishu\CreationClient;
use VHttpd\Feishu\CreationLease;
function check(bool $value): void { if (!$value) throw new RuntimeException('Assertion failed'); }
function rejects(callable $f): void { try { $f(); } catch (Throwable) { return; } throw new RuntimeException('Expected rejection'); }
$calls = [];
$client = new CreationClient('http://127.0.0.1:19981', 'secret', function ($method, $url, $headers, $body) use (&$calls) {
    $calls[] = [$method, $url, $headers, $body];
    check(in_array('x-vhttpd-admin-token: secret', $headers, true));
    if ($method === 'GET') return ['status' => 200, 'body' => json_encode(['epoch' => str_repeat('e', 64), 'issued_at' => time()])];
    if (str_ends_with($url, '/revoke')) return ['status' => 200, 'body' => '{"revoked":true}'];
    return ['status' => 200, 'body' => json_encode(['generation' => 'server-generation-' . count($calls), 'token' => str_repeat('a', 64)])];
});
$lease = $client->issue('stream');
$command = $lease->command(['type' => 'provider.message.send', 'provider' => 'feishu', 'stream_id' => 'stream', 'target' => 'chat']);
$packet = json_encode($command, JSON_THROW_ON_ERROR);
check(count($calls) === 2);
check($command['metadata']['stream_generation'] === $lease->generation && $command['metadata']['creation_token'] === $lease->token);
$client->revoke($lease);
check(json_decode($calls[2][3], true) === $lease->request);
check(json_encode($lease->command($command)) === $packet && count($calls) === 3);
rejects(fn () => $lease->command(array_replace($command, ['stream_id' => 'new'])));
rejects(fn () => $lease->command(array_replace($command, ['instance' => 'other'])));
rejects(fn () => $lease->command(array_replace($command, ['type' => 'session.bind'])));
$bind = $client->issue('bind-stream', 'main', 'message');
$bound = $bind->command(['type' => 'session.bind', 'provider' => 'feishu', 'stream_id' => 'bind-stream', 'target_type' => 'message_id', 'target' => 'message']);
check($bound['metadata']['creation_generation'] === $bind->generation && $bound['metadata']['stream_generation'] === '');
rejects(fn () => $bind->command(array_replace($bound, ['target' => 'replacement'])));
rejects(fn () => new CreationClient('http://localhost', ''));
rejects(fn () => new CreationClient('http://user@localhost', 'secret'));
$failCalls = 0;
$bad = new CreationClient('http://localhost', 'secret', function () use (&$failCalls) { $failCalls++; return ['status' => 403, 'body' => '{}']; });
rejects(fn () => $bad->issue('stream')); check($failCalls === 1);

foreach (['null', 'bad JSON', '{"epoch":"bad","issued_at":1}'] as $body) {
    $invalid = new CreationClient('http://localhost', 'secret', fn () => ['status' => 200, 'body' => $body]);
    rejects(fn () => $invalid->issue('stream'));
}
rejects(fn () => new CreationLease([], 'generation', str_repeat('a', 64)));

$example = dirname(__DIR__, 3) . '/examples/codexbot-app';
foreach (['Db.php', 'Repository/TaskRepository.php', 'Repository/StreamRepository.php', 'Service/StreamService.php', 'Service/CommandFactory.php'] as $file) require $example . '/lib/' . $file;
$dbPath = sys_get_temp_dir() . '/vhttpd-creation-php-' . bin2hex(random_bytes(8)) . '.sqlite';
$previousDbPath = getenv('VHTTPD_BOT_DB_PATH');
putenv('VHTTPD_BOT_DB_PATH=' . $dbPath);
try {
    $db = CodexBot\Db::getConnection();
    $db->exec("INSERT INTO projects(project_key,name,repo_path,created_at,updated_at) VALUES('demo','demo','/tmp','now','now')");
    $streams = new CodexBot\Repository\StreamRepository();
    $service = new CodexBot\Service\StreamService(new CodexBot\Repository\TaskRepository(), $streams, $client);
    $result = $service->createStreamTask(['platform' => 'feishu', 'channel_id' => 'chat', 'project_key' => 'demo', 'prompt' => 'test']);
    $row = $streams->findByStreamId($result['stream_id']);
    require_once $example . '/lib/Upstream/ProviderEventRouter.php';
    $routerType = new ReflectionClass(CodexBot\Upstream\ProviderEventRouter::class);
    $router = $routerType->newInstanceWithoutConstructor();
    $routerType->getProperty('streamRepo')->setValue($router, $streams);
    check($streams->acceptSentReceipt(['stream_id' => $result['stream_id'], 'message_id' => 'new-message', 'stream_generation' => $result['creation']->generation, 'instance' => 'main', 'publication_id' => $result['creation']->request['request_id'], 'publication_sequence' => 1]));
    foreach ([[], ['stream_generation' => 'retired-generation']] as $receipt) {
        $router->dispatch('feishu', 'feishu.message.updated', array_merge($receipt, ['stream_id' => $result['stream_id'], 'message_id' => 'retired-message']), []);
        $afterReceipt = $streams->findByStreamId($result['stream_id']);
        check($afterReceipt['response_message_id'] === 'new-message');
        check($afterReceipt['stream_generation'] === $result['creation']->generation);
    }
    check($row['stream_generation'] === $result['creation']->generation && $row['stream_creation_token'] === $result['creation']->token);
    check(json_decode($row['stream_creation_request'], true) === $result['creation']->request);
    $send = CodexBot\Service\CommandFactory::feishuSendMarkdown('chat', 'hello', $result['stream_id'], 0, $result['creation']);
    check($send['metadata']['creation_token'] === $row['stream_creation_token']);
    check($send['metadata']['publication_id'] === $row['stream_publication_id']);
    $clear = CodexBot\Service\CommandFactory::feishuSessionClear($row['stream_id'], $row['stream_generation']);
    check($clear['metadata']['stream_generation'] === $row['stream_generation']);
    $restored = new CreationLease(json_decode($row['stream_creation_request'], true), $row['stream_generation'], $row['stream_creation_token']);
    check($restored->command($send) === $send);
    rejects(fn () => CodexBot\Service\CommandFactory::feishuSendMarkdown('chat', 'hello', $row['stream_id']));
    $before = (int) $db->query('SELECT count(*) FROM tasks')->fetchColumn();
    $db->exec("CREATE TRIGGER reject_stream BEFORE INSERT ON streams BEGIN SELECT RAISE(ABORT, 'fixture DB failure'); END");
    rejects(fn () => $service->createStreamTask(['platform' => 'feishu', 'channel_id' => 'chat', 'project_key' => 'demo', 'prompt' => 'fail']));
    check((int) $db->query('SELECT count(*) FROM tasks')->fetchColumn() === $before);
    check(str_ends_with($calls[array_key_last($calls)][1], '/revoke'));
    echo "PASS: PHP creation acquisition, captured serialization, SQLite persistence, rollback/revocation and fail-closed transport\n";
} finally {
    CodexBot\Db::resetConnectionForTests(); unset($db, $streams, $service);
    foreach ([$dbPath, $dbPath . '-wal', $dbPath . '-shm'] as $file) if (is_file($file)) unlink($file);
    putenv($previousDbPath === false ? 'VHTTPD_BOT_DB_PATH' : 'VHTTPD_BOT_DB_PATH=' . $previousDbPath);
}

// Existing installations gain empty credentials, never fabricated replacement authority.
$legacyPath = sys_get_temp_dir() . '/vhttpd-creation-legacy-' . bin2hex(random_bytes(8)) . '.sqlite';
putenv('VHTTPD_BOT_DB_PATH=' . $legacyPath);
try {
    $legacy = new PDO('sqlite:' . $legacyPath);
    $schema = file_get_contents($example . '/data/codex.sql');
    $schema = preg_replace('/^  stream_(generation|creation_token|creation_request|instance|publication_id) TEXT[^\n]*\n/m', '', $schema);
    $schema = preg_replace('/^  stream_receipt_sequence INTEGER[^\n]*\n/m', '', $schema);
    $legacy->exec($schema);
    unset($legacy);
    $before = count($calls);
    $migrated = CodexBot\Db::getConnection();
    $columns = $migrated->query('PRAGMA table_info(streams)')->fetchAll(PDO::FETCH_ASSOC);
    foreach (['stream_generation', 'stream_creation_token', 'stream_creation_request', 'stream_instance', 'stream_publication_id', 'stream_receipt_sequence'] as $column) {
        check(in_array($column, array_column($columns, 'name'), true));
    }
    check(count($calls) === $before);
    echo "PASS: legacy SQLite credential migration never acquires replacement grants\n";
} finally {
    CodexBot\Db::resetConnectionForTests(); unset($migrated);
    foreach ([$legacyPath, $legacyPath . '-wal', $legacyPath . '-shm'] as $file) if (is_file($file)) unlink($file);
    putenv($previousDbPath === false ? 'VHTTPD_BOT_DB_PATH' : 'VHTTPD_BOT_DB_PATH=' . $previousDbPath);
}
