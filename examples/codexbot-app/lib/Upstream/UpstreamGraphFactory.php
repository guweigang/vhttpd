<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

use CodexBot\Repository\ProjectChannelRepository;
use CodexBot\Repository\CommandContextRepository;
use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\SettingsRepository;
use CodexBot\Repository\StreamRepository;
use CodexBot\Repository\TaskRepository;
use CodexBot\Service\CodexSessionService;
use CodexBot\Service\StreamService;
use CodexBot\Service\TaskStateService;
use CodexBot\Service\WorkerAdminService;
use VPhp\VHttpd\Upstream\WebSocket\EventRouter;

final class UpstreamGraphFactory
{
    public function create(): array
    {
        $projectRepo = new ProjectRepository();
        $channelRepo = new ProjectChannelRepository();
        $commandContextRepo = new CommandContextRepository();
        $settingsRepo = new SettingsRepository();
        $taskRepo = new TaskRepository();
        $streamRepo = new StreamRepository();

        $sessionService = new CodexSessionService($projectRepo);
        $streamService = new StreamService($taskRepo, $streamRepo);
        $taskStateService = new TaskStateService($taskRepo, $streamRepo);
        $workerAdminService = new WorkerAdminService();

        $contextHelper = new BotContextHelper($taskRepo);
        $errorHelper = new BotErrorHelper();
        $jsonHelper = new BotJsonHelper();
        $responseHelper = new BotResponseHelper();
        $threadViewHelper = new ThreadViewHelper();
        $messageParser = new FeishuMessageParser($jsonHelper);

        $feishuCommandRouter = new FeishuCommandRouter(
            $projectRepo,
            $channelRepo,
            $commandContextRepo,
            $settingsRepo,
            $taskRepo,
            $streamService,
            $sessionService,
            $taskStateService,
            $workerAdminService,
            $contextHelper,
            $responseHelper,
            $threadViewHelper,
        );
        $feishuInboundRouter = new FeishuInboundRouter(
            $channelRepo,
            $feishuCommandRouter,
            $messageParser,
        );

        $rpcResultProjector = new RpcResultProjector(
            $taskRepo,
            $streamRepo,
            $projectRepo,
            $sessionService,
            $taskStateService,
            $contextHelper,
            $jsonHelper,
            $responseHelper,
            $threadViewHelper,
        );
        $notificationLifecycleRouter = new NotificationLifecycleRouter(
            $taskRepo,
            $taskStateService,
            $contextHelper,
            $errorHelper,
            $responseHelper,
        );
        $codexNotificationRouter = new CodexNotificationRouter(
            $taskRepo,
            $streamRepo,
            $taskStateService,
            $errorHelper,
            $responseHelper,
            $notificationLifecycleRouter,
        );
        $rpcResponseRouter = new RpcResponseRouter(
            $taskRepo,
            $streamRepo,
            $projectRepo,
            $sessionService,
            $taskStateService,
            $errorHelper,
            $responseHelper,
            $rpcResultProjector,
        );
        $providerEventRouter = new ProviderEventRouter(
            $streamRepo,
            $taskStateService,
            $rpcResponseRouter,
            $codexNotificationRouter,
        );

        $feishuInboundEventHandler = new FeishuInboundEventHandler(
            $responseHelper,
            $feishuInboundRouter,
        );
        $providerUpstreamEventHandler = new ProviderUpstreamEventHandler(
            $responseHelper,
            $providerEventRouter,
        );
        $eventRouter = (new EventRouter())
            ->addHandler($feishuInboundEventHandler)
            ->addHandler($providerUpstreamEventHandler);

        return [
            'project_repo' => $projectRepo,
            'channel_repo' => $channelRepo,
            'command_context_repo' => $commandContextRepo,
            'settings_repo' => $settingsRepo,
            'task_repo' => $taskRepo,
            'stream_repo' => $streamRepo,
            'session_service' => $sessionService,
            'stream_service' => $streamService,
            'task_state_service' => $taskStateService,
            'worker_admin_service' => $workerAdminService,
            'context_helper' => $contextHelper,
            'error_helper' => $errorHelper,
            'json_helper' => $jsonHelper,
            'response_helper' => $responseHelper,
            'thread_view_helper' => $threadViewHelper,
            'message_parser' => $messageParser,
            'feishu_command_router' => $feishuCommandRouter,
            'feishu_inbound_router' => $feishuInboundRouter,
            'rpc_result_projector' => $rpcResultProjector,
            'notification_lifecycle_router' => $notificationLifecycleRouter,
            'codex_notification_router' => $codexNotificationRouter,
            'rpc_response_router' => $rpcResponseRouter,
            'provider_event_router' => $providerEventRouter,
            'feishu_inbound_event_handler' => $feishuInboundEventHandler,
            'provider_upstream_event_handler' => $providerUpstreamEventHandler,
            'event_router' => $eventRouter,
        ];
    }
}
