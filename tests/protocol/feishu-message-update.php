<?php
declare(strict_types=1);
$root = dirname(__DIR__, 2);
foreach (['Db.php', 'Repository/TaskRepository.php', 'Repository/StreamRepository.php', 'Service/CommandFactory.php'] as $file) require_once $root . '/examples/codexbot-app/lib/' . $file;
function check(bool $value): void { if (!$value) throw new RuntimeException('PHP update ownership regression'); }
$path = tempnam(sys_get_temp_dir(), 'vhttpd-update-');
$old = getenv('VHTTPD_BOT_DB_PATH'); putenv('VHTTPD_BOT_DB_PATH=' . $path);
try {
 $db = CodexBot\Db::getConnection();
 $db->exec("INSERT INTO projects(project_key,name,repo_path,created_at,updated_at) VALUES('p','p','/tmp','now','now')");
 $tasks = new CodexBot\Repository\TaskRepository();
 $tasks->create(['task_id'=>'task','project_key'=>'p','platform'=>'feishu','channel_id'=>'chat','stream_id'=>'stream','task_type'=>'ask','prompt'=>'test','status'=>'queued']);
 $streams = new CodexBot\Repository\StreamRepository();
 $streams->create(['stream_id'=>'stream','task_id'=>'task','platform'=>'feishu','channel_id'=>'chat','response_message_id'=>'message','stream_generation'=>'old','stream_instance'=>'secondary']);
 $context = $tasks->resolveStreamContext('stream');
 check($context['stream_instance'] === 'secondary');
 $packet = json_encode(CodexBot\Service\CommandFactory::feishuMessageUpdate(['stream_id'=>'stream','target'=>'message','content'=>'{}'], $context), JSON_THROW_ON_ERROR);
 $db->exec("UPDATE streams SET stream_generation = 'replacement' WHERE stream_id = 'stream'");
 $captured = CodexBot\Service\CommandFactory::feishuUpdateMarkdown($context, 'late');
 check($captured['metadata']['stream_generation'] === 'old' && $captured['instance'] === 'secondary');
 check(json_decode($packet, true)['metadata']['stream_generation'] === 'old');
 $current = CodexBot\Service\CommandFactory::feishuUpdateMarkdown($streams->findByStreamId('stream'), 'current');
 check($current['metadata']['stream_generation'] === 'replacement');
 check(CodexBot\Service\CommandFactory::feishuUpdateMarkdown('stream', 'ID only')['metadata']['stream_generation'] === '');
 $spoofed = CodexBot\Service\CommandFactory::feishuMessageUpdate(['stream_id'=>'stream','type'=>'session.bind','provider'=>'other','metadata'=>['stream_generation'=>'new']], $context);
 check($spoofed['type'] === 'provider.message.update' && $spoofed['provider'] === 'feishu' && $spoofed['metadata']['stream_generation'] === 'old');
 $rejected = false;
 try { CodexBot\Service\CommandFactory::feishuMessageUpdate(['stream_id'=>'other'], $context); } catch (InvalidArgumentException) { $rejected = true; }
 check($rejected);
 echo "PASS: PHP whole-card update serialization retains captured generation/instance, rejects scope mismatch, and never refreshes ID-only authority\n";
} finally {
 CodexBot\Db::resetConnectionForTests(); unset($db,$streams,$tasks);
 foreach ([$path,$path.'-wal',$path.'-shm'] as $file) if (is_file($file)) unlink($file);
 putenv($old === false ? 'VHTTPD_BOT_DB_PATH' : 'VHTTPD_BOT_DB_PATH='.$old);
}
