<?php

declare(strict_types=1);

namespace VHttpd\WordPress;

final class ProfilerEnv
{
    private static ?bool $isVHttpd = null;
    private static ?string $cachedMode = null;

    /**
     * 检测当前运行环境是否为 vhttpd Web 服务器
     */
    public static function isVHttpd(): bool
    {
        if (self::$isVHttpd !== null) {
            return self::$isVHttpd;
        }

        $serverSoftware = $_SERVER['SERVER_SOFTWARE'] ?? '';
        self::$isVHttpd = (
            str_contains(strtolower($serverSoftware), 'vhttpd')
            || getenv('VHTTPD_DB_SOCKET') !== false
            || getenv('VHTTPD_CACHE_SOCKET') !== false
            || getenv('VHTTPD_INTERNAL_ADMIN_SOCKET') !== false
            || isset($_SERVER['VHTTPD_DB_SOCKET'])
            || isset($_SERVER['VHTTPD_CACHE_SOCKET'])
            || isset($_SERVER['VHTTPD_INTERNAL_ADMIN_SOCKET'])
            || isset($_ENV['VHTTPD_DB_SOCKET'])
            || isset($_ENV['VHTTPD_CACHE_SOCKET'])
            || isset($_ENV['VHTTPD_INTERNAL_ADMIN_SOCKET'])
        );

        return self::$isVHttpd;
    }

    /**
     * 获取当前的运行模式：'full' | 'restricted'
     * 在非 vhttpd 环境下强制返回 'restricted' 模式。
     * 采用单一事实来源（Single Source of Truth），直接通过物理 Drop-in 文件的存在性来判定。
     */
    public static function getMode(): string
    {
        if (!self::isVHttpd()) {
            return 'restricted';
        }

        if (self::$cachedMode !== null) {
            return self::$cachedMode;
        }

        $wpContentDir = self::getWpContentDir();
        $loaderFile = $wpContentDir . '/mu-plugins/v-profiler-loader.php';
        $dbFile = $wpContentDir . '/db.php';

        // 如果安装并激活了 v-Profiler 插件（loader 存在）
        if (is_file($loaderFile)) {
            // 模式的真实性 100% 绑定到 Drop-ins 物理文件是否在位
            self::$cachedMode = is_file($dbFile) ? 'full' : 'restricted';
        } else {
            // 没有安装插件时，纯 wp-config.php 桥接模式下默认开启 DB 代理
            self::$cachedMode = 'full';
        }

        return self::$cachedMode;
    }

    /**
     * 判断是否是完整模式
     */
    public static function isFullMode(): bool
    {
        return self::getMode() === 'full';
    }

    /**
     * 物理切换运行模式并同步文件状态
     * @return bool 是否成功
     */
    public static function switchMode(string $targetMode): bool
    {
        self::$cachedMode = null; // 重置缓存
        if ($targetMode === 'full') {
            return self::enableFullMode();
        }
        
        self::enableRestrictedMode();
        return true;
    }

    /**
     * 激活插件时的初始化逻辑
     */
    public static function activate(): void
    {
        // 1. 部署 mu-plugins 加载器
        self::deployMuLoader();

        // 2. 环境适配：如果是 vhttpd，默认部署 Drop-ins 以开启完整模式
        if (self::isVHttpd()) {
            self::deployDropins();
        }

        self::resetOpcache();
    }

    /**
     * 停用插件时的清理逻辑
     */
    public static function deactivate(): void
    {
        self::$cachedMode = null;
        self::removeMuLoader();
        self::removeDropins();
        self::resetOpcache();
    }

    /**
     * 部署 Drop-ins 数据库和对象缓存文件
     */
    private static function deployDropins(): bool
    {
        $contentDir = self::getWpContentDir();
        if ($contentDir === '' || !is_writable($contentDir)) {
            return false;
        }

        $pluginDir = self::getPluginDir();
        $dbCandidates = [
            $pluginDir . '/v-profiler/db.php',
            $pluginDir . '/db.php',
        ];
        $ocCandidates = [
            $pluginDir . '/v-profiler/object-cache.php',
            $pluginDir . '/object-cache.php',
        ];

        $dbSrc = '';
        foreach ($dbCandidates as $candidate) {
            if (is_file($candidate)) {
                $dbSrc = $candidate;
                break;
            }
        }

        $ocSrc = '';
        foreach ($ocCandidates as $candidate) {
            if (is_file($candidate)) {
                $ocSrc = $candidate;
                break;
            }
        }

        if ($dbSrc === '' || $ocSrc === '') {
            return false;
        }

        return @copy($dbSrc, $contentDir . '/db.php') && @copy($ocSrc, $contentDir . '/object-cache.php');
    }

    /**
     * 启用完整加速模式
     */
    private static function enableFullMode(): bool
    {
        if (!self::isVHttpd()) {
            return false;
        }

        if (!self::deployDropins()) {
            return false;
        }

        self::resetOpcache();
        return true;
    }

    /**
     * 清理 Drop-ins 回退到受限模式
     */
    private static function enableRestrictedMode(): void
    {
        self::removeDropins();
        self::resetOpcache();
    }

    /**
     * 部署 MU 加载器
     */
    private static function deployMuLoader(): void
    {
        $muDir = self::getMuPluginsDir();
        if ($muDir !== '') {
            if (!is_dir($muDir)) {
                @mkdir($muDir, 0755, true);
            }
            $loaderContent = <<<'PHP'
<?php
/**
 * Plugin Name: v-Profiler Loader
 * Description: High-performance MUST-USE loader for v-Profiler telemetry module.
 * Version: 0.1.0
 * Author: guweigang
 *
 * Auto-generated by v-Profiler plugin. Do not edit directly.
 */
declare(strict_types=1);

$vProfilerEntry = (defined('WP_PLUGIN_DIR') ? WP_PLUGIN_DIR : dirname(__DIR__) . '/plugins') . '/v-profiler/v-profiler.php';
if (file_exists($vProfilerEntry)) {
    require_once $vProfilerEntry;
}
PHP;
            @file_put_contents($muDir . '/v-profiler-loader.php', $loaderContent);
        }
    }

    /**
     * 移除 MU 加载器
     */
    private static function removeMuLoader(): void
    {
        $muDir = self::getMuPluginsDir();
        if ($muDir !== '') {
            $loader = $muDir . '/v-profiler-loader.php';
            if (is_file($loader)) {
                @unlink($loader);
            }
        }
    }

    /**
     * 物理删除 wp-content 下的 Drop-ins 代理文件
     */
    private static function removeDropins(): void
    {
        $contentDir = self::getWpContentDir();
        if ($contentDir === '') {
            return;
        }

        $dbFile = $contentDir . '/db.php';
        if (is_file($dbFile)) {
            $content = @file_get_contents($dbFile);
            if ($content !== false && str_contains($content, 'Wpdb')) {
                @unlink($dbFile);
            }
        }

        $ocFile = $contentDir . '/object-cache.php';
        if (is_file($ocFile)) {
            $content = @file_get_contents($ocFile);
            if ($content !== false && str_contains($content, 'ObjectCache')) {
                @unlink($ocFile);
            }
        }
    }

    /**
     * 重置 Opcache 并清理缓存
     */
    public static function resetOpcache(): void
    {
        if (function_exists('opcache_reset')) {
            @opcache_reset();
        }
        clearstatcache(true);
    }

    // --- 路径辅助方法 ---

    public static function getWpContentDir(): string
    {
        if (defined('WP_CONTENT_DIR')) {
            return WP_CONTENT_DIR;
        }
        if (defined('ABSPATH')) {
            return ABSPATH . 'wp-content';
        }
        // 从包含文件推断
        foreach (get_included_files() as $file) {
            if (str_contains($file, 'wp-config.php')) {
                return dirname($file) . '/wp-content';
            }
        }
        return '';
    }

    private static function getMuPluginsDir(): string
    {
        if (defined('WPMU_PLUGIN_DIR')) {
            return WPMU_PLUGIN_DIR;
        }
        $contentDir = self::getWpContentDir();
        return $contentDir !== '' ? $contentDir . '/mu-plugins' : '';
    }

    private static function getPluginDir(): string
    {
        // 优先使用当前文件物理路径推导的插件根目录
        $dir = dirname(__DIR__, 3);
        if (is_file($dir . '/v-profiler.php')) {
            return $dir;
        }

        if (defined('WP_PLUGIN_DIR')) {
            return WP_PLUGIN_DIR . '/v-profiler';
        }
        $contentDir = self::getWpContentDir();
        return $contentDir !== '' ? $contentDir . '/plugins/v-profiler' : '';
    }
}
