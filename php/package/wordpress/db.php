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

$wpdb = new Wpdb(DB_USER, DB_PASSWORD, DB_NAME, DB_HOST, $socket, $pool, $timeoutMs);
