<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\CommandContextRepository;
use CodexBot\Repository\ProjectChannelRepository;
use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\SettingsRepository;
use CodexBot\Repository\TaskRepository;
use CodexBot\Service\CodexSessionService;
use CodexBot\Service\CommandFactory;
use CodexBot\Service\StreamService;
use CodexBot\Service\TaskStateService;
use CodexBot\Service\WorkerAdminService;

final class FeishuCommandRouter
{
    private const DEFAULT_MODEL = 'gpt-5.3-codex';

    public function __construct(
        private ProjectRepository $projectRepo,
        private ProjectChannelRepository $channelRepo,
        private CommandContextRepository $commandContextRepo,
        private SettingsRepository $settingsRepo,
        private TaskRepository $taskRepo,
        private StreamService $streamService,
        private CodexSessionService $sessionService,
        private TaskStateService $taskStateService,
        private WorkerAdminService $workerAdminService,
        private BotContextHelper $contextHelper,
        private BotResponseHelper $responseHelper,
        private ThreadViewHelper $threadViewHelper,
    ) {
    }

    public function refreshProjectContext(?array $project): ?array
    {
        if (!is_array($project) || $project === []) {
            return null;
        }

        $projectKey = trim((string) ($project['project_key'] ?? ''));
        if ($projectKey === '') {
            return $project;
        }

        $fresh = $this->projectRepo->findByProjectKey($projectKey);
        if (!is_array($fresh) || $fresh === []) {
            return $project;
        }

        foreach (['channel_thread_key', 'is_primary', 'channel_is_active'] as $key) {
            if (array_key_exists($key, $project)) {
                $fresh[$key] = $project[$key];
            }
        }

        return $fresh;
    }

    public function dispatch(string $text, ?array &$project, string $chatId, string $sender, array $payload): ?array
    {
        $helpResponse = $this->handleHelpCommand($text, $chatId);
        if ($helpResponse !== null) {
            return $helpResponse;
        }

        $createResponse = $this->handleCreateCommand($text, $chatId, $project);
        if ($createResponse !== null) {
            return $createResponse;
        }

        $importResponse = $this->handleImportCommand($text, $chatId, $project);
        if ($importResponse !== null) {
            return $importResponse;
        }

        $settingsResponse = $this->handleSettingsCommand($text, $chatId);
        if ($settingsResponse !== null) {
            return $settingsResponse;
        }

        $bindResponse = $this->handleBindCommand($text, $chatId);
        if ($bindResponse !== null) {
            return $bindResponse;
        }

        $cancelResponse = $this->handleCancelCommand($text, $chatId);
        if ($cancelResponse !== null) {
            return $cancelResponse;
        }

        $workerResponse = $this->handleWorkerCommand($text, $chatId);
        if ($workerResponse !== null) {
            return $workerResponse;
        }

        $configResponse = $this->handleConfigCommand($text, $project, $chatId, $sender, $payload);
        if ($configResponse !== null) {
            return $configResponse;
        }

        $listingResponse = $this->handleListingCommand($text, $project, $chatId, $sender, $payload);
        if ($listingResponse !== null) {
            return $listingResponse;
        }

        $selectionResponse = $this->handleSelectionCommand($text, $project, $chatId, $sender, $payload);
        if ($selectionResponse !== null) {
            return $selectionResponse;
        }

        $resetResponse = $this->handleResetCommand($text, $chatId, $project);
        if ($resetResponse !== null) {
            return $resetResponse;
        }

        return $this->handleRegularTaskCommand($text, $project, $chatId, $sender, $payload);
    }

    private function handleHelpCommand(string $text, string $chatId): ?array
    {
        if ($text !== '/help' && $text !== 'help' && $text !== '帮助') {
            return null;
        }

        $this->clearSelectionScope($chatId);

        return $this->responseHelper->command(CommandFactory::feishuSend([
            'target_type' => 'chat_id',
            'target' => $chatId,
            'message_type' => 'interactive',
            'content' => json_encode([
                'header' => ['title' => ['tag' => 'plain_text', 'content' => '💡 Codex Bot 帮助手册']],
                'elements' => [[
                    'tag' => 'markdown',
                    'content' => "列表命令：\n" .
                        "- `/projects`: 查看当前聊天已绑定的项目列表\n" .
                        "- `/threads`: 查看当前项目的会话列表\n" .
                        "- `/models`: 查看可用模型列表\n\n" .
                        "选择与查看：\n" .
                        "- `/project [project_key]`: 不带参数时查看当前项目，带参数时切换到指定项目\n" .
                        "- `/thread [thread_id]`: 不带参数时查看当前线程，带参数时暂存并切换到指定线程\n" .
                        "- `/model [model_id]`: 不带参数时查看当前模型，带参数时立即切到该模型并从新 thread 生效\n" .
                        "- `/config <key>`: 查看 Codex 当前配置项，例如 `profile`\n" .
                        "- `/use <value>`: 根据最近一次列表上下文自动选择；默认按 thread 处理\n" .
                        "- `/use latest`: 选择当前项目最近一个 thread\n\n" .
                        "配置：\n" .
                        "- `/settings`: 查看当前全局配置\n" .
                        "- `/setting <name> <value>`: 更新配置，例如 `project_root_dir`\n\n" .
                        "Worker 运维：\n" .
                        "- `/worker status`: 查看当前 PHP worker 池状态\n" .
                        "- `/worker restart`: 重启全部 PHP worker，让最新 PHP 代码立即生效\n\n" .
                        "项目与任务：\n" .
                        "- `/create <project_key>`: 在 `project_root_dir` 下创建并切换到项目\n" .
                        "- `/import <project_key> <path>`: 导入已有目录并切换到项目\n" .
                        "- `/bind <project_key>`: 绑定项目到当前聊天，但不切换主项目\n" .
                        "- `/new [model_id]`: 清空当前 thread；带模型时同时切到该模型并新开会话\n" .
                        "- `/cancel`: 取消当前聊天最近一条未完成任务\n\n" .
                        "普通文本消息会在当前项目上下文中执行任务。"
                ]],
            ], JSON_UNESCAPED_UNICODE),
        ]));
    }

    private function handleCreateCommand(string $text, string $chatId, ?array &$project): ?array
    {
        if (strpos($text, '/create') !== 0) {
            return null;
        }

        if (!preg_match('/^\/create\s+(\S+)$/', $text, $matches)) {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **创建项目命令格式不正确**\n\n请使用：`/create <project_key>`",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $projectKey = trim((string) ($matches[1] ?? ''));
        if ($this->projectRepo->findByProjectKey($projectKey)) {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **项目已存在**\n\n项目：`{$projectKey}` 已经存在，不能重复创建。",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $projectRootDir = trim((string) ($this->settingsRepo->findValue('project_root_dir') ?? ''));
        if ($projectRootDir === '') {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **还没有配置项目根目录**\n\n请先执行：`/setting project_root_dir <path>`",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $projectRootDir = rtrim($projectRootDir, DIRECTORY_SEPARATOR);
        $repoPath = $projectRootDir . DIRECTORY_SEPARATOR . $projectKey;
        if (!is_dir($repoPath) && !mkdir($repoPath, 0777, true) && !is_dir($repoPath)) {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **项目目录创建失败**\n\n目标路径：`{$repoPath}`",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $this->projectRepo->save([
            'project_key' => $projectKey,
            'name' => $projectKey,
            'repo_path' => $repoPath,
            'default_branch' => 'main',
            'current_model' => null,
            'current_thread_id' => null,
            'current_cwd' => $repoPath,
        ]);
        $this->channelRepo->bindOrSwitchProject($projectKey, 'feishu', $chatId);
        $project = $this->channelRepo->findProjectByTarget('feishu', $chatId);
        $this->clearSelectionScope($chatId);

        $md = "🆕 **项目已创建并切换**\n\n" .
            "• **项目**: `{$projectKey}`\n" .
            "• **路径**: `{$repoPath}`\n" .
            "• **默认分支**: `main`\n" .
            "• **默认模型**: `" . self::DEFAULT_MODEL . "`\n\n" .
            "接下来你直接发任务，就会在这个项目里启动。";

        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function handleImportCommand(string $text, string $chatId, ?array &$project): ?array
    {
        if (strpos($text, '/import') !== 0) {
            return null;
        }

        if (!preg_match('/^\/import\s+(\S+)\s+(.+)$/', $text, $matches)) {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **导入项目命令格式不正确**\n\n请使用：`/import <project_key> <path>`",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $projectKey = trim((string) ($matches[1] ?? ''));
        if ($this->projectRepo->findByProjectKey($projectKey)) {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **项目已存在**\n\n项目：`{$projectKey}` 已经存在，不能重复导入。",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $rawPath = trim((string) ($matches[2] ?? ''));
        $repoPath = rtrim($rawPath, DIRECTORY_SEPARATOR);
        if ($repoPath === '' || !is_dir($repoPath)) {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **项目目录不存在**\n\n目标路径：`{$rawPath}`",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $resolvedPath = realpath($repoPath);
        if (is_string($resolvedPath) && $resolvedPath !== '') {
            $repoPath = $resolvedPath;
        }

        $this->projectRepo->save([
            'project_key' => $projectKey,
            'name' => $projectKey,
            'repo_path' => $repoPath,
            'default_branch' => 'main',
            'current_model' => null,
            'current_thread_id' => null,
            'current_cwd' => $repoPath,
        ]);
        $this->channelRepo->bindOrSwitchProject($projectKey, 'feishu', $chatId);
        $project = $this->channelRepo->findProjectByTarget('feishu', $chatId);
        $this->clearSelectionScope($chatId);

        $md = "📥 **项目已导入并切换**\n\n" .
            "• **项目**: `{$projectKey}`\n" .
            "• **路径**: `{$repoPath}`\n" .
            "• **默认分支**: `main`\n" .
            "• **默认模型**: `" . self::DEFAULT_MODEL . "`\n\n" .
            "接下来你直接发任务，就会在这个项目里启动。";

        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function handleSettingsCommand(string $text, string $chatId): ?array
    {
        if ($text === '/settings') {
            $this->clearSelectionScope($chatId);
            $settings = $this->settingsRepo->findAll();
            if ($settings === []) {
                return $this->responseHelper->command(
                    CommandFactory::feishuSendMarkdown(
                        $chatId,
                        "⚠️ **当前还没有任何配置**\n\n可以使用 `/setting project_root_dir <path>` 先设置项目根目录。",
                        '',
                        JSON_UNESCAPED_UNICODE
                    )
                );
            }

            $md = "⚙️ **当前配置**\n\n";
            foreach ($settings as $setting) {
                $name = (string) ($setting['name'] ?? '');
                $value = (string) ($setting['value'] ?? '');
                $md .= "• `{$name}` = `{$value}`\n";
            }

            return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
        }

        if (!preg_match('/^\/setting\s+(\S+)\s+(.+)$/', $text, $matches)) {
            return null;
        }

        $name = trim((string) ($matches[1] ?? ''));
        $value = trim((string) ($matches[2] ?? ''));
        $this->clearSelectionScope($chatId);
        $this->settingsRepo->upsert($name, $value);

        return $this->responseHelper->command(
            CommandFactory::feishuSendMarkdown(
                $chatId,
                "⚙️ **配置已更新**\n\n• `{$name}` = `{$value}`",
                '',
                JSON_UNESCAPED_UNICODE
            )
        );
    }

    private function handleBindCommand(string $text, string $chatId): ?array
    {
        if (!preg_match('/^\/bind\s+(\S+)$/', $text, $matches)) {
            return null;
        }

        $projectKey = trim((string) ($matches[1] ?? ''));
        $targetProject = $this->projectRepo->findByProjectKey($projectKey);
        if (!$targetProject) {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **项目不存在**\n\n没有找到项目：`{$projectKey}`",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $alreadyBound = false;
        foreach ($this->channelRepo->listProjectsByTarget('feishu', $chatId) as $boundProject) {
            if (($boundProject['project_key'] ?? '') === $projectKey) {
                $alreadyBound = true;
                break;
            }
        }

        $this->channelRepo->bindProject($projectKey, 'feishu', $chatId);
        $projects = $this->channelRepo->listProjectsByTarget('feishu', $chatId);
        $primaryProjectKey = '';
        foreach ($projects as $boundProject) {
            if ((int) ($boundProject['is_primary'] ?? 0) === 1) {
                $primaryProjectKey = (string) ($boundProject['project_key'] ?? '');
                break;
            }
        }

        $this->clearSelectionScope($chatId);
        $md = "🔗 **项目已绑定到当前聊天**\n\n" .
            "• **项目**: {$targetProject['name']}\n" .
            "• **Key**: `{$targetProject['project_key']}`\n" .
            "• **路径**: `{$targetProject['repo_path']}`\n" .
            "• **是否已存在绑定**: " . ($alreadyBound ? '是，已恢复为激活状态' : '否，已新增绑定') . "\n" .
            "• **当前主项目**: `" . ($primaryProjectKey !== '' ? $primaryProjectKey : '尚未设置') . "`\n\n" .
            "如果要立刻切换到这个项目，请发送 `/project {$projectKey}`。";
        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function handleCancelCommand(string $text, string $chatId): ?array
    {
        if ($text !== '/cancel') {
            return null;
        }

        $this->clearSelectionScope($chatId);
        $task = $this->taskRepo->findLatestCancelableTask('feishu', $chatId);
        if (!$task) {
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **当前没有可取消的任务**\n\n最近没有处于 `queued` 或 `streaming` 状态的普通任务。",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $taskId = (string) ($task['task_id'] ?? '');
        $streamId = (string) ($task['stream_id'] ?? '');
        $prompt = trim((string) ($task['prompt'] ?? ''));
        $message = "🛑 **任务已取消**\n\n" .
            "• **任务**: `{$taskId}`\n" .
            ($prompt !== '' ? "• **内容**: {$prompt}\n" : '') .
            "\n后续如果 Codex 还有迟到事件，我们也会忽略，不再继续刷新这条消息。";

        $this->taskStateService->markCancelled($taskId, $streamId, 'Cancelled by user');
        $responseMessageId = trim((string) ($task['response_message_id'] ?? ''));
        if ($streamId !== '' && $responseMessageId !== '') {
            return $this->responseHelper->command(CommandFactory::feishuMessageUpdate([
                'stream_id' => $streamId,
                'target' => $responseMessageId,
                'message_type' => 'interactive',
                'content' => json_encode([
                    'elements' => [
                        ['tag' => 'markdown', 'content' => $message],
                    ],
                ], JSON_UNESCAPED_UNICODE),
            ]));
        }

        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $message, '', JSON_UNESCAPED_UNICODE));
    }

    private function handleWorkerCommand(string $text, string $chatId): ?array
    {
        if ($text === '/worker status') {
            $this->clearSelectionScope($chatId);
            $result = $this->workerAdminService->status();
            if (($result['ok'] ?? false) !== true) {
                $error = trim((string) ($result['error'] ?? '读取 worker 状态失败'));
                $status = (int) ($result['status'] ?? 0);
                $suffix = $status > 0 ? "\n\nHTTP 状态：`{$status}`" : '';

                return $this->responseHelper->command(
                    CommandFactory::feishuSendMarkdown(
                        $chatId,
                        "⚠️ **读取 PHP worker 状态失败**\n\n{$error}{$suffix}",
                        '',
                        JSON_UNESCAPED_UNICODE
                    )
                );
            }

            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    $this->renderWorkerStatusMarkdown((array) ($result['data'] ?? [])),
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        if ($text === '/worker restart') {
            $this->clearSelectionScope($chatId);
            $md = "♻️ **PHP worker 即将重启**\n\n" .
                "我会先把这条确认消息发出去，然后再由 `vhttpd` 触发全部 worker 重启。\n\n" .
                "建议你过 1 到 2 秒后直接重试刚才的命令，确认最新 PHP 代码已经生效。";

            return $this->responseHelper->commands([
                CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE),
                CommandFactory::adminRestartAllWorkers(),
            ]);
        }

        if (strpos($text, '/worker') === 0) {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **不支持的 worker 命令**\n\n请使用：\n- `/worker status`\n- `/worker restart`",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        return null;
    }

    private function handleConfigCommand(
        string $text,
        ?array $project,
        string $chatId,
        string $sender,
        array $payload
    ): ?array {
        $configKey = '';
        if (preg_match('/^\/config\s+(\S+)$/', $text, $matches)) {
            $configKey = trim((string) ($matches[1] ?? ''));
        } elseif ($text === '/config') {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **缺少配置项名称**\n\n请使用 `/config <key>`，例如 `/config profile`。",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        } else {
            return null;
        }

        $this->clearSelectionScope($chatId);
        if (!$project) {
            return $this->responseHelper->command(
                CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法读取当前 Codex 配置。')
            );
        }

        $res = $this->streamService->createStreamTask([
            'platform' => 'feishu',
            'channel_id' => $chatId,
            'project_key' => $project['project_key'],
            'prompt' => $configKey,
            'user_id' => $sender,
            'request_message_id' => $payload['event']['message']['message_id'] ?? null,
            'thread_id' => $this->contextHelper->preferredThreadId($project),
            'task_type' => 'config_read',
        ]);

        $streamId = $res['stream_id'];
        return $this->responseHelper->commands([
            CommandFactory::feishuSendMarkdown($chatId, "🪪 **正在读取 Codex 配置...**\n\n> {$configKey}", $streamId),
            CommandFactory::codexRpcCall('config/read', [
                'key' => $configKey,
            ], $streamId),
        ]);
    }

    private function handleListingCommand(
        string $text,
        ?array $project,
        string $chatId,
        string $sender,
        array $payload
    ): ?array {
        if ($text === '/projects') {
            $this->rememberSelectionScope($chatId, 'project');
            $projects = $this->channelRepo->listProjectsByTarget('feishu', $chatId);
            if ($projects === []) {
                $md = "⚠️ **当前聊天还没有绑定项目**\n\n可以先使用 `/create <project_key>` 新建项目，或者 `/bind <project_key>` 绑定已有项目。";
            } else {
                $md = "📂 **当前聊天已绑定项目**\n\n";
                foreach ($projects as $boundProject) {
                    $isPrimary = (int) ($boundProject['is_primary'] ?? 0) === 1;
                    $marker = $isPrimary ? '⭐ 当前项目' : '• 已绑定项目';
                    $currentThread = (string) ($boundProject['current_thread_id'] ?? '');
                    $currentModel = trim((string) ($boundProject['current_model'] ?? ''));
                    $md .= "{$marker}\n";
                    $md .= "• **Key**: `{$boundProject['project_key']}`\n";
                    $md .= "• **名称**: {$boundProject['name']}\n";
                    $md .= "• **路径**: `{$boundProject['repo_path']}`\n";
                    $md .= "• **分支**: `{$boundProject['default_branch']}`\n";
                    $md .= "• **模型**: `" . ($currentModel !== '' ? $currentModel : self::DEFAULT_MODEL) . "`\n";
                    $md .= "• **当前 Thread**: `" . ($currentThread !== '' ? $currentThread : '尚未绑定') . "`\n\n";
                }
                $md .= "你可以发送 `/use <project_key>` 或 `/project <project_key>` 进行切换。";
            }

            return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
        }

        if ($text === '/threads') {
            if (!$project) {
                $this->clearSelectionScope($chatId);
                return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法按项目查看 Codex 历史线程。'));
            }

            $this->rememberSelectionScope($chatId, 'thread');
            $res = $this->streamService->createStreamTask([
                'platform' => 'feishu',
                'channel_id' => $chatId,
                'project_key' => $project['project_key'],
                'prompt' => '查看当前项目的 Codex 历史线程',
                'user_id' => $sender,
                'request_message_id' => $payload['event']['message']['message_id'] ?? null,
                'thread_id' => null,
                'task_type' => 'thread_list',
            ]);
            $streamId = $res['stream_id'];
            $cwd = ($project['current_cwd'] ?? '') ?: ($project['repo_path'] ?? '');
            return $this->responseHelper->commands([
                CommandFactory::feishuSendMarkdown($chatId, '🔍 **正在调取 Codex 历史线程列表...**', $streamId),
                CommandFactory::codexRpcCall('thread/list', [
                    'limit' => 10,
                    'cwd' => $cwd,
                ], $streamId),
            ]);
        }

        if ($text === '/models') {
            $this->rememberSelectionScope($chatId, 'model');
            $streamId = "rpc:models:" . uniqid();
            return $this->responseHelper->commands([
                CommandFactory::feishuSendMarkdown($chatId, '🤖 **正在调取 Codex 可用模型列表...**', $streamId),
                CommandFactory::codexRpcCall('model/list', [
                    'provider' => null,
                    'model' => null,
                    'effort' => null,
                ], $streamId),
            ]);
        }

        return null;
    }

    private function handleSelectionCommand(
        string $text,
        ?array &$project,
        string $chatId,
        string $sender,
        array $payload
    ): ?array {
        if ($text === '/project' || $text === '/current') {
            $this->clearSelectionScope($chatId);
            return $this->showCurrentProject($project, $chatId);
        }

        if (preg_match('/^\/project\s+(\S+)$/', $text, $matches) || preg_match('/^\/switch\s+(\S+)$/', $text, $matches)) {
            $this->clearSelectionScope($chatId);
            return $this->selectProject(trim((string) ($matches[1] ?? '')), $chatId, $project);
        }

        if ($text === '/thread latest') {
            $this->clearSelectionScope($chatId);
            return $this->showThreadLatest($project, $chatId);
        }

        if ($text === '/thread recent') {
            $this->clearSelectionScope($chatId);
            return $this->showThreadRecent($project, $chatId);
        }

        if ($text === '/thread') {
            $this->clearSelectionScope($chatId);
            return $this->showCurrentThread($project, $chatId, $sender, $payload);
        }

        if (preg_match('/^\/thread\s+(\S+)$/', $text, $matches)) {
            $this->clearSelectionScope($chatId);
            return $this->selectThread(trim((string) ($matches[1] ?? '')), $project, $chatId, $sender, $payload);
        }

        if ($text === '/model') {
            $this->clearSelectionScope($chatId);
            return $this->showCurrentModel($project, $chatId);
        }

        if (preg_match('/^\/model\s+(\S+)$/', $text, $matches)) {
            $this->clearSelectionScope($chatId);
            return $this->selectModel(trim((string) ($matches[1] ?? '')), $project, $chatId);
        }

        if ($text === '/use') {
            $this->clearSelectionScope($chatId);
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **缺少选择目标**\n\n请使用 `/use <value>`，或者直接使用 `/project <key>`、`/thread <id>`、`/model <id>`。",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        if (!preg_match('/^\/use\s+(\S+)$/', $text, $matches)) {
            return null;
        }

        $value = trim((string) ($matches[1] ?? ''));
        $scope = $this->selectionScope($chatId);
        $this->clearSelectionScope($chatId);

        if ($value === 'latest' && $scope !== 'thread') {
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **当前上下文不支持 `/use latest`**\n\n只有在线程列表上下文里，`/use latest` 才表示选择最近一个 thread。",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        if ($scope === 'project') {
            return $this->selectProject($value, $chatId, $project);
        }

        if ($scope === 'model') {
            return $this->selectModel($value, $project, $chatId);
        }

        if ($value === 'latest') {
            return $this->selectLatestThread($project, $chatId, $sender, $payload);
        }

        return $this->selectThread($value, $project, $chatId, $sender, $payload);
    }

    private function handleResetCommand(string $text, string $chatId, ?array &$project): ?array
    {
        $newModelId = null;
        $isExplicitReset = false;

        if (preg_match('/^\/(?:new|reset)(?:\s+(\S+))?$/', $text, $matches)) {
            $newModelId = trim((string) ($matches[1] ?? ''));
            $isExplicitReset = true;
        }

        if (!$isExplicitReset && strpos($text, '新会话') === false) {
            return null;
        }

        $this->clearSelectionScope($chatId);
        if ($project) {
            $projectKey = (string) $project['project_key'];
            if ($newModelId !== '') {
                $this->sessionService->updateModel($projectKey, $newModelId);
            }
            $this->resetProjectConversationState($projectKey);
            $project = $this->channelRepo->findProjectByTarget('feishu', $chatId);
        }

        if ($isExplicitReset) {
            if ($newModelId !== '') {
                return $this->responseHelper->command(
                    CommandFactory::feishuSendText($chatId, "♻️ **会话已重置并切换模型**\n\n当前模型已切到 `{$newModelId}`，下一条消息会以这个模型启动全新 Codex Thread。")
                );
            }

            return $this->responseHelper->command(
                CommandFactory::feishuSendText($chatId, "♻️ **会话已重置**\n\n发送任意指令将开启全新 Codex Thread。")
            );
        }

        return null;
    }

    private function handleRegularTaskCommand(
        string $text,
        ?array $project,
        string $chatId,
        string $sender,
        array $payload
    ): ?array {
        if (strpos($text, '/') === 0) {
            return null;
        }

        $this->clearSelectionScope($chatId);
        if (!$project) {
            return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 请先创建项目、绑定项目，或切换到一个项目。'));
        }

        $activeThreadId = $this->contextHelper->preferredThreadId($project);
        $res = $this->streamService->createStreamTask([
            'platform' => 'feishu',
            'channel_id' => $chatId,
            'project_key' => $project['project_key'],
            'prompt' => $text,
            'user_id' => $sender,
            'request_message_id' => $payload['event']['message']['message_id'] ?? null,
            'thread_id' => $activeThreadId,
        ]);

        $streamId = $res['stream_id'];
        $commands = [
            CommandFactory::feishuSendMarkdown($chatId, "⚙️ **任务已启动...**\n\n> {$text}", $streamId),
        ];

        if (!$activeThreadId) {
            $model = trim((string) ($project['current_model'] ?? ''));
            $threadParams = [
                'model' => $model !== '' ? $model : self::DEFAULT_MODEL,
                'cwd' => $project['repo_path'],
                'approvalPolicy' => 'never',
                'sandbox' => 'workspace-write',
            ];
            $commands[] = CommandFactory::codexRpcCall('thread/start', $threadParams, $streamId);
        } else {
            $commands[] = CommandFactory::codexRpcCall('thread/resume', [
                'threadId' => $activeThreadId,
            ], $streamId);
        }

        return $this->responseHelper->commands($commands);
    }

    private function showCurrentProject(?array $project, string $chatId): array
    {
        if (!$project) {
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **当前聊天还没有主项目**\n\n可以使用 `/projects` 查看绑定项目，或使用 `/create <project_key>` 新建项目。",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $currentThreadId = trim((string) ($project['current_thread_id'] ?? ''));
        $currentModel = trim((string) ($project['current_model'] ?? ''));
        $pendingSelection = $this->contextHelper->findPendingThreadSelection((string) $project['project_key']);
        $cwd = ($project['current_cwd'] ?? '') ?: ($project['repo_path'] ?? '');
        $md = "🧭 **当前项目**\n\n" .
            "• **项目名称**: `{$project['project_key']}`\n" .
            "• **项目简介**: {$project['name']}\n" .
            "• **路径**: `{$project['repo_path']}`\n" .
            "• **分支**: `{$project['default_branch']}`\n" .
            "• **模型**: `" . ($currentModel !== '' ? $currentModel : self::DEFAULT_MODEL) . "`\n" .
            "• **Thread**: `" . ($currentThreadId !== '' ? $currentThreadId : '尚未绑定') . "`\n" .
            "• **工作目录**: `{$cwd}`\n";
        if ($pendingSelection && !empty($pendingSelection['thread_id'])) {
            $md .= "• **待验证 Thread**: `" . $pendingSelection['thread_id'] . "`\n";
        }

        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function renderWorkerStatusMarkdown(array $snapshot): string
    {
        $workerPoolSize = (int) ($snapshot['worker_pool_size'] ?? 0);
        $workerMaxRequests = (int) ($snapshot['worker_max_requests'] ?? 0);
        $rrIndex = (int) ($snapshot['worker_rr_index'] ?? 0);
        $autostart = !empty($snapshot['worker_autostart']) ? 'on' : 'off';
        $workers = is_array($snapshot['workers'] ?? null) ? $snapshot['workers'] : [];

        $alive = 0;
        $draining = 0;
        $inflight = 0;
        foreach ($workers as $worker) {
            if (!is_array($worker)) {
                continue;
            }
            if (!empty($worker['alive'])) {
                $alive++;
            }
            if (!empty($worker['draining'])) {
                $draining++;
            }
            $inflight += (int) ($worker['inflight_requests'] ?? 0);
        }

        $md = "🧰 **PHP Worker 状态**\n\n" .
            "• **池大小**: `{$workerPoolSize}`\n" .
            "• **存活数**: `{$alive}`\n" .
            "• **Draining**: `{$draining}`\n" .
            "• **Inflight**: `{$inflight}`\n" .
            "• **Autostart**: `{$autostart}`\n" .
            "• **RR Index**: `{$rrIndex}`\n" .
            "• **Max Requests**: `" . ($workerMaxRequests > 0 ? (string) $workerMaxRequests : 'disabled') . "`\n";

        if ($workers !== []) {
            $md .= "\n**Workers**\n";
            foreach ($workers as $worker) {
                if (!is_array($worker)) {
                    continue;
                }
                $id = (int) ($worker['id'] ?? -1);
                $pid = (int) ($worker['pid'] ?? 0);
                $socket = (string) ($worker['socket'] ?? '');
                $rss = (int) ($worker['rss_kb'] ?? 0);
                $served = (int) ($worker['served_requests'] ?? 0);
                $restartCount = (int) ($worker['restart_count'] ?? 0);
                $isAlive = !empty($worker['alive']) ? 'alive' : 'down';
                $isDraining = !empty($worker['draining']) ? 'draining' : 'ready';
                $workerInflight = (int) ($worker['inflight_requests'] ?? 0);
                $md .= "- `#{$id}` {$isAlive} / {$isDraining} / pid=`{$pid}` / inflight=`{$workerInflight}` / served=`{$served}` / restarts=`{$restartCount}` / rss=`{$rss}KB`\n";
                if ($socket !== '') {
                    $md .= "  socket: `{$socket}`\n";
                }
            }
        }

        return $md;
    }

    private function selectProject(string $projectKey, string $chatId, ?array &$project): array
    {
        $targetProject = $this->projectRepo->findByProjectKey($projectKey);
        if (!$targetProject) {
            return $this->responseHelper->command(
                CommandFactory::feishuSendMarkdown(
                    $chatId,
                    "⚠️ **项目不存在**\n\n没有找到项目：`{$projectKey}`",
                    '',
                    JSON_UNESCAPED_UNICODE
                )
            );
        }

        $this->channelRepo->bindOrSwitchProject($projectKey, 'feishu', $chatId);
        $project = $this->channelRepo->findProjectByTarget('feishu', $chatId);
        $currentThread = trim((string) ($project['current_thread_id'] ?? ''));
        $currentModel = trim((string) ($project['current_model'] ?? ''));
        $cwd = ($project['current_cwd'] ?? '') ?: ($project['repo_path'] ?? '');
        $md = "🔀 **已切换当前项目**\n\n" .
            "• **项目**: {$targetProject['name']}\n" .
            "• **Key**: `{$targetProject['project_key']}`\n" .
            "• **路径**: `{$targetProject['repo_path']}`\n" .
            "• **模型**: `" . ($currentModel !== '' ? $currentModel : self::DEFAULT_MODEL) . "`\n" .
            "• **当前 Thread**: `" . ($currentThread !== '' ? $currentThread : '尚未绑定') . "`\n" .
            "• **工作目录**: `{$cwd}`\n\n" .
            "接下来你直接发任务，就会在这个项目上下文里继续。";

        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function showCurrentThread(?array $project, string $chatId, string $sender, array $payload): array
    {
        if (!$project) {
            return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法读取 Codex thread。'));
        }
        if (!$this->contextHelper->preferredThreadId($project)) {
            return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $this->threadViewHelper->missingThreadHint()));
        }

        $threadReadPrompt = '读取当前 thread 详情（name、preview、时间戳等轻量信息）';
        $activeThreadId = $this->contextHelper->preferredThreadId($project) ?? '';
        $res = $this->streamService->createStreamTask([
            'platform' => 'feishu',
            'channel_id' => $chatId,
            'project_key' => $project['project_key'],
            'prompt' => $threadReadPrompt,
            'user_id' => $sender,
            'request_message_id' => $payload['event']['message']['message_id'] ?? null,
            'thread_id' => $activeThreadId,
            'task_type' => 'thread_read',
        ]);

        $streamId = $res['stream_id'];
        return $this->responseHelper->commands([
            CommandFactory::feishuSendMarkdown($chatId, "🧵 **正在读取当前 Thread...**\n\n> {$activeThreadId}", $streamId),
            CommandFactory::codexRpcCall('thread/read', [
                'threadId' => $activeThreadId,
            ], $streamId),
        ]);
    }

    private function showThreadLatest(?array $project, string $chatId): array
    {
        if (!$project) {
            return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法查看最近任务。'));
        }
        $threadId = $this->contextHelper->preferredThreadId($project) ?? '';
        if ($threadId === '') {
            return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $this->threadViewHelper->missingThreadHint()));
        }
        $latest = $this->threadViewHelper->latestThreadTask($this->taskRepo, $threadId);
        $md = $latest
            ? $this->threadViewHelper->renderThreadLatest($latest, $threadId)
            : "🕘 **当前 Thread 最近任务**\n\n• **Thread**: `{$threadId}`\n\n本地还没有记录到这个 thread 的任务历史。";
        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function showThreadRecent(?array $project, string $chatId): array
    {
        if (!$project) {
            return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法查看最近任务。'));
        }
        $threadId = $this->contextHelper->preferredThreadId($project) ?? '';
        if ($threadId === '') {
            return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $this->threadViewHelper->missingThreadHint()));
        }
        $recent = $this->threadViewHelper->recentThreadTasks($this->taskRepo, $threadId, 3);
        $md = $recent
            ? $this->threadViewHelper->renderThreadRecent($recent, $threadId)
            : "🕘 **当前 Thread 最近几次任务**\n\n• **Thread**: `{$threadId}`\n\n本地还没有记录到这个 thread 的最近任务历史。";
        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function selectLatestThread(?array $project, string $chatId, string $sender, array $payload): array
    {
        if (!$project) {
            return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法切换 Codex thread。'));
        }

        $res = $this->streamService->createStreamTask([
            'platform' => 'feishu',
            'channel_id' => $chatId,
            'project_key' => $project['project_key'],
            'prompt' => '切换到最近一个可用 thread',
            'user_id' => $sender,
            'request_message_id' => $payload['event']['message']['message_id'] ?? null,
            'thread_id' => null,
            'task_type' => 'use_thread_latest',
        ]);
        $streamId = $res['stream_id'];
        $cwd = ($project['current_cwd'] ?? '') ?: ($project['repo_path'] ?? '');

        return $this->responseHelper->commands([
            CommandFactory::feishuSendMarkdown($chatId, '🧭 **正在读取最近一个 Codex Thread...**', $streamId),
            CommandFactory::codexRpcCall('thread/list', [
                'limit' => 1,
                'cwd' => $cwd,
            ], $streamId),
        ]);
    }

    private function selectThread(
        string $threadId,
        ?array $project,
        string $chatId,
        string $sender,
        array $payload
    ): array {
        if (!$project) {
            return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法切换 Codex thread。'));
        }

        $this->contextHelper->createPendingThreadSelection(
            (string) $project['project_key'],
            $threadId,
            'feishu',
            $chatId,
            $sender ?: null,
            $payload['event']['message']['message_id'] ?? null
        );
        $md = "🧪 **已暂存待验证 Codex Thread**\n\n" .
            "• **Thread**: `{$threadId}`\n" .
            "• **项目名称**: `{$project['project_key']}`\n" .
            "• **项目简介**: {$project['name']}\n" .
            "• **工作目录**: `" . (($project['current_cwd'] ?? '') ?: ($project['repo_path'] ?? '')) . "`\n\n" .
            "下一次你直接发任务，或发送 `/thread` 时，我们会先尝试恢复这个线程；只有恢复成功后，才会正式绑定为当前会话。";
        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function showCurrentModel(?array $project, string $chatId): array
    {
        if (!$project) {
            return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法查看当前模型。'));
        }

        $currentModel = trim((string) ($project['current_model'] ?? ''));
        $md = "🤖 **当前模型**\n\n" .
            "• **项目**: `{$project['project_key']}`\n" .
            "• **模型**: `" . ($currentModel !== '' ? $currentModel : self::DEFAULT_MODEL) . "`\n\n" .
            "可以使用 `/model <model_id>` 切换默认模型。";
        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function selectModel(string $modelId, ?array $project, string $chatId): array
    {
        if (!$project) {
            return $this->responseHelper->command(CommandFactory::feishuSendText($chatId, '⚠️ 当前群尚未绑定项目，无法设置默认模型。'));
        }

        $projectKey = (string) $project['project_key'];
        $this->sessionService->updateModel($projectKey, $modelId);
        $this->resetProjectConversationState($projectKey);
        $md = "🤖 **模型已更新并立即生效**\n\n" .
            "• **项目**: `{$project['project_key']}`\n" .
            "• **模型**: `{$modelId}`\n\n" .
            "当前 thread 已清空；下一条消息会以这个模型启动全新 Codex Thread。";
        return $this->responseHelper->command(CommandFactory::feishuSendMarkdown($chatId, $md, '', JSON_UNESCAPED_UNICODE));
    }

    private function resetProjectConversationState(string $projectKey): void
    {
        $this->sessionService->updateThread($projectKey, null, null);
        $this->contextHelper->clearPendingThreadSelections($projectKey);
    }

    private function rememberSelectionScope(string $chatId, string $scope): void
    {
        $this->commandContextRepo->setSelectionScope('feishu', $chatId, $scope);
    }

    private function clearSelectionScope(string $chatId): void
    {
        $this->commandContextRepo->clearSelectionScope('feishu', $chatId);
    }

    private function selectionScope(string $chatId): string
    {
        return $this->commandContextRepo->findSelectionScope('feishu', $chatId) ?? 'thread';
    }
}
