<?php

declare(strict_types=1);

use VHttpd\Upstream\WebSocket\Feishu\McpToolset;
use VSlim\Mcp\App;

$mcp = McpToolset::register(
    new App(['name' => 'vhttpd-mcp-feishu-demo', 'version' => '0.1.0'], [])
);

return [
    'mcp' => $mcp,
];
