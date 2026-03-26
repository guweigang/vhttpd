<?php

require __DIR__ . '/codexbot-app/autoload.php';

use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\ProjectChannelRepository;

$projectRepo = new ProjectRepository();
$channelRepo = new ProjectChannelRepository();

// 1. 初始化项目信息
$projectRepo->save([
    'project_key' => 'vhttpd',
    'name' => 'vhttpd Gateway',
    'repo_path' => '/Users/guweigang/Source/vhttpd',
    'default_branch' => 'feat/codex-upstream',
]);

// 2. 绑定飞书群
$channelRepo->bindChannel([
    'project_key' => 'vhttpd',
    'platform' => 'feishu',
    'channel_id' => 'oc_e89fce0f1979dbf05d0f5303fbe86084',
    'is_primary' => 1,
]);

// 3. (模拟) 如果将来有 Discord
// $channelRepo->bindChannel([
//     'project_key' => 'vhttpd',
//     'platform' => 'discord',
//     'channel_id' => '123456789',
//     'is_primary' => 1,
// ]);

echo "✅ 项目 vhttpd 及其飞书频道已成功初始化。\n";
