<?php

declare(strict_types=1);

require_once __DIR__ . '/package/src/VSlim/Psr7Adapter.php';
require_once __DIR__ . '/package/src/VHttpd/Upstream/WebSocket/Feishu/Event.php';
require_once __DIR__ . '/package/src/VHttpd/Upstream/WebSocket/Feishu/Message.php';
require_once __DIR__ . '/package/src/VHttpd/Upstream/WebSocket/Feishu/Command.php';
require_once __DIR__ . '/package/src/VSlim/App/Feishu/BotAdapter.php';
require_once __DIR__ . '/package/src/VSlim/App/Feishu/BotHandler.php';
require_once __DIR__ . '/package/src/VSlim/App/Feishu/AbstractBotHandler.php';
require_once __DIR__ . '/package/src/VSlim/App/Feishu/BotApp.php';
require_once __DIR__ . '/app/MyFeishuBot.php';

$app = VSlim\App::demo();
$feishuBotApp = new \VPhp\VSlim\App\Feishu\BotApp(new \VHttpd\App\MyFeishuBot());

$http = static function (mixed $request, array $envelope = []) use ($app): mixed {
    if (is_object($request)) {
        return \VPhp\VSlim\Psr7Adapter::dispatch($app, $request);
    }

    if (is_array($request)) {
        if (method_exists($app, 'dispatch_envelope_worker')) {
            return $app->dispatch_envelope_worker($request);
        }
        if (method_exists($app, 'dispatch_envelope')) {
            return $app->dispatch_envelope($request);
        }
    }

    if ($envelope !== []) {
        if (method_exists($app, 'dispatch_envelope_worker')) {
            return $app->dispatch_envelope_worker($envelope);
        }
        if (method_exists($app, 'dispatch_envelope')) {
            return $app->dispatch_envelope($envelope);
        }
    }

    return [
        'status' => 500,
        'content_type' => 'text/plain; charset=utf-8',
        'body' => 'No request payload available',
    ];
};

return [
    'http' => $http,
    'websocket_upstream' => static fn (array $frame): array => $feishuBotApp->handle($frame),
];
