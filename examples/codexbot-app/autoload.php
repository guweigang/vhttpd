<?php
declare(strict_types=1);

$packageAutoload = dirname(__DIR__, 2) . '/php/package/vendor/autoload.php';
if (is_file($packageAutoload)) {
    require_once $packageAutoload;
}

require_once __DIR__ . '/lib/Db.php';
require_once __DIR__ . '/lib/AppRuntime.php';
require_once __DIR__ . '/lib/Admin/AdminHttpApp.php';
require_once __DIR__ . '/lib/Admin/DashboardController.php';
require_once __DIR__ . '/lib/Admin/AdminMutationService.php';

if (class_exists('VSlim\\Live\\View')) {
    require_once __DIR__ . '/lib/Admin/AdminDashboardLiveView.php';
}

require_once __DIR__ . '/lib/Repository/ProjectRepository.php';
require_once __DIR__ . '/lib/Repository/ProjectChannelRepository.php';
require_once __DIR__ . '/lib/Repository/CommandContextRepository.php';
require_once __DIR__ . '/lib/Repository/SettingsRepository.php';
require_once __DIR__ . '/lib/Repository/TaskRepository.php';
require_once __DIR__ . '/lib/Repository/StreamRepository.php';

require_once __DIR__ . '/lib/Service/ProjectResolver.php';
require_once __DIR__ . '/lib/Service/CodexSessionService.php';
require_once __DIR__ . '/lib/Service/StreamService.php';
require_once __DIR__ . '/lib/Service/TaskStateService.php';
require_once __DIR__ . '/lib/Service/WorkerAdminService.php';
require_once __DIR__ . '/lib/Service/CommandFactory.php';

require_once __DIR__ . '/lib/Upstream/BotContextHelper.php';
require_once __DIR__ . '/lib/Upstream/BotErrorHelper.php';
require_once __DIR__ . '/lib/Upstream/BotJsonHelper.php';
require_once __DIR__ . '/lib/Upstream/BotResponseHelper.php';
require_once __DIR__ . '/lib/Upstream/ThreadViewHelper.php';
require_once __DIR__ . '/lib/Upstream/FeishuMessageParser.php';
require_once __DIR__ . '/lib/Upstream/FeishuCommandRouter.php';
require_once __DIR__ . '/lib/Upstream/FeishuInboundRouter.php';
require_once __DIR__ . '/lib/Upstream/RpcResultProjector.php';
require_once __DIR__ . '/lib/Upstream/NotificationLifecycleRouter.php';
require_once __DIR__ . '/lib/Upstream/RpcResponseRouter.php';
require_once __DIR__ . '/lib/Upstream/CodexNotificationRouter.php';
require_once __DIR__ . '/lib/Upstream/ProviderEventRouter.php';
require_once __DIR__ . '/lib/Upstream/FeishuInboundEventHandler.php';
require_once __DIR__ . '/lib/Upstream/ProviderUpstreamEventHandler.php';
require_once __DIR__ . '/lib/Upstream/UpstreamGraphFactory.php';
