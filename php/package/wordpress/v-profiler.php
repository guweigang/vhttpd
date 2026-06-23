<?php
/**
 * Plugin Name: v-Profiler for WordPress
 * Description: Zero-dependency, ultra-performance debugger toolbar for WordPress sites running on vhttpd.
 * Version: 0.1.0
 * Author: guweigang
 */

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

// PHP 版本兼容性检测 (vhttpd runtime 要求 PHP >= 8.1)
if (version_compare(PHP_VERSION, '8.1.0', '<')) {
    add_action('admin_notices', static function (): void {
        echo '<div class="notice notice-error"><p>';
        echo '<strong>v-Profiler:</strong> This plugin requires PHP version 8.1.0 or higher. Your current PHP version is ' . esc_html(PHP_VERSION) . '.';
        echo '</p></div>';
    });
    return;
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

    // 检查是否在 wp-config.php 中禁用了挂件
    if (defined('V_PROFILER_WIDGET_DISABLED') && V_PROFILER_WIDGET_DISABLED) {
        Profiler::stopAndDeactivate();
        return;
    }
    
    $canManage = current_user_can('manage_options');
    
    // 写入诊断日志，方便查看激活状态
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

// 4. 引入后台管理模块
if (is_admin()) {
    require_once __DIR__ . '/v-profiler/v-profiler-admin.php';
}

// 5. 注册激活与停用钩子以自动配置 MU-Plugin Loader
register_activation_hook(__FILE__, 'v_profiler_activate_plugin');
register_deactivation_hook(__FILE__, 'v_profiler_deactivate_plugin');

function v_profiler_activate_plugin(): void {
    \VHttpd\WordPress\ProfilerEnv::activate();
}

function v_profiler_deactivate_plugin(): void {
    \VHttpd\WordPress\ProfilerEnv::deactivate();
}

