<?php

declare(strict_types=1);

use VHttpd\WordPress\Wpdb;

if (!class_exists(Wpdb::class)) {
    $autoload = getenv('VHTTPD_PHP_PACKAGE_AUTOLOAD');
    if ((!is_string($autoload) || $autoload === '') && defined('VHTTPD_PHP_PACKAGE_AUTOLOAD')) {
        $autoload = (string) VHTTPD_PHP_PACKAGE_AUTOLOAD;
    }
    if (is_string($autoload) && $autoload !== '' && is_file($autoload)) {
        require_once $autoload;
    } elseif (is_file(__DIR__ . '/../vendor/autoload.php')) {
        require_once __DIR__ . '/../vendor/autoload.php';
    }
}

$socket = getenv('VHTTPD_DB_SOCKET');
if (!is_string($socket) || $socket === '') {
    $socket = defined('VHTTPD_DB_SOCKET') ? (string) VHTTPD_DB_SOCKET : '/tmp/vhttpd_db.sock';
}

$pool = getenv('VHTTPD_DB_POOL');
if (!is_string($pool) || $pool === '') {
    $pool = defined('VHTTPD_DB_POOL') ? (string) VHTTPD_DB_POOL : 'default';
}

$timeout = getenv('VHTTPD_DB_TIMEOUT_MS');
$timeoutMs = is_string($timeout) && ctype_digit($timeout) ? (int) $timeout : 1000;

if (!class_exists(Wpdb::class)) {
    // 优雅降级到 WordPress 原生数据库类，防止非 vhttpd 环境或缺少 Autoloader 时网站崩溃
    if (defined('ABSPATH') && defined('WPINC')) {
        require_once ABSPATH . WPINC . '/class-wpdb.php';
        $wpdb = new \wpdb(DB_USER, DB_PASSWORD, DB_NAME, DB_HOST);
    } else {
        // 极端防护，如果连 ABSPATH 都没有
        exit('v-Profiler: Failed to load database class.');
    }
} else {
    $wpdb = new Wpdb(DB_USER, DB_PASSWORD, DB_NAME, DB_HOST, $socket, $pool, $timeoutMs);
}
