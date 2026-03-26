<?php
declare(strict_types=1);

require_once __DIR__ . '/CodexBotTestFixture.php';

function codex_bot_test_app_dir(): string
{
    return dirname(__DIR__);
}

function codex_bot_test_db_path(string $suffix = 'pest'): string
{
    return sys_get_temp_dir() . '/vhttpd_codex_bot_' . $suffix . '_' . getmypid() . '.db';
}

function codex_bot_test_db(string $dbPath): PDO
{
    $pdo = new PDO('sqlite:' . $dbPath);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    return $pdo;
}

function codex_bot_test_init_schema(string $dbPath): void
{
    if (file_exists($dbPath)) {
        unlink($dbPath);
    }

    $pdo = codex_bot_test_db($dbPath);
    $pdo->exec((string) file_get_contents(codex_bot_test_app_dir() . '/codex.sql'));
}

function codex_bot_test_seed_default_binding(PDO $pdo): void
{
    $now = date('Y-m-d H:i:s');
    $insertProject = $pdo->prepare(
        "INSERT INTO projects (project_key, name, repo_path, default_branch, current_model, current_thread_id, current_cwd, is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?)"
    );
    $insertProject->execute([
        'demo',
        'Demo Project',
        '/tmp/demo-repo',
        'main',
        null,
        null,
        '/tmp/demo-repo',
        $now,
        $now,
    ]);

    $insertChannel = $pdo->prepare(
        "INSERT INTO project_channels (project_key, platform, channel_id, thread_key, is_primary, is_active, created_at, updated_at)
         VALUES (?, ?, ?, ?, 1, 1, ?, ?)"
    );
    $insertChannel->execute([
        'demo',
        'feishu',
        'chat_ut_001',
        null,
        $now,
        $now,
    ]);
}

function codex_bot_test_reset_state(PDO $pdo): void
{
    $pdo->exec('DELETE FROM command_contexts');
    $pdo->exec('DELETE FROM settings');
    $pdo->exec('DELETE FROM streams');
    $pdo->exec('DELETE FROM tasks');
    $pdo->exec('DELETE FROM project_channels');
    $pdo->exec('DELETE FROM projects');
}

function codex_bot_test_inbound(string $text, string $chatId = 'chat_ut_001', ?string $messageId = null): array
{
    $messageId = $messageId ?: ('om_test_msg_' . bin2hex(random_bytes(3)));

    return [
        'mode' => 'websocket_upstream',
        'provider' => 'feishu',
        'event_type' => 'im.message.receive_v1',
        'payload' => json_encode([
            'event' => [
                'sender' => ['sender_id' => ['open_id' => 'ou_test_user']],
                'message' => [
                    'message_id' => $messageId,
                    'chat_id' => $chatId,
                    'message_type' => 'text',
                    'content' => json_encode(['text' => $text], JSON_UNESCAPED_UNICODE),
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ];
}

function codex_bot_test_fixture(): Tests\CodexBotTestFixture
{
    static $fixture = null;

    if (!$fixture instanceof Tests\CodexBotTestFixture) {
        $fixture = new Tests\CodexBotTestFixture();
    }

    return $fixture;
}
