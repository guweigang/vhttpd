<?php

declare(strict_types=1);

require_once __DIR__ . '/VHttpd/Manager.php';
require_once __DIR__ . '/VHttpd/JsonShape.php';
require_once __DIR__ . '/VHttpd/AdminClient.php';
require_once __DIR__ . '/VHttpd/GatewayClient.php';
require_once __DIR__ . '/VHttpd/VHttpd.php';
require_once __DIR__ . '/VHttpd/Psr7Adapter.php';
require_once __DIR__ . '/VHttpd/Attribute/Dispatchable.php';
require_once __DIR__ . '/VHttpd/Upstream/Plan.php';
require_once __DIR__ . '/VSlim/Psr7Adapter.php';
require_once __DIR__ . '/VHttpd/PhpWorker/Client.php';
require_once __DIR__ . '/VHttpd/PhpWorker/StreamResponse.php';
require_once __DIR__ . '/VHttpd/PhpWorker/StreamApp.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Event.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Command.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Command/AbstractCommand.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Command/Factory.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Command/SendCommand.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Command/UpdateCommand.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Content/InteractiveCard.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Content/PostContent.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Content/CardActionValue.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Content/CardButton.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Content/CardMarkdown.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Content/CardActionBlock.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Content/PlainText.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Content/CardHeader.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Event/AbstractEvent.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Event/Factory.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Event/CardActionEvent.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/AbstractMessage.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/Factory.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/TextMessage.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/ImageMessage.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/PostMessage.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/FileMessage.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/AudioMessage.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/MediaMessage.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/Message/StickerMessage.php';
require_once __DIR__ . '/VSlim/App/Feishu/BotAdapter.php';
require_once __DIR__ . '/VSlim/App/Feishu/BotHandler.php';
require_once __DIR__ . '/VSlim/App/Feishu/AbstractBotHandler.php';
require_once __DIR__ . '/VSlim/App/Feishu/BotApp.php';
require_once __DIR__ . '/VSlim/Mcp/App.php';
require_once __DIR__ . '/VHttpd/Upstream/WebSocket/Feishu/McpToolset.php';
require_once __DIR__ . '/VHttpd/PhpWorker/WebSocket/CommandSink.php';
require_once __DIR__ . '/VHttpd/PhpWorker/WebSocket/Connection.php';
require_once __DIR__ . '/VHttpd/PhpWorker/WebSocket/CommandBuffer.php';
require_once __DIR__ . '/VSlim/WebSocket/App.php';
require_once __DIR__ . '/VHttpd/PhpWorker/Server.php';
require_once __DIR__ . '/VSlim/DbGateway/PDO.php';
require_once __DIR__ . '/VSlim/DbGateway/PDOStatement.php';
require_once __DIR__ . '/VSlim/Stream/Response.php';
require_once __DIR__ . '/VSlim/Stream/NdjsonDecoder.php';
require_once __DIR__ . '/VSlim/Stream/SseEncoder.php';
require_once __DIR__ . '/VSlim/Stream/OllamaClient.php';
require_once __DIR__ . '/VSlim/Stream/Factory.php';

if (!function_exists('vhttpd_stream_sse')) {
    function vhttpd_stream_sse(
        iterable $events,
        int $status = 200,
        array $headers = [],
    ): \VPhp\VHttpd\PhpWorker\StreamResponse {
        return \VPhp\VHttpd\PhpWorker\StreamResponse::sse($events, $status, $headers);
    }
}

if (!function_exists('vhttpd_stream_text')) {
    function vhttpd_stream_text(
        iterable $chunks,
        int $status = 200,
        string $contentType = 'text/plain; charset=utf-8',
        array $headers = [],
    ): \VPhp\VHttpd\PhpWorker\StreamResponse {
        return \VPhp\VHttpd\PhpWorker\StreamResponse::text($chunks, $status, $contentType, $headers);
    }
}
