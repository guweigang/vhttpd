<?php

declare(strict_types=1);

/**
 * Minimal WordPress wp-config.php bridge for the vhttpd DB pool.
 *
 * Usage in wp-config.php:
 *
 * if (($vendor = getenv('VHTTPD_VENDOR')) !== false && $vendor !== '') {
 *     require_once rtrim($vendor, '/') . '/wordpress/vhttpd-db.php';
 * }
 */

$vhttpdPackageRoot = dirname(__DIR__, 2);
$vhttpdWordPressRoot = '';

foreach (get_included_files() as $includedFile) {
    if (basename($includedFile) === 'wp-config.php') {
        $vhttpdWordPressRoot = dirname($includedFile);
        break;
    }
}

if ($vhttpdWordPressRoot === '') {
    $envRoot = getenv('VPHP_WP_ROOT');
    if (is_string($envRoot) && $envRoot !== '') {
        $vhttpdWordPressRoot = rtrim($envRoot, '/');
    }
}

if ($vhttpdWordPressRoot === '') {
    $script = $_SERVER['SCRIPT_FILENAME'] ?? '';
    if (is_string($script) && $script !== '') {
        $vhttpdWordPressRoot = dirname($script);
        if (basename($vhttpdWordPressRoot) === 'wp-admin') {
            $vhttpdWordPressRoot = dirname($vhttpdWordPressRoot);
        }
    }
}

if (!defined('VHTTPD_DB_SOCKET')) {
    define('VHTTPD_DB_SOCKET', getenv('VHTTPD_DB_SOCKET') ?: '/tmp/vhttpd_wp_db.sock');
}
if (!defined('VHTTPD_DB_POOL')) {
    define('VHTTPD_DB_POOL', getenv('VHTTPD_DB_POOL') ?: 'wordpress');
}
if (!defined('VHTTPD_DB_TIMEOUT_MS')) {
    define('VHTTPD_DB_TIMEOUT_MS', (int) (getenv('VHTTPD_DB_TIMEOUT_MS') ?: 3000));
}
if (!defined('VHTTPD_PHP_PACKAGE_AUTOLOAD')) {
    $autoload = $vhttpdPackageRoot . '/vendor/autoload.php';
    if (is_file($autoload)) {
        define('VHTTPD_PHP_PACKAGE_AUTOLOAD', $autoload);
    }
}

spl_autoload_register(static function (string $class) use ($vhttpdPackageRoot): void {
    $prefix = 'VHttpd\\';
    if (!str_starts_with($class, $prefix)) {
        return;
    }

    $relative = str_replace('\\', '/', substr($class, strlen($prefix)));
    $file = $vhttpdPackageRoot . '/src/VHttpd/' . $relative . '.php';
    if (is_file($file)) {
        require_once $file;
    }
});

if (\VHttpd\WordPress\ProfilerEnv::isFullMode() && $vhttpdWordPressRoot !== '' && defined('DB_USER') && defined('DB_PASSWORD') && defined('DB_NAME') && defined('DB_HOST')) {
    $wpdbClass = $vhttpdWordPressRoot . '/wp-includes/class-wpdb.php';
    if (is_file($wpdbClass)) {
        require_once $wpdbClass;
    }

    if (class_exists(\VHttpd\WordPress\Wpdb::class)) {
        global $wpdb;

        if (!isset($wpdb)) {
            $wpdb = new \VHttpd\WordPress\Wpdb(
                DB_USER,
                DB_PASSWORD,
                DB_NAME,
                DB_HOST,
                (string) VHTTPD_DB_SOCKET,
                (string) VHTTPD_DB_POOL,
                (int) VHTTPD_DB_TIMEOUT_MS,
            );
        }
    }
}
