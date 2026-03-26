<?php
declare(strict_types=1);

/**
 * Codex + Feishu Bot Implementation for vhttpd.
 */

$codexBotTz = getenv('VHTTPD_BOT_TZ') ?: getenv('TZ') ?: 'Asia/Shanghai';
date_default_timezone_set($codexBotTz);

require_once __DIR__ . '/codexbot-app/autoload.php';

$runtime = new CodexBot\AppRuntime();
return $runtime->handlers();
