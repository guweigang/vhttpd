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
        );

        return self::$isVHttpd;
    }

    /**
     * 获取当前的运行模式：'full' | 'restricted'
     * 在非 vhttpd 环境下强制返回 'restricted' 模式
     */
    public static function getMode(): string
    {
        if (!self::isVHttpd()) {
            return 'restricted';
        }

        if (self::$cachedMode !== null) {
            return self::$cachedMode;
        }

        // 优先尝试从本地配置文件中读取（此方法在 WP 核心数据库尚未建立连接的非常早期也能工作）
        $modeFile = self::getModeFilePath();
        if (is_file($modeFile)) {
            $mode = trim((string)@file_get_contents($modeFile));
            if ($mode === 'full' || $mode === 'restricted') {
                self::$cachedMode = $mode;
                return $mode;
            }
        }

        // 降级尝试从数据库读取（在 WordPress 数据库连接加载完毕后）
        if (function_exists('get_option')) {
            $dbMode = get_option('v_profiler_mode');
            if ($dbMode === 'full' || $dbMode === 'restricted') {
                self::$cachedMode = $dbMode;
                return $dbMode;
            }
        }

        // 默认兜底
        return 'full';
    }

    /**
     * 判断是否是完整模式
     */
    public static function isFullMode(): bool
    {
        return self::getMode() === 'full';
    }

    /**
     * 物理切换运行模式并同步所有文件状态
     * @return bool 是否成功
     */
    public static function switchMode(string $targetMode): bool
    {
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
        // 1. 部署必须的 mu-plugins 加载器
        self::deployMuLoader();

        // 2. 确定初始模式并保存
        $savedMode = false;
        if (function_exists('get_option')) {
            $savedMode = get_option('v_profiler_mode');
        }

        if ($savedMode === false) {
            $savedMode = self::isVHttpd() ? 'full' : 'restricted';
            if (function_exists('update_option')) {
                update_option('v_profiler_mode', $savedMode);
            }
        }

        // 同步状态配置文件
        self::writeModeFile($savedMode);

        // 如果是完整模式，自动部署 Drop-ins 文件
        if ($savedMode === 'full') {
            self::deployDropins();
        }
    }

    /**
     * 停用插件时的清理逻辑
     */
    public static function deactivate(): void
    {
        self::removeMuLoader();
        self::removeModeFile();
        self::removeDropins();
    }

    /**
     * 部署 Drop-ins 到 wp-content
     */
    private static function deployDropins(): bool
    {
        $contentDir = self::getWpContentDir();
        if ($contentDir === '' || !is_writable($contentDir)) {
            return false;
        }

        $dbSrc = self::getPluginDir() . '/db.php';
        $ocSrc = self::getPluginDir() . '/object-cache.php';

        if (!is_file($dbSrc) || !is_file($ocSrc)) {
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

        if (function_exists('update_option')) {
            update_option('v_profiler_mode', 'full');
        }
        self::writeModeFile('full');
        self::resetOpcache();

        return true;
    }

    /**
     * 清理 Drop-ins 回退到受限模式
     */
    private static function enableRestrictedMode(): void
    {
        self::removeDropins();
        
        if (function_exists('update_option')) {
            update_option('v_profiler_mode', 'restricted');
        }
        self::writeModeFile('restricted');
        self::resetOpcache();
    }

    /**
     * 写入模式配置文件
     */
    private static function writeModeFile(string $mode): void
    {
        $contentDir = self::getWpContentDir();
        if ($contentDir !== '' && is_writable($contentDir)) {
            @file_put_contents($contentDir . '/.v-profiler-mode', $mode);
        }
    }

    /**
     * 删除模式配置文件
     */
    private static function removeModeFile(): void
    {
        $file = self::getModeFilePath();
        if (is_file($file)) {
            @unlink($file);
        }
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
 * Description: High-performance MUST-USE loader for v-Profiler telemetry module (vhttpd).
 * Version: 0.1.0
 * Author: guweigang
 *
 * Auto-generated by v-Profiler plugin. Do not edit directly.
 */
declare(strict_types=1);

if (file_exists(WP_PLUGIN_DIR . '/v-profiler/v-profiler.php')) {
    require_once WP_PLUGIN_DIR . '/v-profiler/v-profiler.php';
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
     * 物理删除 wp-content 下的 Drop-ins
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
        if (defined('WP_PLUGIN_DIR')) {
            return WP_PLUGIN_DIR . '/v-profiler';
        }
        $contentDir = self::getWpContentDir();
        return $contentDir !== '' ? $contentDir . '/plugins/v-profiler' : '';
    }

    private static function getModeFilePath(): string
    {
        $contentDir = self::getWpContentDir();
        return $contentDir !== '' ? $contentDir . '/.v-profiler-mode' : '';
    }
}
