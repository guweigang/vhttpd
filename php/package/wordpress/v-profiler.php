<?php
/**
 * Plugin Name: v-Profiler for WordPress
 * Description: Zero-dependency, ultra-performance debugger toolbar for WordPress sites running on vhttpd.
 * Version: 0.1.0
 * Author: Antigravity / Google DeepMind
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

// 确保 autoloader 正常加载
if (!class_exists(\VHttpd\WordPress\Profiler::class)) {
    $autoload = getenv('VHTTPD_PHP_PACKAGE_AUTOLOAD');
    if ((!is_string($autoload) || $autoload === '') && defined('VHTTPD_PHP_PACKAGE_AUTOLOAD')) {
        $autoload = (string) VHTTPD_PHP_PACKAGE_AUTOLOAD;
    }
    if (is_string($autoload) && $autoload !== '' && is_file($autoload)) {
        require_once $autoload;
    } else {
        $vhttpdVendor = getenv('VHTTPD_VENDOR');
        if (is_string($vhttpdVendor) && $vhttpdVendor !== '' && is_file($vhttpdVendor . '/vendor/autoload.php')) {
            require_once $vhttpdVendor . '/vendor/autoload.php';
        } elseif (is_file('/Users/guweigang/Source/vhttpd/php/package/vendor/autoload.php')) {
            require_once '/Users/guweigang/Source/vhttpd/php/package/vendor/autoload.php';
        } elseif (is_file(dirname(__DIR__) . '/vendor/autoload.php')) {
            require_once dirname(__DIR__) . '/vendor/autoload.php';
        }
    }
}

use VHttpd\WordPress\Profiler;

// 1. 全局调试日志函数
if (!function_exists('v_debug')) {
    function v_debug(mixed $var, string $label = ''): void {
        Profiler::log($var, $label, 'debug');
    }
}

if (!function_exists('v_log')) {
    function v_log(string $message, string $label = ''): void {
        Profiler::log($message, $label, 'info');
    }
}

// 2. 尽早开启遥测（捕获插件加载早期的错误与耗时）
Profiler::start();

// 挂载到非常早的过滤器，在 php-worker 模式下，每次请求开始时都会触发
add_filter('determine_current_user', static function ($userId) {
    Profiler::start();
    return $userId;
}, 1);

// 3. 在 init 阶段校验用户身份
add_action('init', static function (): void {
    $debug = defined('WP_DEBUG') && WP_DEBUG;
    $canManage = current_user_can('manage_options');
    
    // 写入诊断日志，方便查看为什么没有激活
    error_log(sprintf(
        '[v-Profiler] Auth Check: WP_DEBUG=%s, current_user_can(manage_options)=%s, request_uri=%s',
        $debug ? 'true' : 'false',
        $canManage ? 'true' : 'false',
        $_SERVER['REQUEST_URI'] ?? 'unknown'
    ));

    if ($debug && $canManage) {
        Profiler::activate();
    } else {
        // 普通访客或调试关闭时，立即停止采集并撤销错误捕获
        Profiler::stopAndDeactivate();
    }
}, 99);
