<?php
declare(strict_types=1);

it('handles inbound help and regular task bootstrap', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $helpResp = $handler(codex_bot_test_inbound('/help'));
    expect($helpResp['commands'])->toBeArray()->toHaveCount(1);
    expect($helpResp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($helpResp['commands'][0]['provider'] ?? null)->toBe('feishu');

    $taskResp = $handler(codex_bot_test_inbound('请创建一个测试任务'));
    expect($taskResp['commands'])->toBeArray()->toHaveCount(2);
    expect($taskResp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($taskResp['commands'][0]['provider'] ?? null)->toBe('feishu');
    expect($taskResp['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($taskResp['commands'][1]['provider'] ?? null)->toBe('codex');
    expect($taskResp['commands'][1]['method'] ?? null)->toBe('thread/start');
});

it('renders help with new command semantics', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/help'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    $text = codex_bot_test_fixture()->commandText($resp['commands'][0]);
    expect($text)->toContain('/project [project_key]');
    expect($text)->toContain('/thread [thread_id]');
    expect($text)->toContain('/model [model_id]');
    expect($text)->toContain('/config <key>');
    expect($text)->toContain('/settings');
    expect($text)->toContain('/setting <name> <value>');
    expect($text)->toContain('/create <project_key>');
    expect($text)->toContain('/import <project_key> <path>');
    expect($text)->toContain('/cancel');
});

it('handles health and not-found http responses through app runtime', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $runtime = $fixture->runtime();

    $health = $runtime->handle(['path' => '/health']);
    $missing = $runtime->handle(['path' => '/missing']);

    expect($health['status'] ?? null)->toBe(200);
    expect($health['body'] ?? null)->toBe('OK');
    expect($missing['status'] ?? null)->toBe(404);
    expect($missing['content_type'] ?? null)->toBe('application/json');
    expect((string) ($missing['body'] ?? ''))->toContain('Not Found');
});

it('renders admin dashboard through the dedicated http app', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $pdo = $fixture->db();
    $http = $fixture->httpHandler();

    $now = date('Y-m-d H:i:s');
    $pdo->prepare(
        "INSERT INTO tasks
         (task_id, project_key, thread_id, platform, channel_id, thread_key, user_id, request_message_id, stream_id, task_type, prompt, status, codex_turn_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )->execute([
        'task_admin_001',
        'demo',
        'thread_admin_001',
        'feishu',
        'chat_ut_001',
        null,
        'ou_test_user',
        'om_admin_001',
        'stream_admin_001',
        'prompt',
        '请展示 admin dashboard',
        'queued',
        null,
        $now,
        $now,
    ]);
    $pdo->prepare(
        "INSERT INTO streams
         (stream_id, task_id, platform, channel_id, thread_key, response_message_id, status, last_render_hash, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )->execute([
        'stream_admin_001',
        'task_admin_001',
        'feishu',
        'chat_ut_001',
        null,
        'om_admin_response_001',
        'opened',
        null,
        $now,
        $now,
    ]);
    $pdo->prepare(
        "INSERT INTO settings (name, value, created_at, updated_at)
         VALUES (?, ?, ?, ?)"
    )->execute([
        'project_root_dir',
        '/tmp/demo-admin-root',
        $now,
        $now,
    ]);

    $response = $http([
        'method' => 'GET',
        'path' => '/admin',
        'query' => [],
        'headers' => [],
        'cookies' => [],
        'attributes' => [],
        'body' => '',
        'scheme' => 'http',
        'host' => 'demo.local',
        'port' => '80',
        'protocol_version' => '1.1',
        'remote_addr' => '127.0.0.1',
        'server' => [],
        'uploaded_files' => [],
    ]);

    expect($response['status'] ?? null)->toBe(200);
    expect((string) ($response['content_type'] ?? ''))->toContain('text/html');
    expect((string) ($response['body'] ?? ''))->toContain('CodexBot Admin');
    expect((string) ($response['body'] ?? ''))->toContain('Demo Project');
    expect((string) ($response['body'] ?? ''))->toContain('stream_admin_001');
    expect((string) ($response['body'] ?? ''))->toContain('project_root_dir');
});

it('creates a project through the admin mutation service', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $pdo = $fixture->db();
    $now = date('Y-m-d H:i:s');
    $pdo->prepare(
        "INSERT INTO settings (name, value, created_at, updated_at)
         VALUES (?, ?, ?, ?)"
    )->execute([
        'project_root_dir',
        sys_get_temp_dir() . '/codex-admin-live',
        $now,
        $now,
    ]);

    $service = new CodexBot\Admin\AdminMutationService();
    $result = $service->createProject('admin-live-demo', 'Admin Live Demo');

    expect($result['ok'] ?? null)->toBeTrue();
    expect($result['project_key'] ?? null)->toBe('admin-live-demo');

    $project = (new CodexBot\Repository\ProjectRepository())->findByProjectKey('admin-live-demo');
    expect($project)->toBeArray();
    expect($project['name'] ?? null)->toBe('Admin Live Demo');
    expect((string) ($project['repo_path'] ?? ''))->toContain('admin-live-demo');
});

it('saves a setting through the admin mutation service', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();

    $service = new CodexBot\Admin\AdminMutationService();
    $result = $service->saveSetting('project_root_dir', '/tmp/codex-admin-live-root');

    expect($result['ok'] ?? null)->toBeTrue();
    expect($result['name'] ?? null)->toBe('project_root_dir');
    expect((new CodexBot\Repository\SettingsRepository())->findValue('project_root_dir'))
        ->toBe('/tmp/codex-admin-live-root');
});

it('renders worker status through the worker admin command', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    putenv('VHTTPD_ADMIN_STATUS_FIXTURE_JSON=' . json_encode([
        'worker_autostart' => true,
        'worker_pool_size' => 4,
        'worker_rr_index' => 2,
        'worker_max_requests' => 5000,
        'workers' => [
            [
                'id' => 0,
                'socket' => '/tmp/vslim_worker_0.sock',
                'alive' => true,
                'pid' => 1001,
                'rss_kb' => 20480,
                'draining' => false,
                'inflight_requests' => 0,
                'served_requests' => 42,
                'restart_count' => 1,
                'next_retry_ts' => 0,
            ],
            [
                'id' => 1,
                'socket' => '/tmp/vslim_worker_1.sock',
                'alive' => true,
                'pid' => 1002,
                'rss_kb' => 21504,
                'draining' => true,
                'inflight_requests' => 1,
                'served_requests' => 39,
                'restart_count' => 2,
                'next_retry_ts' => 0,
            ],
        ],
    ], JSON_UNESCAPED_UNICODE));

    try {
        $resp = $handler(codex_bot_test_inbound('/worker status'));
        $text = codex_bot_test_fixture()->commandText($resp['commands'][0]);

        expect($text)->toContain('PHP Worker 状态');
        expect($text)->toContain('池大小');
        expect($text)->toContain('`4`');
        expect($text)->toContain('#0');
        expect($text)->toContain('#1');
        expect($text)->toContain('draining');
    } finally {
        putenv('VHTTPD_ADMIN_STATUS_FIXTURE_JSON');
    }
});

it('restarts all workers through the worker admin command', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/worker restart'));
    $text = codex_bot_test_fixture()->commandText($resp['commands'][0]);

    expect($resp['commands'])->toHaveCount(2);
    expect($text)->toContain('PHP worker 即将重启');
    expect($resp['commands'][1]['type'] ?? null)->toBe('admin.worker.restart_all');
});

it('updates project session defaults through the admin mutation service', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();

    $service = new CodexBot\Admin\AdminMutationService();
    $result = $service->updateProjectSession(
        'demo',
        'gpt-5.4-codex',
        'thread_admin_live_001',
        '/tmp/demo-live-cwd'
    );

    expect($result['ok'] ?? null)->toBeTrue();
    expect($result['current_model'] ?? null)->toBe('gpt-5.4-codex');
    expect($result['current_thread_id'] ?? null)->toBe('thread_admin_live_001');

    $project = (new CodexBot\Repository\ProjectRepository())->findByProjectKey('demo');
    expect($project)->toBeArray();
    expect($project['current_model'] ?? null)->toBe('gpt-5.4-codex');
    expect($project['current_thread_id'] ?? null)->toBe('thread_admin_live_001');
    expect($project['current_cwd'] ?? null)->toBe('/tmp/demo-live-cwd');
});

it('sets project model through the admin mutation service shortcut', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();

    $service = new CodexBot\Admin\AdminMutationService();
    $result = $service->setProjectModel('demo', 'gpt-5.4-codex');

    expect($result['ok'] ?? null)->toBeTrue();
    expect((new CodexBot\Repository\ProjectRepository())->findByProjectKey('demo')['current_model'] ?? null)
        ->toBe('gpt-5.4-codex');
});

it('clears project thread through the admin mutation service shortcut', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();

    $repo = new CodexBot\Repository\ProjectRepository();
    $repo->updateCurrentThread('demo', 'thread_to_clear_001', '/tmp/demo-repo');

    $service = new CodexBot\Admin\AdminMutationService();
    $result = $service->clearProjectThread('demo');

    expect($result['ok'] ?? null)->toBeTrue();
    $project = $repo->findByProjectKey('demo');
    expect($project)->toBeArray();
    expect(array_key_exists('current_thread_id', $project))->toBeTrue();
    expect($project['current_thread_id'])->toBeNull();
});

it('resets project cwd through the admin mutation service shortcut', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();

    $repo = new CodexBot\Repository\ProjectRepository();
    $repo->updateCurrentThread('demo', 'thread_keep_001', '/tmp/demo-repo/subdir');

    $service = new CodexBot\Admin\AdminMutationService();
    $result = $service->resetProjectCwd('demo');

    expect($result['ok'] ?? null)->toBeTrue();
    $project = $repo->findByProjectKey('demo');
    expect($project)->toBeArray();
    expect($project['current_cwd'] ?? null)->toBe('/tmp/demo-repo');
    expect($project['current_thread_id'] ?? null)->toBe('thread_keep_001');
});

it('auto-applies schema on first database connection', function (): void {
    $originalDbPath = getenv('VHTTPD_BOT_DB_PATH');
    $dbPath = codex_bot_test_db_path('auto_schema');
    if (file_exists($dbPath)) {
        unlink($dbPath);
    }

    putenv('VHTTPD_BOT_DB_PATH=' . $dbPath);
    CodexBot\Db::resetConnectionForTests();

    $repo = new CodexBot\Repository\SettingsRepository();
    $repo->upsert('project_root_dir', '/tmp/auto-schema-root');

    $pdo = codex_bot_test_db($dbPath);
    $tables = $pdo->query(
        "SELECT name
         FROM sqlite_master
         WHERE type = 'table'
         ORDER BY name"
    )->fetchAll(PDO::FETCH_COLUMN) ?: [];

    expect($tables)->toContain('projects');
    expect($tables)->toContain('tasks');
    expect($tables)->toContain('command_contexts');
    expect($tables)->toContain('settings');

    $row = $pdo->query("SELECT value FROM settings WHERE name = 'project_root_dir' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($row['value'] ?? ''))->toBe('/tmp/auto-schema-root');

    if ($originalDbPath === false || $originalDbPath === '') {
        putenv('VHTTPD_BOT_DB_PATH');
    } else {
        putenv('VHTTPD_BOT_DB_PATH=' . $originalDbPath);
    }
    CodexBot\Db::resetConnectionForTests();
});

it('migrates legacy projects table to add current_model column', function (): void {
    $originalDbPath = getenv('VHTTPD_BOT_DB_PATH');
    $dbPath = codex_bot_test_db_path('legacy_projects_schema');
    if (file_exists($dbPath)) {
        unlink($dbPath);
    }

    $pdo = codex_bot_test_db($dbPath);
    $pdo->exec("CREATE TABLE projects (
        project_key TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        repo_path TEXT NOT NULL,
        default_branch TEXT DEFAULT 'main',
        current_thread_id TEXT,
        current_cwd TEXT,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )");
    $pdo->exec("CREATE TABLE project_channels (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_key TEXT NOT NULL,
        platform TEXT NOT NULL,
        channel_id TEXT NOT NULL,
        thread_key TEXT,
        is_primary INTEGER NOT NULL DEFAULT 1,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )");
    $pdo->exec("CREATE TABLE tasks (
        task_id TEXT PRIMARY KEY,
        project_key TEXT NOT NULL,
        thread_id TEXT,
        platform TEXT NOT NULL,
        channel_id TEXT NOT NULL,
        thread_key TEXT,
        user_id TEXT,
        request_message_id TEXT,
        stream_id TEXT,
        task_type TEXT NOT NULL,
        prompt TEXT NOT NULL,
        status TEXT NOT NULL,
        codex_turn_id TEXT,
        error_message TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )");
    $pdo->exec("CREATE TABLE streams (
        stream_id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL UNIQUE,
        platform TEXT NOT NULL,
        channel_id TEXT NOT NULL,
        thread_key TEXT,
        response_message_id TEXT,
        status TEXT NOT NULL,
        last_render_hash TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    )");

    putenv('VHTTPD_BOT_DB_PATH=' . $dbPath);
    CodexBot\Db::resetConnectionForTests();

    $repo = new CodexBot\Repository\ProjectRepository();
    $repo->save([
        'project_key' => 'legacy',
        'name' => 'Legacy Project',
        'repo_path' => '/tmp/legacy-repo',
        'default_branch' => 'main',
        'current_model' => 'gpt-5.4-codex',
        'current_thread_id' => null,
        'current_cwd' => '/tmp/legacy-repo',
    ]);

    $pdo = codex_bot_test_db($dbPath);
    $columns = $pdo->query("PRAGMA table_info(projects)")->fetchAll(PDO::FETCH_ASSOC) ?: [];
    $columnNames = array_map(static fn (array $row): string => (string) ($row['name'] ?? ''), $columns);
    expect($columnNames)->toContain('current_model');

    $row = $pdo->query("SELECT current_model FROM projects WHERE project_key = 'legacy' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($row['current_model'] ?? ''))->toBe('gpt-5.4-codex');

    if ($originalDbPath === false || $originalDbPath === '') {
        putenv('VHTTPD_BOT_DB_PATH');
    } else {
        putenv('VHTTPD_BOT_DB_PATH=' . $originalDbPath);
    }
    CodexBot\Db::resetConnectionForTests();
});

it('dispatches feishu inbound events through named event handlers', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $router = $fixture->eventRouter();
    $event = VPhp\VHttpd\Upstream\WebSocket\Event::fromDispatchRequest(codex_bot_test_inbound('/help'));

    $response = $router->dispatch($event)->export();

    expect($response['commands'])->toBeArray()->toHaveCount(1);
    expect($response['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($response['commands'][0]['provider'] ?? null)->toBe('feishu');
});

it('dispatches feishu commands through named command router', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $router = $fixture->feishuCommandRouter();
    $project = [
        'project_key' => 'demo',
        'name' => 'Demo Project',
        'repo_path' => '/tmp/demo-repo',
        'current_cwd' => '/tmp/demo-repo',
        'current_thread_id' => null,
    ];

    $response = $router->dispatch('/models', $project, 'chat_ut_001', 'ou_test_user', [
        'event' => [
            'message' => [
                'message_id' => 'om_router_models_001',
            ],
        ],
    ]);

    expect($response)->toBeArray();
    expect($response['commands'])->toBeArray()->toHaveCount(2);
    expect($response['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($response['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($response['commands'][1]['method'] ?? null)->toBe('model/list');
});

it('extracts prompt text through feishu message parser', function (): void {
    $parser = codex_bot_test_fixture()->messageParser();

    $text = $parser->extractPrompt([
        'message_type' => 'post',
        'content' => json_encode([
            'zh_cn' => [
                'title' => '日报',
                'content' => [
                    [
                        ['tag' => 'text', 'text' => '今天修复了 '],
                        ['tag' => 'text', 'text' => 'vhttpd 命令路由'],
                    ],
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($text)->toContain('日报');
    expect($text)->toContain('今天修复了 vhttpd 命令路由');
});

it('extracts prompt text through nested feishu post content payload', function (): void {
    $parser = codex_bot_test_fixture()->messageParser();

    $text = $parser->extractPrompt([
        'message_type' => 'post',
        'content' => json_encode([
            'post' => [
                'zh_cn' => [
                    'title' => '周报',
                    'content' => [
                        [
                            ['tag' => 'text', 'text' => '今天排查了 '],
                            ['tag' => 'text', 'text' => '飞书 markdown 入站'],
                        ],
                    ],
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($text)->toContain('周报');
    expect($text)->toContain('今天排查了 飞书 markdown 入站');
});

it('extracts prompt text through direct feishu post body payload', function (): void {
    $parser = codex_bot_test_fixture()->messageParser();

    $text = $parser->extractPrompt([
        'message_type' => 'post',
        'content' => json_encode([
            'title' => '',
            'content' => [
                [
                    ['tag' => 'text', 'text' => '好，新增 HttpApp.php，和 AppRuntime 同级目录就行，业务这样组织，你有不同意见可以提：'],
                ],
                [
                    ['tag' => 'text', 'text' => '- '],
                    ['tag' => 'text', 'text' => '逻辑 controller/Admin.php'],
                ],
                [
                    ['tag' => 'text', 'text' => '- '],
                    ['tag' => 'text', 'text' => '视图 controller/view/admin/liveview.html ？'],
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($text)->toContain('好，新增 HttpApp.php，和 AppRuntime 同级目录就行');
    expect($text)->toContain('- 逻辑 controller/Admin.php');
    expect($text)->toContain('- 视图 controller/view/admin/liveview.html');
});

it('renders thread summary through thread view helper', function (): void {
    $helper = codex_bot_test_fixture()->threadViewHelper();

    $label = $helper->threadLabel([
        'id' => 'thread_demo_001',
        'turns' => [
            ['content' => '最后一条非常长的消息内容，用来做摘要展示'],
        ],
    ]);
    $card = $helper->renderThreadRead([
        'id' => 'thread_demo_001',
        'name' => 'Demo Thread',
        'preview' => 'preview text',
        'model' => 'gpt-5.3-codex',
    ]);

    expect($label)->toContain('最后一条');
    expect($card)->toContain('当前 Thread 详情');
    expect($card)->toContain('Demo Thread');
    expect($card)->toContain('gpt-5.3-codex');
});

it('formats thread-not-found error through error helper', function (): void {
    $helper = codex_bot_test_fixture()->errorHelper();

    expect($helper->isThreadNotFound('thread not found: thread_ut_001'))->toBeTrue();
    expect($helper->isRateLimitError('thread not found: thread_ut_001'))->toBeFalse();

    $view = $helper->formatUserError('thread not found: thread_ut_001');
    $card = $helper->buildErrorCard('thread not found: thread_ut_001');

    expect($view['title'] ?? null)->toBe('🔄 当前 Thread 已失效');
    expect((string) ($view['body'] ?? ''))->toContain('/threads');
    expect($card)->toContain('当前 Thread 已失效');
    expect($card)->toContain('thread not found: thread_ut_001');
});

it('formats rate-limit and system errors through error helper', function (): void {
    $helper = codex_bot_test_fixture()->errorHelper();

    expect($helper->isRateLimitError('Usage Limit exceeded'))->toBeTrue();
    expect($helper->isSystemError('System Error: upstream failed'))->toBeTrue();

    $rateLimitCard = $helper->buildErrorCard('Usage Limit exceeded');
    $systemCard = $helper->buildErrorCard('System Error: upstream failed');

    expect($rateLimitCard)->toContain('额度或频率限制');
    expect($rateLimitCard)->toContain('Usage Limit exceeded');
    expect($systemCard)->toContain('Codex 服务暂时异常');
    expect($systemCard)->toContain('System Error: upstream failed');
});

it('wraps single and multiple commands through response helper', function (): void {
    $helper = codex_bot_test_fixture()->responseHelper();

    $single = $helper->command(CodexBot\Service\CommandFactory::feishuSendText('chat_ut_001', 'hello'));
    $multiple = $helper->commands([
        CodexBot\Service\CommandFactory::feishuSendText('chat_ut_001', 'hello'),
        CodexBot\Service\CommandFactory::codexRpcCall('model/list', [], 'rpc:test_models_001'),
    ]);

    expect($single['commands'] ?? [])->toBeArray()->toHaveCount(1);
    expect($single['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($multiple['commands'] ?? [])->toBeArray()->toHaveCount(2);
    expect($multiple['commands'][1]['method'] ?? null)->toBe('model/list');
});

it('appends commands into command bus through response helper', function (): void {
    $helper = codex_bot_test_fixture()->responseHelper();
    $bus = new VPhp\VHttpd\Upstream\WebSocket\CommandBus();

    $result = $helper->appendToBus([
        'commands' => [
            CodexBot\Service\CommandFactory::feishuSendText('chat_ut_001', 'hello'),
            CodexBot\Service\CommandFactory::feishuSendText('chat_ut_001', 'world'),
        ],
    ], $bus);

    expect($result)->toBeTrue();
    expect($bus->export()['commands'] ?? [])->toBeArray()->toHaveCount(2);
});

it('decodes nested json payload through json helper', function (): void {
    $helper = codex_bot_test_fixture()->jsonHelper();
    $raw = json_encode(json_encode([
        'result' => [
            'turn' => ['id' => 'turn_nested_001'],
        ],
    ], JSON_UNESCAPED_UNICODE), JSON_UNESCAPED_UNICODE);

    $decoded = $helper->decode($raw, 'test.nested');

    expect($decoded)->toBeArray();
    expect((string) ($decoded['result']['turn']['id'] ?? ''))->toBe('turn_nested_001');
});

it('returns empty array for invalid json through json helper', function (): void {
    $helper = codex_bot_test_fixture()->jsonHelper();

    expect($helper->decode('{invalid-json', 'test.invalid'))->toBe([]);
});

it('handles rpc thread start response and persists thread binding', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $taskResp = $handler(codex_bot_test_inbound('请创建一个测试任务'));
    $streamId = (string) ($taskResp['commands'][1]['stream_id'] ?? '');
    $taskId = str_replace('codex:', '', $streamId);

    $rpcResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/start',
            'has_error' => false,
            'result' => ['thread' => ['id' => 'thread_ut_001']],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($rpcResp['commands'])->toBeArray()->toHaveCount(1);
    expect($rpcResp['commands'][0]['type'] ?? null)->toBe('session.turn.start');
    expect($rpcResp['commands'][0]['provider'] ?? null)->toBe('codex');
    expect($rpcResp['commands'][0]['metadata']['thread_id'] ?? null)->toBe('thread_ut_001');

    $pdo = $fixture->db();

    $taskStmt = $pdo->prepare('SELECT thread_id FROM tasks WHERE task_id = ? LIMIT 1');
    $taskStmt->execute([$taskId]);
    $taskRow = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($taskRow['thread_id'] ?? ''))->toBe('thread_ut_001');

    $projectRow = $pdo->query("SELECT current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($projectRow['current_thread_id'] ?? ''))->toBe('thread_ut_001');
});

it('dispatches provider upstream events through named event handlers', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $router = $fixture->eventRouter();

    $taskResponse = $router->dispatch(
        VPhp\VHttpd\Upstream\WebSocket\Event::fromDispatchRequest(codex_bot_test_inbound('请创建一个测试任务'))
    )->export();

    $streamId = (string) ($taskResponse['commands'][1]['stream_id'] ?? '');
    $rpcEvent = VPhp\VHttpd\Upstream\WebSocket\Event::fromDispatchRequest([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/start',
            'has_error' => false,
            'result' => ['thread' => ['id' => 'thread_ut_001']],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $response = $router->dispatch($rpcEvent)->export();

    expect($response['commands'])->toBeArray()->toHaveCount(1);
    expect($response['commands'][0]['type'] ?? null)->toBe('session.turn.start');
    expect($response['commands'][0]['provider'] ?? null)->toBe('codex');
    expect($response['commands'][0]['metadata']['thread_id'] ?? null)->toBe('thread_ut_001');
});

it('dispatches rpc responses through named rpc router', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $router = $fixture->rpcResponseRouter();

    $taskResp = $handler(codex_bot_test_inbound('请创建一个测试任务'));
    $streamId = (string) ($taskResp['commands'][1]['stream_id'] ?? '');

    $response = $router->dispatch([
        'stream_id' => $streamId,
        'method' => 'thread/start',
        'has_error' => false,
        'result' => ['thread' => ['id' => 'thread_ut_001']],
    ], 'thread/start', $streamId);

    expect($response)->toBeArray();
    expect($response['commands'])->toBeArray()->toHaveCount(1);
    expect($response['commands'][0]['type'] ?? null)->toBe('session.turn.start');
    expect($response['commands'][0]['metadata']['thread_id'] ?? null)->toBe('thread_ut_001');
});

it('dispatches codex notifications through named notification router', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $router = $fixture->notificationRouter();

    $response = $router->dispatch([
        'method' => 'error',
        'params' => ['message' => 'simulated upstream failure'],
    ], [], 'codex:task_notification_router_001');

    expect($response)->toBeArray();
    expect($response['commands'])->toBeArray()->toHaveCount(1);
    expect($response['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect($response['commands'][0]['provider'] ?? null)->toBe('feishu');
    expect((string) ($response['commands'][0]['stream_id'] ?? ''))->toBe('codex:task_notification_router_001');
});

it('renders out-of-credits notification through named notification router', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $router = $fixture->notificationRouter();

    $response = $router->dispatch([
        'method' => 'rateLimits/updated',
        'params' => [
            'credits' => ['hasCredits' => false],
        ],
    ], [], 'codex:task_notification_router_credit_001');

    expect($response)->toBeArray();
    expect($response['commands'])->toBeArray()->toHaveCount(1);
    expect($response['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect((string) ($response['commands'][0]['content'] ?? ''))->toContain('额度已耗尽');
});

it('renders rpc list responses through named rpc result projector', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $projector = $fixture->rpcResultProjector();

    $response = $projector->renderList('model/list', 'codex:task_models_001', [
        'data' => [
            ['id' => 'gpt-5.3-codex', 'name' => 'GPT-5.3 Codex'],
        ],
    ]);

    expect($response)->toBeArray();
    expect($response['commands'])->toBeArray()->toHaveCount(1);
    expect($response['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect(codex_bot_test_fixture()->commandText($response['commands'][0]))->toContain('Codex 可用模型列表');
    expect(codex_bot_test_fixture()->commandText($response['commands'][0]))->toContain('gpt-5.3-codex');
});

it('renders model list without empty parentheses when name is missing', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $projector = $fixture->rpcResultProjector();

    $response = $projector->renderList('model/list', 'codex:task_models_missing_name_001', [
        'data' => [
            ['id' => 'gpt-5.4'],
            ['id' => 'gpt-5.3-codex', 'name' => 'GPT-5.3 Codex'],
        ],
    ]);

    expect($response)->toBeArray();
    $text = codex_bot_test_fixture()->commandText($response['commands'][0]);
    expect($text)->toContain('**gpt-5.4**');
    expect($text)->not->toContain('gpt-5.4 ()');
    expect($text)->toContain('gpt-5.3-codex');
    expect($text)->toContain('GPT-5.3 Codex');
});

it('renders config value responses through named rpc result projector', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $projector = $fixture->rpcResultProjector();

    $response = $projector->renderConfigValue('config/read', 'codex:task_profile_001', [
        'key' => 'profile',
        'value' => 'default',
    ]);

    expect($response)->toBeArray();
    expect($response['commands'])->toBeArray()->toHaveCount(1);
    expect($response['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect(codex_bot_test_fixture()->commandText($response['commands'][0]))->toContain('Codex 当前配置值');
    expect(codex_bot_test_fixture()->commandText($response['commands'][0]))->toContain('`profile`');
    expect(codex_bot_test_fixture()->commandText($response['commands'][0]))->toContain('`default`');
});

it('handles notification lifecycle through named lifecycle router', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $router = $fixture->notificationLifecycleRouter();

    $task = codex_bot_test_fixture()->createRegularTask($handler, '请继续当前任务');
    $streamId = $task['stream_id'];

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'feishu',
        'event_type' => 'feishu.message.sent',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'message_id' => 'om_helper_finish_001',
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/start',
            'has_error' => false,
            'result' => ['thread' => ['id' => 'thread_helper_001']],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'turn/start',
            'has_error' => false,
            'raw_response' => json_encode(['result' => ['turn' => ['id' => 'turn_helper_001']]], JSON_UNESCAPED_UNICODE),
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $response = $router->dispatch(
        'item/completed',
        [
            'turnId' => 'turn_helper_001',
            'threadId' => 'thread_helper_001',
        ],
        $streamId,
        'thread_helper_001',
        'turn_helper_001',
        'chat_ut_001',
    );

    expect($response)->toBeArray();
    expect($response['commands'])->toBeArray()->toHaveCount(1);
    expect($response['commands'][0]['type'] ?? null)->toBe('stream.finish');
    expect($response['commands'][0]['provider'] ?? null)->toBe('feishu');
    expect((string) ($response['commands'][0]['target'] ?? ''))->toBe('om_helper_finish_001');
});

it('resolves stream context by turn and channel through context helper', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $helper = $fixture->contextHelper();

    $task = codex_bot_test_fixture()->createRegularTask($handler, '请继续当前任务');
    $streamId = $task['stream_id'];

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'feishu',
        'event_type' => 'feishu.message.sent',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'message_id' => 'om_context_stream_001',
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/start',
            'has_error' => false,
            'result' => ['thread' => ['id' => 'thread_context_helper_001']],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'turn/start',
            'has_error' => false,
            'raw_response' => json_encode(['result' => ['turn' => ['id' => 'turn_context_helper_001']]], JSON_UNESCAPED_UNICODE),
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $context = $helper->resolveStreamContext('', 'thread_context_helper_001', 'turn_context_helper_001', 'chat_ut_001');

    expect($context)->toBeArray();
    expect((string) ($context['stream_id'] ?? ''))->toBe($streamId);
    expect((string) ($context['thread_id'] ?? ''))->toBe('thread_context_helper_001');
    expect((string) ($context['response_message_id'] ?? ''))->toBe('om_context_stream_001');
});

it('handles /threads with thread list rpc command in project cwd', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/threads'));
    expect($resp['commands'])->toBeArray()->toHaveCount(2);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($resp['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($resp['commands'][1]['method'] ?? null)->toBe('thread/list');

    $params = json_decode((string) ($resp['commands'][1]['params'] ?? ''), true);
    expect($params)->toBeArray();
    expect((int) ($params['limit'] ?? 0))->toBe(10);
    expect((string) ($params['cwd'] ?? ''))->toBe('/tmp/demo-repo');
});

it('resets current thread on /new command', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $fixture->startThread($handler);
    $fixture->contextHelper()->createPendingThreadSelection(
        'demo',
        'thread_pending_new_reset',
        'feishu',
        'chat_ut_001',
        'ou_test_user',
        'om_test_msg_pending_new_reset'
    );

    $resp = $handler(codex_bot_test_inbound('/new'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect((string) ($resp['commands'][0]['message_type'] ?? ''))->toBe('text');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('会话已重置');

    $pdo = $fixture->db();
    $projectRow = $pdo->query("SELECT current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($projectRow['current_thread_id'] ?? ''))->toBe('');
    $pending = $pdo->query(
        "SELECT status FROM tasks
         WHERE project_key = 'demo' AND task_type = 'use_thread' AND thread_id = 'thread_pending_new_reset'
         ORDER BY updated_at DESC LIMIT 1"
    )->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($pending['status'] ?? ''))->toBe('completed');
});

it('clears current thread when rpc response returns thread not found', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $streamId = $fixture->startThread($handler);

    $errorResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/resume',
            'has_error' => true,
            'result' => ['error' => ['message' => 'thread not found: thread_ut_001']],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($errorResp['commands'])->toBeArray()->toHaveCount(1);
    expect($errorResp['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect((string) ($errorResp['commands'][0]['content'] ?? ''))->toContain('已自动清除当前绑定线程');

    $pdo = $fixture->db();
    $projectRow = $pdo->query("SELECT current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($projectRow['current_thread_id'] ?? ''))->toBe('');
});

it('handles /use latest with list-latest rpc request', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/use latest'));
    expect($resp['commands'])->toBeArray()->toHaveCount(2);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($resp['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($resp['commands'][1]['method'] ?? null)->toBe('thread/list');

    $params = json_decode((string) ($resp['commands'][1]['params'] ?? ''), true);
    expect($params)->toBeArray();
    expect((int) ($params['limit'] ?? 0))->toBe(1);
    expect((string) ($params['cwd'] ?? ''))->toBe('/tmp/demo-repo');
});

it('returns missing-thread hint for /thread when no thread bound', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/thread'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect((string) ($resp['commands'][0]['message_type'] ?? ''))->toBe('interactive');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('当前还没有绑定 Codex Thread');
});

it('stores pending thread selection for /use <thread_id>', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/use thread_custom_123'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('已暂存待验证 Codex Thread');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('thread_custom_123');

    $pdo = $fixture->db();
    $row = $pdo->query(
        "SELECT thread_id, task_type, status
         FROM tasks
         WHERE project_key = 'demo'
         ORDER BY created_at DESC
         LIMIT 1"
    )->fetch(PDO::FETCH_ASSOC) ?: [];

    expect((string) ($row['thread_id'] ?? ''))->toBe('thread_custom_123');
    expect((string) ($row['task_type'] ?? ''))->toBe('use_thread');
    expect((string) ($row['status'] ?? ''))->toBe('pending_bind');
});

it('uses pending thread as resume target for next regular task', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $handler(codex_bot_test_inbound('/use thread_pending_001'));
    $resp = $handler(codex_bot_test_inbound('继续处理这个任务'));

    expect($resp['commands'])->toBeArray()->toHaveCount(2);
    expect($resp['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($resp['commands'][1]['method'] ?? null)->toBe('thread/resume');

    $params = json_decode((string) ($resp['commands'][1]['params'] ?? ''), true);
    expect($params)->toBeArray();
    expect((string) ($params['threadId'] ?? ''))->toBe('thread_pending_001');
});

it('shows pending thread in /current context output', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $handler(codex_bot_test_inbound('/use thread_pending_ctx'));
    $resp = $handler(codex_bot_test_inbound('/current'));

    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');

    $text = codex_bot_test_fixture()->commandText($resp['commands'][0]);
    expect($text)->toContain('当前项目');
    expect($text)->toContain('待验证 Thread');
    expect($text)->toContain('thread_pending_ctx');
});

it('prefers pending thread over current project thread through context helper', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $helper = $fixture->contextHelper();

    $helper->createPendingThreadSelection(
        'demo',
        'thread_pending_helper_001',
        'feishu',
        'chat_ut_001',
        'ou_test_user',
        'om_context_helper_001'
    );

    $project = [
        'project_key' => 'demo',
        'current_thread_id' => 'thread_current_001',
    ];

    expect($helper->preferredThreadId($project))->toBe('thread_pending_helper_001');

    $pdo = $fixture->db();
    $row = $pdo->query(
        "SELECT thread_id, task_type, status
         FROM tasks
         WHERE task_type = 'use_thread'
         ORDER BY created_at DESC
         LIMIT 1"
    )->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($row['thread_id'] ?? ''))->toBe('thread_pending_helper_001');
    expect((string) ($row['status'] ?? ''))->toBe('pending_bind');
});

it('falls back to current thread after resolving pending selection through context helper', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $helper = $fixture->contextHelper();

    $helper->createPendingThreadSelection(
        'demo',
        'thread_pending_helper_002',
        'feishu',
        'chat_ut_001',
        'ou_test_user',
        'om_context_helper_002'
    );
    $helper->resolvePendingThreadSelection('demo', 'thread_pending_helper_002');

    $project = [
        'project_key' => 'demo',
        'current_thread_id' => 'thread_current_after_resolve',
    ];

    $pdo = $fixture->db();
    $row = $pdo->query(
        "SELECT thread_id, status
         FROM tasks
         WHERE task_type = 'use_thread'
         ORDER BY created_at DESC
         LIMIT 1"
    )->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($row['thread_id'] ?? ''))->toBe('thread_pending_helper_002');
    expect((string) ($row['status'] ?? ''))->toBe('completed');

    expect($helper->preferredThreadId($project))->toBe('thread_current_after_resolve');
});

it('returns project-not-found hint for /bind on unknown project', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/bind unknown_project'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('项目不存在');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('unknown_project');
});

it('binds secondary project without switching primary via /bind', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();
    $fixture->seedProject($pdo, 'api', 'API Project', '/tmp/api-repo', 'develop');

    $resp = $handler(codex_bot_test_inbound('/bind api'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('项目已绑定到当前聊天');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('当前主项目');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('demo');

    $rows = $pdo->query(
        "SELECT project_key, is_primary, is_active
         FROM project_channels
         WHERE platform = 'feishu' AND channel_id = 'chat_ut_001'
         ORDER BY project_key"
    )->fetchAll(PDO::FETCH_ASSOC) ?: [];

    expect($rows)->toHaveCount(2);
    $byKey = [];
    foreach ($rows as $row) {
        $byKey[(string) $row['project_key']] = $row;
    }
    expect((int) ($byKey['demo']['is_primary'] ?? 0))->toBe(1);
    expect((int) ($byKey['api']['is_primary'] ?? 0))->toBe(0);
    expect((int) ($byKey['api']['is_active'] ?? 0))->toBe(1);
});

it('switches primary project with /switch and subsequent task uses switched project', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();
    $fixture->seedProject($pdo, 'api', 'API Project', '/tmp/api-repo', 'develop');

    $switchResp = $handler(codex_bot_test_inbound('/switch api'));
    expect($switchResp['commands'])->toBeArray()->toHaveCount(1);
    expect($switchResp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect(codex_bot_test_fixture()->commandText($switchResp['commands'][0]))->toContain('已切换当前项目');
    expect(codex_bot_test_fixture()->commandText($switchResp['commands'][0]))->toContain('api');

    $rows = $pdo->query(
        "SELECT project_key, is_primary
         FROM project_channels
         WHERE platform = 'feishu' AND channel_id = 'chat_ut_001'
         ORDER BY project_key"
    )->fetchAll(PDO::FETCH_ASSOC) ?: [];

    $byKey = [];
    foreach ($rows as $row) {
        $byKey[(string) $row['project_key']] = $row;
    }
    expect((int) ($byKey['api']['is_primary'] ?? 0))->toBe(1);
    expect((int) ($byKey['demo']['is_primary'] ?? 0))->toBe(0);

    $taskResp = $handler(codex_bot_test_inbound('切换后发起任务'));
    $streamId = (string) ($taskResp['commands'][1]['stream_id'] ?? '');
    $taskId = str_replace('codex:', '', $streamId);
    $taskRow = $pdo->prepare("SELECT project_key FROM tasks WHERE task_id = ? LIMIT 1");
    $taskRow->execute([$taskId]);
    $task = $taskRow->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($task['project_key'] ?? ''))->toBe('api');
});

it('lists all bound projects in /projects output', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();
    $fixture->seedProject($pdo, 'api', 'API Project', '/tmp/api-repo', 'develop');
    $handler(codex_bot_test_inbound('/bind api'));

    $resp = $handler(codex_bot_test_inbound('/projects'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    $text = codex_bot_test_fixture()->commandText($resp['commands'][0]);
    expect($text)->toContain('当前聊天已绑定项目');
    expect($text)->toContain('`demo`');
    expect($text)->toContain('`api`');
});

it('shows new create guidance without legacy repo path placeholder', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();

    codex_bot_test_reset_state($pdo);

    $projectsResp = $handler(codex_bot_test_inbound('/projects'));
    $projectsText = codex_bot_test_fixture()->commandText($projectsResp['commands'][0]);
    expect($projectsText)->toContain('/create <project_key>');
    expect($projectsText)->not->toContain('<repo_path>');

    $currentResp = $handler(codex_bot_test_inbound('/project'));
    $currentText = codex_bot_test_fixture()->commandText($currentResp['commands'][0]);
    expect($currentText)->toContain('/create <project_key>');
    expect($currentText)->not->toContain('<repo_path>');
});

it('routes /models to model/list rpc call', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/models'));
    expect($resp['commands'])->toBeArray()->toHaveCount(2);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($resp['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($resp['commands'][1]['method'] ?? null)->toBe('model/list');
});

it('routes /config profile to config/read rpc call', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/config profile'));
    expect($resp['commands'])->toBeArray()->toHaveCount(2);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('正在读取 Codex 配置');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('profile');
    expect($resp['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($resp['commands'][1]['method'] ?? null)->toBe('config/read');

    $params = json_decode((string) ($resp['commands'][1]['params'] ?? ''), true);
    expect((string) ($params['key'] ?? ''))->toBe('profile');
});

it('requires a key for /config command', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/config'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('缺少配置项名称');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('/config <key>');
});

it('shows current project via /project without args', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $resp = $handler(codex_bot_test_inbound('/project'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    $text = codex_bot_test_fixture()->commandText($resp['commands'][0]);
    expect($text)->toContain('当前项目');
    expect($text)->toContain('`demo`');
    expect($text)->toContain('`gpt-5.3-codex`');
});

it('switches project via /project <key>', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();
    $fixture->seedProject($pdo, 'api', 'API Project', '/tmp/api-repo', 'develop');

    $switchResp = $handler(codex_bot_test_inbound('/project api'));
    expect($switchResp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($switchResp['commands'][0]))->toContain('已切换当前项目');
    expect(codex_bot_test_fixture()->commandText($switchResp['commands'][0]))->toContain('`api`');

    $taskResp = $handler(codex_bot_test_inbound('切换后发起任务'));
    $streamId = (string) ($taskResp['commands'][1]['stream_id'] ?? '');
    $taskId = str_replace('codex:', '', $streamId);
    $taskStmt = $pdo->prepare("SELECT project_key FROM tasks WHERE task_id = ? LIMIT 1");
    $taskStmt->execute([$taskId]);
    $task = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($task['project_key'] ?? ''))->toBe('api');
});

it('uses /use project key after /projects context', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();
    $fixture->seedProject($pdo, 'api', 'API Project', '/tmp/api-repo', 'develop');
    $handler(codex_bot_test_inbound('/bind api'));

    $handler(codex_bot_test_inbound('/projects'));
    $resp = $handler(codex_bot_test_inbound('/use api'));

    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('已切换当前项目');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('`api`');
});

it('shows and updates current model through /model commands', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();
    $fixture->startThread($handler);
    $fixture->contextHelper()->createPendingThreadSelection(
        'demo',
        'thread_pending_model_reset',
        'feishu',
        'chat_ut_001',
        'ou_test_user',
        'om_test_msg_pending_model_reset'
    );

    $showResp = $handler(codex_bot_test_inbound('/model'));
    expect($showResp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($showResp['commands'][0]))->toContain('当前模型');
    expect(codex_bot_test_fixture()->commandText($showResp['commands'][0]))->toContain('`gpt-5.3-codex`');

    $setResp = $handler(codex_bot_test_inbound('/model gpt-5.4-codex'));
    expect($setResp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($setResp['commands'][0]))->toContain('模型已更新并立即生效');
    expect(codex_bot_test_fixture()->commandText($setResp['commands'][0]))->toContain('gpt-5.4-codex');

    $project = $pdo->query("SELECT current_model, current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['current_model'] ?? ''))->toBe('gpt-5.4-codex');
    expect((string) ($project['current_thread_id'] ?? ''))->toBe('');
    $pending = $pdo->query(
        "SELECT status FROM tasks
         WHERE project_key = 'demo' AND task_type = 'use_thread' AND thread_id = 'thread_pending_model_reset'
         ORDER BY updated_at DESC LIMIT 1"
    )->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($pending['status'] ?? ''))->toBe('completed');

    $taskResp = $handler(codex_bot_test_inbound('请用新模型开始任务'));
    $params = json_decode((string) ($taskResp['commands'][1]['params'] ?? ''), true);
    expect((string) ($taskResp['commands'][1]['method'] ?? ''))->toBe('thread/start');
    expect((string) ($params['model'] ?? ''))->toBe('gpt-5.4-codex');
});

it('uses /use model id after /models context', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();

    $handler(codex_bot_test_inbound('/models'));
    $resp = $handler(codex_bot_test_inbound('/use gpt-5.5-codex'));

    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('模型已更新并立即生效');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('gpt-5.5-codex');

    $project = $pdo->query("SELECT current_model FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['current_model'] ?? ''))->toBe('gpt-5.5-codex');
});

it('resets conversation and applies model through /new <model_id>', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();
    $fixture->startThread($handler);
    $fixture->contextHelper()->createPendingThreadSelection(
        'demo',
        'thread_pending_new_model',
        'feishu',
        'chat_ut_001',
        'ou_test_user',
        'om_test_msg_pending_new_model'
    );

    $resp = $handler(codex_bot_test_inbound('/new gpt-5.5-codex'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('会话已重置并切换模型');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('gpt-5.5-codex');

    $project = $pdo->query("SELECT current_model, current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['current_model'] ?? ''))->toBe('gpt-5.5-codex');
    expect((string) ($project['current_thread_id'] ?? ''))->toBe('');

    $pending = $pdo->query(
        "SELECT status FROM tasks
         WHERE project_key = 'demo' AND task_type = 'use_thread' AND thread_id = 'thread_pending_new_model'
         ORDER BY updated_at DESC LIMIT 1"
    )->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($pending['status'] ?? ''))->toBe('completed');

    $taskResp = $handler(codex_bot_test_inbound('请直接开始新的模型会话'));
    expect((string) ($taskResp['commands'][1]['method'] ?? ''))->toBe('thread/start');
    $params = json_decode((string) ($taskResp['commands'][1]['params'] ?? ''), true);
    expect((string) ($params['model'] ?? ''))->toBe('gpt-5.5-codex');
});

it('stores and lists settings through /setting and /settings', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();

    $setResp = $handler(codex_bot_test_inbound('/setting project_root_dir /tmp/codex-projects-test'));
    expect($setResp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($setResp['commands'][0]))->toContain('配置已更新');
    expect(codex_bot_test_fixture()->commandText($setResp['commands'][0]))->toContain('project_root_dir');

    $row = $pdo->query("SELECT value FROM settings WHERE name = 'project_root_dir' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($row['value'] ?? ''))->toBe('/tmp/codex-projects-test');

    $listResp = $handler(codex_bot_test_inbound('/settings'));
    expect($listResp['commands'])->toBeArray()->toHaveCount(1);
    $text = codex_bot_test_fixture()->commandText($listResp['commands'][0]);
    expect($text)->toContain('当前配置');
    expect($text)->toContain('project_root_dir');
    expect($text)->toContain('/tmp/codex-projects-test');
});

it('creates and switches project via /create', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $projectRootDir = sys_get_temp_dir() . '/codex-project-root-' . getmypid();
    $handler(codex_bot_test_inbound('/setting project_root_dir ' . $projectRootDir));

    $resp = $handler(codex_bot_test_inbound('/create lab'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('项目已创建并切换');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('`lab`');

    $pdo = $fixture->db();
    $projectStmt = $pdo->prepare("SELECT repo_path, default_branch FROM projects WHERE project_key = ? LIMIT 1");
    $projectStmt->execute(['lab']);
    $project = $projectStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['repo_path'] ?? ''))->toBe($projectRootDir . '/lab');
    expect((string) ($project['default_branch'] ?? ''))->toBe('main');
    expect(is_dir($projectRootDir . '/lab'))->toBeTrue();

    $taskResp = $handler(codex_bot_test_inbound('在新项目里发任务'));
    expect($taskResp['commands'])->toBeArray()->toHaveCount(2);
    $streamId = (string) ($taskResp['commands'][1]['stream_id'] ?? '');
    $taskId = str_replace('codex:', '', $streamId);
    $pdo = $fixture->db();
    $taskStmt = $pdo->prepare("SELECT project_key FROM tasks WHERE task_id = ? LIMIT 1");
    $taskStmt->execute([$taskId]);
    $task = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($task['project_key'] ?? ''))->toBe('lab');
});

it('imports existing project directory and switches current project', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $repoPath = sys_get_temp_dir() . '/codex-import-project-' . getmypid();
    if (!is_dir($repoPath)) {
        mkdir($repoPath, 0777, true);
    }

    $resp = $handler(codex_bot_test_inbound('/import outside ' . $repoPath));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('项目已导入并切换');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('`outside`');

    $pdo = $fixture->db();
    $projectStmt = $pdo->prepare("SELECT repo_path, current_cwd, default_branch FROM projects WHERE project_key = ? LIMIT 1");
    $projectStmt->execute(['outside']);
    $project = $projectStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['repo_path'] ?? ''))->toBe(realpath($repoPath) ?: $repoPath);
    expect((string) ($project['current_cwd'] ?? ''))->toBe(realpath($repoPath) ?: $repoPath);
    expect((string) ($project['default_branch'] ?? ''))->toBe('main');

    $currentResp = $handler(codex_bot_test_inbound('/project'));
    expect($currentResp['commands'])->toBeArray()->toHaveCount(1);
    $currentText = codex_bot_test_fixture()->commandText($currentResp['commands'][0]);
    expect($currentText)->toContain('`outside`');
    expect($currentText)->toContain(realpath($repoPath) ?: $repoPath);

    $taskResp = $handler(codex_bot_test_inbound('在导入项目里发任务'));
    expect($taskResp['commands'])->toBeArray()->toHaveCount(2);
    expect((string) ($taskResp['commands'][1]['method'] ?? ''))->toBe('thread/start');
    $params = json_decode((string) ($taskResp['commands'][1]['params'] ?? ''), true);
    expect((string) ($params['cwd'] ?? ''))->toBe(realpath($repoPath) ?: $repoPath);
});

it('cancels latest task and ignores late completion events', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $pdo = $fixture->db();

    $created = $fixture->createRegularTask($handler, '需要被取消的任务');
    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'feishu',
        'event_type' => 'feishu.message.sent',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'message_id' => 'om_cancel_target_001',
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $cancelResp = $handler(codex_bot_test_inbound('/cancel'));
    expect($cancelResp['commands'])->toBeArray()->toHaveCount(1);
    expect($cancelResp['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect((string) ($cancelResp['commands'][0]['target'] ?? ''))->toBe('om_cancel_target_001');
    expect((string) ($cancelResp['commands'][0]['content'] ?? ''))->toContain('任务已取消');

    $taskStmt = $pdo->prepare("SELECT status FROM tasks WHERE task_id = ? LIMIT 1");
    $taskStmt->execute([$created['task_id']]);
    $task = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($task['status'] ?? ''))->toBe('cancelled');

    $ignoredResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.turn.completed',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'status' => 'completed',
        ], JSON_UNESCAPED_UNICODE),
    ]);
    expect($ignoredResp['commands'] ?? [])->toBeArray()->toHaveCount(0);

    $taskStmt->execute([$created['task_id']]);
    $taskAfter = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($taskAfter['status'] ?? ''))->toBe('cancelled');
});

it('marks task and stream completed on codex.turn.completed status completed', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $created = $fixture->createRegularTask($handler);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.turn.completed',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'status' => 'completed',
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $pdo = $fixture->db();
    $taskStmt = $pdo->prepare('SELECT status FROM tasks WHERE task_id = ? LIMIT 1');
    $taskStmt->execute([$created['task_id']]);
    $task = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($task['status'] ?? ''))->toBe('completed');

    $streamStmt = $pdo->prepare('SELECT status FROM streams WHERE stream_id = ? LIMIT 1');
    $streamStmt->execute([$created['stream_id']]);
    $stream = $streamStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($stream['status'] ?? ''))->toBe('completed');
});

it('marks task and stream failed on codex.turn.completed non-completed status', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $created = $fixture->createRegularTask($handler);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.turn.completed',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'status' => 'failed',
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $pdo = $fixture->db();
    $taskStmt = $pdo->prepare('SELECT status FROM tasks WHERE task_id = ? LIMIT 1');
    $taskStmt->execute([$created['task_id']]);
    $task = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($task['status'] ?? ''))->toBe('failed');

    $streamStmt = $pdo->prepare('SELECT status FROM streams WHERE stream_id = ? LIMIT 1');
    $streamStmt->execute([$created['stream_id']]);
    $stream = $streamStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($stream['status'] ?? ''))->toBe('failed');
});

it('binds response message id on feishu.message.sent provider event', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $created = $fixture->createRegularTask($handler);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'feishu',
        'event_type' => 'feishu.message.sent',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'message_id' => 'om_reply_001',
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $pdo = $fixture->db();
    $stmt = $pdo->prepare('SELECT response_message_id FROM streams WHERE stream_id = ? LIMIT 1');
    $stmt->execute([$created['stream_id']]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($row['response_message_id'] ?? ''))->toBe('om_reply_001');
});

it('returns feishu update command for codex.notification error with stream id', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $created = $fixture->createRegularTask($handler);

    $resp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.notification',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'method' => 'error',
            'params' => [
                'message' => 'simulated upstream failure',
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect((string) ($resp['commands'][0]['stream_id'] ?? ''))->toBe($created['stream_id']);
    expect((string) ($resp['commands'][0]['content'] ?? ''))->toContain('simulated upstream failure');
});

it('streams delta patches and final flush after the placeholder message is bound', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $created = $fixture->createRegularTask($handler, '请继续当前任务');

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'feishu',
        'event_type' => 'feishu.message.sent',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'message_id' => 'om_reply_stream_001',
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'method' => 'thread/start',
            'has_error' => false,
            'result' => ['thread' => ['id' => 'thread_stream_001']],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'method' => 'turn/start',
            'has_error' => false,
            'raw_response' => json_encode([
                'result' => [
                    'turn' => ['id' => 'turn_stream_001'],
                ],
            ], JSON_UNESCAPED_UNICODE),
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $deltaResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.notification',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'method' => 'item/agentMessage/delta',
            'params' => [
                'turnId' => 'turn_stream_001',
                'threadId' => 'thread_stream_001',
                'delta' => '第一段回复',
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($deltaResp['commands'])->toBeArray()->toHaveCount(1);
    expect($deltaResp['commands'][0]['type'] ?? null)->toBe('stream.append');
    expect($deltaResp['commands'][0]['provider'] ?? null)->toBe('feishu');
    expect((string) ($deltaResp['commands'][0]['target'] ?? ''))->toBe('om_reply_stream_001');
    expect((string) ($deltaResp['commands'][0]['text'] ?? ''))->toBe('第一段回复');

    $flushResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.notification',
        'payload' => json_encode([
            'stream_id' => $created['stream_id'],
            'method' => 'item/completed',
            'params' => [
                'turnId' => 'turn_stream_001',
                'threadId' => 'thread_stream_001',
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($flushResp['commands'])->toBeArray()->toHaveCount(1);
    expect($flushResp['commands'][0]['type'] ?? null)->toBe('stream.finish');
    expect($flushResp['commands'][0]['provider'] ?? null)->toBe('feishu');
    expect((string) ($flushResp['commands'][0]['target'] ?? ''))->toBe('om_reply_stream_001');
    expect((string) ($flushResp['commands'][0]['stream_id'] ?? ''))->toBe($created['stream_id']);

    $pdo = $fixture->db();
    $taskStmt = $pdo->prepare('SELECT status, codex_turn_id, thread_id FROM tasks WHERE task_id = ? LIMIT 1');
    $taskStmt->execute([$created['task_id']]);
    $task = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($task['status'] ?? ''))->toBe('completed');
    expect((string) ($task['codex_turn_id'] ?? ''))->toBe('turn_stream_001');
    expect((string) ($task['thread_id'] ?? ''))->toBe('thread_stream_001');
});

it('renders latest thread summary for /thread latest when thread is active', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $fixture->startThread($handler);

    $resp = $handler(codex_bot_test_inbound('/thread latest'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect((string) ($resp['commands'][0]['message_type'] ?? ''))->toBe('interactive');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('当前 Thread 最近一次本地任务');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('thread_ut_001');
});

it('renders recent thread history for /thread recent when thread is active', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $fixture->startThread($handler);

    $handler(codex_bot_test_inbound('继续第一个任务'));
    $handler(codex_bot_test_inbound('继续第二个任务'));

    $resp = $handler(codex_bot_test_inbound('/thread recent'));
    expect($resp['commands'])->toBeArray()->toHaveCount(1);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect((string) ($resp['commands'][0]['message_type'] ?? ''))->toBe('interactive');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('当前 Thread 最近几次本地任务');
    expect(codex_bot_test_fixture()->commandText($resp['commands'][0]))->toContain('thread_ut_001');
});

it('handles /use latest rpc thread/list response and creates pending bind task', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $useResp = $handler(codex_bot_test_inbound('/use latest'));
    $streamId = (string) ($useResp['commands'][1]['stream_id'] ?? '');

    $rpcResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/list',
            'has_error' => false,
            'result' => [
                'data' => [
                    ['id' => 'thread_latest_001', 'title' => 'Latest Thread'],
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($rpcResp['commands'])->toBeArray()->toHaveCount(1);
    expect($rpcResp['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect(codex_bot_test_fixture()->commandText($rpcResp['commands'][0]))->toContain('已暂存最近一个 Codex Thread');
    expect(codex_bot_test_fixture()->commandText($rpcResp['commands'][0]))->toContain('thread_latest_001');

    $pdo = $fixture->db();
    $pending = $pdo->query(
        "SELECT thread_id, task_type, status
         FROM tasks
         WHERE task_type = 'use_thread'
         ORDER BY created_at DESC
         LIMIT 1"
    )->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($pending['thread_id'] ?? ''))->toBe('thread_latest_001');
    expect((string) ($pending['status'] ?? ''))->toBe('pending_bind');

    $sourceTaskId = str_replace('codex:', '', $streamId);
    $sourceStmt = $pdo->prepare("SELECT task_type, status FROM tasks WHERE task_id = ? LIMIT 1");
    $sourceStmt->execute([$sourceTaskId]);
    $sourceTask = $sourceStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($sourceTask['task_type'] ?? ''))->toBe('use_thread_latest');
    expect((string) ($sourceTask['status'] ?? ''))->toBe('completed');
});

it('returns no-history hint when /use latest rpc thread/list has empty data', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $useResp = $handler(codex_bot_test_inbound('/use latest'));
    $streamId = (string) ($useResp['commands'][1]['stream_id'] ?? '');

    $rpcResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/list',
            'has_error' => false,
            'result' => ['data' => []],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($rpcResp['commands'])->toBeArray()->toHaveCount(1);
    expect($rpcResp['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect(codex_bot_test_fixture()->commandText($rpcResp['commands'][0]))->toContain('没有可用的历史 Thread');
});

it('starts thread/read rpc when /thread is called with active thread', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $fixture->startThread($handler);

    $resp = $handler(codex_bot_test_inbound('/thread'));
    expect($resp['commands'])->toBeArray()->toHaveCount(2);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($resp['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($resp['commands'][1]['method'] ?? null)->toBe('thread/read');

    $params = json_decode((string) ($resp['commands'][1]['params'] ?? ''), true);
    expect($params)->toBeArray();
    expect((string) ($params['threadId'] ?? ''))->toBe('thread_ut_001');
});

it('renders thread/read result card and marks thread_read task completed', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $fixture->startThread($handler);

    $threadResp = $handler(codex_bot_test_inbound('/thread'));
    $streamId = (string) ($threadResp['commands'][1]['stream_id'] ?? '');
    $taskId = str_replace('codex:', '', $streamId);

    $rpcResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/read',
            'has_error' => false,
            'result' => [
                'thread' => [
                    'id' => 'thread_ut_001',
                    'name' => 'Demo Thread',
                    'preview' => 'preview text',
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($rpcResp['commands'])->toBeArray()->toHaveCount(1);
    expect($rpcResp['commands'][0]['type'] ?? null)->toBe('provider.message.update');
    expect(codex_bot_test_fixture()->commandText($rpcResp['commands'][0]))->toContain('当前 Thread 详情');
    expect(codex_bot_test_fixture()->commandText($rpcResp['commands'][0]))->toContain('thread_ut_001');

    $pdo = $fixture->db();
    $stmt = $pdo->prepare("SELECT status, task_type FROM tasks WHERE task_id = ? LIMIT 1");
    $stmt->execute([$taskId]);
    $row = $stmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($row['task_type'] ?? ''))->toBe('thread_read');
    expect((string) ($row['status'] ?? ''))->toBe('completed');
});

it('updates current session thread when thread/read resolves to a different thread id', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $fixture->startThread($handler);

    $threadResp = $handler(codex_bot_test_inbound('/thread'));
    $streamId = (string) ($threadResp['commands'][1]['stream_id'] ?? '');
    $taskId = str_replace('codex:', '', $streamId);

    $rpcResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/read',
            'has_error' => false,
            'result' => [
                'thread' => [
                    'id' => 'thread_resolved_002',
                    'name' => 'Resolved Thread',
                    'preview' => 'resolved preview',
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($rpcResp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($rpcResp['commands'][0]))->toContain('thread_resolved_002');

    $pdo = $fixture->db();
    $project = $pdo->query("SELECT current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['current_thread_id'] ?? ''))->toBe('thread_resolved_002');

    $taskStmt = $pdo->prepare("SELECT thread_id, status FROM tasks WHERE task_id = ? LIMIT 1");
    $taskStmt->execute([$taskId]);
    $task = $taskStmt->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($task['thread_id'] ?? ''))->toBe('thread_resolved_002');
    expect((string) ($task['status'] ?? ''))->toBe('completed');

    $nextResp = $handler(codex_bot_test_inbound('继续验证新的 thread'));
    expect($nextResp['commands'][1]['method'] ?? null)->toBe('thread/resume');
    $params = json_decode((string) ($nextResp['commands'][1]['params'] ?? ''), true);
    expect((string) ($params['threadId'] ?? ''))->toBe('thread_resolved_002');
});

it('clears stale pending selection after thread/read resolves to a different thread id', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $handler(codex_bot_test_inbound('/use thread_pending_old_001'));

    $threadResp = $handler(codex_bot_test_inbound('/thread'));
    $streamId = (string) ($threadResp['commands'][1]['stream_id'] ?? '');

    $rpcResp = $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $streamId,
            'method' => 'thread/read',
            'has_error' => false,
            'result' => [
                'thread' => [
                    'id' => 'thread_resolved_from_read_002',
                    'name' => 'Resolved Thread',
                    'preview' => 'resolved preview',
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    expect($rpcResp['commands'])->toBeArray()->toHaveCount(1);
    expect(codex_bot_test_fixture()->commandText($rpcResp['commands'][0]))->toContain('thread_resolved_from_read_002');

    $pdo = $fixture->db();
    $pendingCount = (int) $pdo->query(
        "SELECT COUNT(*)
         FROM tasks
         WHERE project_key = 'demo'
           AND task_type = 'use_thread'
           AND status = 'pending_bind'"
    )->fetchColumn();
    expect($pendingCount)->toBe(0);

    $project = $pdo->query("SELECT current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['current_thread_id'] ?? ''))->toBe('thread_resolved_from_read_002');

    $nextResp = $handler(codex_bot_test_inbound('继续走读取后解析出的 thread'));
    expect($nextResp['commands'][1]['method'] ?? null)->toBe('thread/resume');
    $params = json_decode((string) ($nextResp['commands'][1]['params'] ?? ''), true);
    expect((string) ($params['threadId'] ?? ''))->toBe('thread_resolved_from_read_002');
});

it('clears pending selection after successful thread resume bind', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();

    $handler(codex_bot_test_inbound('/use thread_pending_resume_001'));
    $resumeResp = $handler(codex_bot_test_inbound('继续恢复这个 thread'));

    expect($resumeResp['commands'][1]['method'] ?? null)->toBe('thread/resume');
    $resumeStreamId = (string) ($resumeResp['commands'][1]['stream_id'] ?? '');

    $handler([
        'mode' => 'websocket_upstream',
        'provider' => 'codex',
        'event_type' => 'codex.rpc.response',
        'payload' => json_encode([
            'stream_id' => $resumeStreamId,
            'method' => 'thread/resume',
            'has_error' => false,
            'result' => [
                'thread' => [
                    'id' => 'thread_resolved_resume_002',
                ],
            ],
        ], JSON_UNESCAPED_UNICODE),
    ]);

    $pdo = $fixture->db();
    $pendingCount = (int) $pdo->query(
        "SELECT COUNT(*)
         FROM tasks
         WHERE project_key = 'demo'
           AND task_type = 'use_thread'
           AND status = 'pending_bind'"
    )->fetchColumn();
    expect($pendingCount)->toBe(0);

    $project = $pdo->query("SELECT current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['current_thread_id'] ?? ''))->toBe('thread_resolved_resume_002');

    $nextResp = $handler(codex_bot_test_inbound('继续验证 resume 成功后的 thread'));
    expect($nextResp['commands'][1]['method'] ?? null)->toBe('thread/resume');
    $params = json_decode((string) ($nextResp['commands'][1]['params'] ?? ''), true);
    expect((string) ($params['threadId'] ?? ''))->toBe('thread_resolved_resume_002');
});

it('supports 新会话 alias by resetting thread then starting a fresh task', function (): void {
    $fixture = codex_bot_test_fixture();
    $fixture->bootstrap();
    $handler = $fixture->handler();
    $fixture->startThread($handler);

    $resp = $handler(codex_bot_test_inbound('新会话'));
    expect($resp['commands'] ?? [])->toBeArray()->toHaveCount(2);
    expect($resp['commands'][0]['type'] ?? null)->toBe('provider.message.send');
    expect($resp['commands'][1]['type'] ?? null)->toBe('provider.rpc.call');
    expect($resp['commands'][1]['method'] ?? null)->toBe('thread/start');

    $pdo = $fixture->db();
    $project = $pdo->query("SELECT current_thread_id FROM projects WHERE project_key = 'demo' LIMIT 1")->fetch(PDO::FETCH_ASSOC) ?: [];
    expect((string) ($project['current_thread_id'] ?? ''))->toBe('');
});
