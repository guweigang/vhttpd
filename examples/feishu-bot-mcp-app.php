<?php

declare(strict_types=1);

require_once __DIR__ . "/../php/package/src/VSlim/Psr7Adapter.php";
require_once __DIR__ . "/../php/package/src/VHttpd/Upstream/WebSocket/Feishu/Event.php";
require_once __DIR__ . "/../php/package/src/VHttpd/Upstream/WebSocket/Feishu/Message.php";
require_once __DIR__ . "/../php/package/src/VHttpd/Upstream/WebSocket/Feishu/Command.php";
require_once __DIR__ . "/../php/package/src/VHttpd/AdminClient.php";
require_once __DIR__ . "/../php/package/src/VHttpd/VHttpd.php";
require_once __DIR__ .
    "/../php/package/src/VSlim/App/Feishu/BotAdapter.php";
require_once __DIR__ .
    "/../php/package/src/VSlim/App/Feishu/BotHandler.php";
require_once __DIR__ .
    "/../php/package/src/VSlim/App/Feishu/AbstractBotHandler.php";
require_once __DIR__ . "/../php/package/src/VSlim/App/Feishu/BotApp.php";
require_once __DIR__ . "/../php/package/src/VSlim/Mcp/App.php";
require_once __DIR__ .
    "/../php/package/src/VHttpd/Upstream/WebSocket/Feishu/McpToolset.php";
require_once __DIR__ . "/../php/app/MyFeishuBot.php";

use VPhp\VSlim\App\Feishu\BotApp;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\McpToolset;
use VPhp\VSlim\Mcp\App;

$app = VSlim\App::demo();
$feishuBotApp = new BotApp(new \VHttpd\App\MyFeishuBot());
$mcp = McpToolset::register(
    new App(["name" => "vhttpd-feishu-combo", "version" => "0.1.0"], []),
);

$app->get("/debug/feishu-send", function () {
    $chatId = trim((string) getenv("VHTTPD_FEISHU_TEST_CHAT_ID"));
    if ($chatId === "") {
        return [
            "status" => 500,
            "content_type" => "application/json; charset=utf-8",
            "body" => json_encode([
                "error" => "VHTTPD_FEISHU_TEST_CHAT_ID is not configured",
            ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        ];
    }

    $resp = \VPhp\VHttpd\VHttpd::gateway("feishu")->sendText(
        instance: "main",
        chatId: $chatId,
        text: "hello from VHttpd::gateway()",
    );

    return [
        "status" => 200,
        "content_type" => "application/json; charset=utf-8",
        "body" => json_encode(
            $resp,
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES,
        ),
    ];
});
$app->get("/debug/feishu-image", function () {
    $chatId = trim((string) getenv("VHTTPD_FEISHU_TEST_CHAT_ID"));
    $filePath = trim((string) getenv("VHTTPD_FEISHU_TEST_IMAGE_PATH"));
    if ($chatId === "" || $filePath === "") {
        return [
            "status" => 500,
            "content_type" => "application/json; charset=utf-8",
            "body" => json_encode([
                "error" => "VHTTPD_FEISHU_TEST_CHAT_ID and VHTTPD_FEISHU_TEST_IMAGE_PATH are required",
            ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        ];
    }

    $resp = \VPhp\VHttpd\VHttpd::gateway("feishu")->sendLocalImage(
        instance: "main",
        chatId: $chatId,
        filePath: $filePath,
    );

    return [
        "status" => 200,
        "content_type" => "application/json; charset=utf-8",
        "body" => json_encode(
            $resp,
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES,
        ),
    ];
});
$app->get("/debug/feishu-image-url", function () {
    $chatId = trim((string) getenv("VHTTPD_FEISHU_TEST_CHAT_ID"));
    $imageUrl = trim((string) getenv("VHTTPD_FEISHU_TEST_IMAGE_URL"));
    if ($chatId === "" || $imageUrl === "") {
        return [
            "status" => 500,
            "content_type" => "application/json; charset=utf-8",
            "body" => json_encode([
                "error" => "VHTTPD_FEISHU_TEST_CHAT_ID and VHTTPD_FEISHU_TEST_IMAGE_URL are required",
            ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        ];
    }

    $resp = \VPhp\VHttpd\VHttpd::gateway("feishu")->sendRemoteImage(
        instance: "main",
        chatId: $chatId,
        imageUrl: $imageUrl,
    );

    return [
        "status" => 200,
        "content_type" => "application/json; charset=utf-8",
        "body" => json_encode(
            $resp,
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES,
        ),
    ];
});
$http = static function (mixed $request, array $envelope = []) use (
    $app,
): mixed {
    if (is_object($request)) {
        return \VPhp\VSlim\Psr7Adapter::dispatch($app, $request);
    }

    if (is_array($request)) {
        if (method_exists($app, "dispatch_envelope_worker")) {
            return $app->dispatch_envelope_worker($request);
        }
        if (method_exists($app, "dispatch_envelope")) {
            return $app->dispatch_envelope($request);
        }
    }

    if ($envelope !== []) {
        if (method_exists($app, "dispatch_envelope_worker")) {
            return $app->dispatch_envelope_worker($envelope);
        }
        if (method_exists($app, "dispatch_envelope")) {
            return $app->dispatch_envelope($envelope);
        }
    }

    return [
        "status" => 500,
        "content_type" => "text/plain; charset=utf-8",
        "body" => "No request payload available",
    ];
};

return [
    "http" => $http,
    "websocket_upstream" => static fn(
        array $frame,
    ): array => $feishuBotApp->handle($frame),
    "mcp" => $mcp,
];
