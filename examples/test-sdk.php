<?php

require_once __DIR__ . '/../php/package/vendor/autoload.php';

use VPhp\Provider\Codex\Parser;
use VPhp\Provider\Codex\Notification;

$json = '{"method":"turn/started","params":{"threadId":"thr_123"}}';
$msg = Parser::parse($json);

echo "Type: " . get_class($msg) . "\n";
if ($msg instanceof Notification) {
    echo "Method: " . $msg->getMethod() . "\n";
    echo "ThreadId: " . ($msg->getParams()['threadId'] ?? 'N/A') . "\n";
}
