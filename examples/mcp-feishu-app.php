<?php

declare(strict_types=1);

require_once __DIR__ . '/../php/package/src/VHttpd/Upstream/WebSocket/Feishu/Command.php';
require_once __DIR__ . '/../php/package/src/VHttpd/AdminClient.php';
require_once __DIR__ . '/../php/package/src/VHttpd/VHttpd.php';
if (!class_exists(\VSlim\Mcp\App::class, false)) {
    require_once __DIR__ . '/../php/package/src/VSlim/Mcp/App.php';
}
require_once __DIR__ . '/../php/package/src/VHttpd/Upstream/WebSocket/Feishu/McpToolset.php';

use VHttpd\Upstream\WebSocket\Feishu\McpToolset;
use VSlim\Mcp\App;

$mcp = McpToolset::register(
    new App(['name' => 'vhttpd-mcp-feishu-demo', 'version' => '0.1.0'], [])
);

return [
    'mcp' => $mcp,
];
