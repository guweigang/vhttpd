<?php
/**
 * v-Profiler Uninstall file
 *
 * This file is automatically executed when the user deletes the plugin via the WordPress admin panel.
 */

if (!defined('WP_UNINSTALL_PLUGIN')) {
    exit;
}

// 1. 清理 wp_options 中的所有持久化设置
delete_option('v_profiler_mode');
delete_option('v_profiler_widget_enabled');
delete_option('v_profiler_secret_token');

// 2. 安全清理可能残留在 wp-content 的加速 Drop-ins
$contentDir = defined('WP_CONTENT_DIR') ? WP_CONTENT_DIR : ABSPATH . 'wp-content';

if (is_dir($contentDir)) {
    $dbFile = $contentDir . '/db.php';
    if (file_exists($dbFile)) {
        $dbContent = @file_get_contents($dbFile);
        if ($dbContent !== false && str_contains($dbContent, 'Wpdb')) {
            @unlink($dbFile);
        }
    }

    $ocFile = $contentDir . '/object-cache.php';
    if (file_exists($ocFile)) {
        $ocContent = @file_get_contents($ocFile);
        if ($ocContent !== false && str_contains($ocContent, 'ObjectCache')) {
            @unlink($ocFile);
        }
    }

    $modeFile = $contentDir . '/.v-profiler-mode';
    if (file_exists($modeFile)) {
        @unlink($modeFile);
    }
}
