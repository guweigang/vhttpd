<?php
declare(strict_types=1);
// Real SQLite producer endpoint for the binary/worker transport regression.
$root = dirname(__DIR__, 2);
foreach (['Db.php', 'Repository/TaskRepository.php', 'Repository/StreamRepository.php', 'Service/TaskStateService.php', 'Upstream/ProviderEventRouter.php'] as $file) require_once $root . '/examples/codexbot-app/lib/' . $file;
$input = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
$db = CodexBot\Db::getConnection();
$repo = new CodexBot\Repository\StreamRepository();
$tasks = new CodexBot\Repository\TaskRepository();
if ($input['action'] === 'create') {
    $db->exec("INSERT INTO projects(project_key,name,repo_path,created_at,updated_at) VALUES('demo','demo','/tmp','now','now')");
    $tasks->create(['task_id' => 'wire', 'project_key' => 'demo', 'platform' => 'feishu', 'channel_id' => 'chat', 'stream_id' => 'wire', 'task_type' => 'ask', 'prompt' => 'test', 'status' => 'queued']);
    $repo->create(['stream_id' => 'wire', 'task_id' => 'wire', 'platform' => 'feishu', 'channel_id' => 'chat', 'stream_generation' => $input['generation'], 'stream_publication_id' => $input['publication_id']]);
} elseif ($input['action'] === 'reserve') {
    $row = $repo->findByStreamId('wire');
    $metadata = $repo->prepareBindingPublication('wire', $row['response_message_id'], $row['stream_generation'], $row['stream_publication_id']);
    if ($metadata === null) throw new RuntimeException('Publication reservation failed');
} elseif ($input['action'] === 'cancel') {
    (new CodexBot\Service\TaskStateService($tasks, $repo))->markCancelled('wire', 'wire');
} elseif ($input['action'] === 'deliver') {
    $reflection = new ReflectionClass(CodexBot\Upstream\ProviderEventRouter::class);
    $router = $reflection->newInstanceWithoutConstructor();
    $reflection->getProperty('streamRepo')->setValue($router, $repo);
    $router->dispatch('feishu', 'feishu.message.sent', $input['receipt'], []);
} else { throw new RuntimeException('Unknown fixture action'); }
echo json_encode(['row' => $repo->findByStreamId('wire'), 'metadata' => $metadata ?? null], JSON_THROW_ON_ERROR);
