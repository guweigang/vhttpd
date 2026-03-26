<?php

declare(strict_types=1);

require_once __DIR__ . '/../php/package/src/VHttpd/Upstream/WebSocket/Feishu/Command.php';
require_once __DIR__ . '/../php/package/src/VHttpd/AdminClient.php';
require_once __DIR__ . '/../php/package/src/VHttpd/VHttpd.php';
require_once __DIR__ . '/../php/package/src/VSlim/Mcp/App.php';
require_once __DIR__ . '/../php/package/src/VHttpd/Upstream/WebSocket/Feishu/McpToolset.php';

use VPhp\VHttpd\Upstream\WebSocket\Feishu\McpToolset;
use VPhp\VSlim\Mcp\App;

$mcp = McpToolset::register(
    new App(['name' => 'vhttpd-mcp-feishu-demo', 'version' => '0.1.0'], [])
);

return [
    'mcp' => $mcp,
];
