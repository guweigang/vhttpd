<?php

declare(strict_types=1);

if (!defined('ABSPATH')) {
    exit;
}

// 注册后台菜单项
add_action('admin_menu', function (): void {
    add_menu_page(
        'v-Profiler Control Panel',
        '📊 v-Profiler',
        'manage_options',
        'v-profiler-settings',
        'v_profiler_render_admin_page',
        'dashicons-performance',
        99
    );
});

// 处理设置页面表单提交
add_action('admin_init', function (): void {
    if (!isset($_POST['v_profiler_action'])) {
        return;
    }

    if (!current_user_can('manage_options')) {
        wp_die('Unauthorized action.');
    }

    check_admin_referer('v_profiler_admin_action', 'v_profiler_nonce');

    $action = sanitize_text_field($_POST['v_profiler_action']);
    $redirect_url = admin_url('admin.php?page=v-profiler-settings');
    if (isset($_SERVER['REQUEST_URI'])) {
        $redirect_url = remove_query_arg(['v_error', 'v_success'], $_SERVER['REQUEST_URI']);
    }

    // 1. Telemetry Widget 开关控制
    if ($action === 'save_widget_settings') {
        $enabled = isset($_POST['widget_enabled']) && $_POST['widget_enabled'] === '1' ? 'yes' : 'no';
        update_option('v_profiler_widget_enabled', $enabled);
        wp_safe_redirect(add_query_arg('v_success', 'widget_updated', $redirect_url));
        exit;
    }

    // 2. 授权调试会话控制 (Debug Session Cookie)
    if ($action === 'start_session' || $action === 'stop_session') {
        $secretToken = get_option('v_profiler_secret_token');
        if (empty($secretToken)) {
            $secretToken = wp_generate_password(32, false);
            update_option('v_profiler_secret_token', $secretToken);
        }

        $cookie_path = defined('COOKIEPATH') ? COOKIEPATH : '/';
        $cookie_domain = defined('COOKIE_DOMAIN') ? COOKIE_DOMAIN : '';

        if ($action === 'start_session') {
            // 下发有效期为 3 天的 Cookie
            setcookie(
                'v_profiler_session',
                $secretToken,
                time() + 3 * 86400,
                $cookie_path,
                $cookie_domain,
                is_ssl(),
                true // HttpOnly
            );
            wp_safe_redirect(add_query_arg('v_success', 'session_started', $redirect_url));
        } else {
            // 清理 Cookie
            setcookie(
                'v_profiler_session',
                '',
                time() - 3600,
                $cookie_path,
                $cookie_domain,
                is_ssl(),
                true
            );
            wp_safe_redirect(add_query_arg('v_success', 'session_stopped', $redirect_url));
        }
        exit;
    }

    // 3. 运行引擎模式切换 (Restricted vs Full vhttpd)
    if ($action === 'switch_mode') {
        $target_mode = sanitize_text_field($_POST['target_mode'] ?? 'restricted');

        $db_src = dirname(__FILE__) . '/db.php';
        $db_dst = WP_CONTENT_DIR . '/db.php';
        $oc_src = dirname(__FILE__) . '/object-cache.php';
        $oc_dst = WP_CONTENT_DIR . '/object-cache.php';

        if ($target_mode === 'full') {
            // 切换到完整加速模式 (部署 Drop-ins)
            if (!is_writable(WP_CONTENT_DIR)) {
                wp_safe_redirect(add_query_arg('v_error', 'dir_not_writable', $redirect_url));
                exit;
            }

            if (!is_file($db_src) || !is_file($oc_src)) {
                wp_safe_redirect(add_query_arg('v_error', 'source_files_missing', $redirect_url));
                exit;
            }

            if (!copy($db_src, $db_dst) || !copy($oc_src, $oc_dst)) {
                wp_safe_redirect(add_query_arg('v_error', 'copy_failed', $redirect_url));
                exit;
            }

            update_option('v_profiler_mode', 'full');
            wp_safe_redirect(add_query_arg('v_success', 'mode_upgraded', $redirect_url));
        } else {
            // 切换到受限模式 (清除 Drop-ins)
            if (is_file($db_dst)) {
                if (!is_writable($db_dst) || !unlink($db_dst)) {
                    wp_safe_redirect(add_query_arg('v_error', 'delete_db_failed', $redirect_url));
                    exit;
                }
            }

            if (is_file($oc_dst)) {
                if (!is_writable($oc_dst) || !unlink($oc_dst)) {
                    wp_safe_redirect(add_query_arg('v_error', 'delete_oc_failed', $redirect_url));
                    exit;
                }
            }

            update_option('v_profiler_mode', 'restricted');
            wp_safe_redirect(add_query_arg('v_success', 'mode_downgraded', $redirect_url));
        }
        exit;
    }
});

// 渲染后台管理页面
function v_profiler_render_admin_page(): void {
    // 状态查询
    $widget_enabled = get_option('v_profiler_widget_enabled', 'yes') === 'yes';
    $current_mode = get_option('v_profiler_mode', 'restricted');

    $db_dst = WP_CONTENT_DIR . '/db.php';
    $oc_dst = WP_CONTENT_DIR . '/object-cache.php';
    
    // 实地检测加速文件是否在位
    $db_active = is_file($db_dst);
    $oc_active = is_file($oc_dst);

    // 调试 Cookie 会话检测
    $session_active = isset($_COOKIE['v_profiler_session']) && $_COOKIE['v_profiler_session'] === get_option('v_profiler_secret_token');

    // 反馈消息处理
    $message = '';
    $message_type = 'success';
    
    if (isset($_GET['v_success'])) {
        $suc = sanitize_text_field($_GET['v_success']);
        if ($suc === 'widget_updated') {
            $message = '调试挂件状态已成功更新！';
        } elseif ($suc === 'session_started') {
            $message = '🎉 调试授权 Cookie 已注入当前浏览器！您现在可以退出登录或切换测试账号，挂件将在本浏览器中正常展示。';
        } elseif ($suc === 'session_stopped') {
            $message = '调试授权 Cookie 已从当前浏览器清除。';
        } elseif ($suc === 'mode_upgraded') {
            $message = '🚀 极速引擎已开启！长连接池与进程共享内存已接管 WordPress。';
        } elseif ($suc === 'mode_downgraded') {
            $message = '已回退至受限模式，所有极速 Drop-ins 已安全移除。';
        }
    } elseif (isset($_GET['v_error'])) {
        $err = sanitize_text_field($_GET['v_error']);
        $message_type = 'error';
        if ($err === 'dir_not_writable') {
            $message = '❌ 权限不足！ wp-content 目录不可写。请在终端执行：<br><code style="background:#f43f5e; color:#fff; padding:2px 6px; border-radius:4px;">chmod 775 ' . esc_html(WP_CONTENT_DIR) . '</code>';
        } elseif ($err === 'source_files_missing') {
            $message = '❌ 部署失败：未能在插件目录中找到 db.php 或 object-cache.php 源文件备份。';
        } elseif ($err === 'copy_failed') {
            $message = '❌ 文件拷贝失败，请检查 wp-content 的属主或权限。';
        } elseif ($err === 'delete_db_failed') {
            $message = '❌ 移除 db.php 失败，请检查文件写入权限。';
        } elseif ($err === 'delete_oc_failed') {
            $message = '❌ 移除 object-cache.php 失败，请检查文件写入权限。';
        }
    }

    ?>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700;800&display=swap');
        
        .v-admin-wrap {
            font-family: 'Outfit', sans-serif;
            background: #0f172a;
            color: #cbd5e1;
            padding: 30px;
            max-width: 960px;
            border-radius: 12px;
            margin: 20px auto 0 0;
            box-shadow: 0 10px 30px rgba(0,0,0,0.25);
            border: 1px solid rgba(255,255,255,0.05);
        }

        .v-admin-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px solid rgba(255,255,255,0.08);
            padding-bottom: 20px;
            margin-bottom: 25px;
        }

        .v-admin-title {
            margin: 0;
            font-size: 26px;
            font-weight: 800;
            background: linear-gradient(135deg, #a78bfa 0%, #ec4899 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            letter-spacing: -0.5px;
        }

        .v-admin-version {
            font-size: 11px;
            background: rgba(167, 139, 250, 0.15);
            color: #c084fc;
            padding: 3px 8px;
            border-radius: 12px;
            font-weight: 700;
        }

        .v-alert {
            padding: 15px;
            border-radius: 8px;
            margin-bottom: 25px;
            font-size: 13px;
            line-height: 1.5;
        }

        .v-alert.success {
            background: rgba(16, 185, 129, 0.08);
            border: 1.5px solid rgba(16, 185, 129, 0.25);
            color: #34d399;
        }

        .v-alert.error {
            background: rgba(239, 68, 68, 0.08);
            border: 1.5px solid rgba(239, 68, 68, 0.25);
            color: #f87171;
        }

        .v-section {
            background: rgba(30, 41, 59, 0.4);
            border: 1px solid rgba(255, 255, 255, 0.03);
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 25px;
        }

        .v-section-title {
            font-size: 16px;
            font-weight: 700;
            color: #f8fafc;
            margin: 0 0 15px 0;
            display: flex;
            align-items: center;
            gap: 8px;
        }

        /* 状态指示网络 */
        .v-status-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }

        .v-status-card {
            background: rgba(15, 23, 42, 0.5);
            border: 1px solid rgba(255,255,255,0.05);
            border-radius: 8px;
            padding: 15px;
            display: flex;
            flex-direction: column;
            gap: 6px;
        }

        .v-status-label {
            font-size: 11px;
            color: #64748b;
            text-transform: uppercase;
            font-weight: 600;
            letter-spacing: 0.5px;
        }

        .v-status-val {
            font-size: 15px;
            font-weight: 700;
            color: #f1f5f9;
            display: flex;
            align-items: center;
            gap: 6px;
        }

        .v-dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            display: inline-block;
        }

        .v-dot.active {
            background: #10b981;
            box-shadow: 0 0 8px #10b981;
        }

        .v-dot.inactive {
            background: #f59e0b;
            box-shadow: 0 0 8px #f59e0b;
        }

        /* 模式大按钮设计 */
        .v-mode-selector {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
            margin-top: 15px;
        }

        .v-mode-box {
            background: rgba(15, 23, 42, 0.3);
            border: 2px solid rgba(255,255,255,0.05);
            border-radius: 12px;
            padding: 25px;
            cursor: pointer;
            transition: all 0.25s ease;
            display: flex;
            flex-direction: column;
            gap: 10px;
            position: relative;
            text-align: left;
        }

        .v-mode-box:hover {
            border-color: rgba(167, 139, 250, 0.3);
            background: rgba(30, 41, 59, 0.2);
            transform: translateY(-2px);
        }

        .v-mode-box.selected {
            border-color: #8b5cf6;
            background: rgba(139, 92, 246, 0.05);
            box-shadow: 0 0 15px rgba(139, 92, 246, 0.15);
        }

        .v-mode-title {
            font-size: 18px;
            font-weight: 800;
            margin: 0;
            color: #f8fafc;
        }

        .v-mode-desc {
            font-size: 11px;
            color: #94a3b8;
            line-height: 1.4;
        }

        .v-badge-mode {
            position: absolute;
            top: 15px;
            right: 15px;
            font-size: 9px;
            padding: 2px 6px;
            border-radius: 4px;
            font-weight: 700;
            text-transform: uppercase;
        }

        .v-badge-mode.green {
            background: rgba(16, 185, 129, 0.15);
            color: #34d399;
        }

        .v-badge-mode.orange {
            background: rgba(245, 158, 11, 0.15);
            color: #fbbf24;
        }

        /* 按钮与表单 */
        .v-btn {
            background: linear-gradient(135deg, #8b5cf6 0%, #6d28d9 100%);
            border: none;
            border-radius: 6px;
            color: #fff;
            font-weight: 700;
            font-size: 12px;
            padding: 10px 20px;
            cursor: pointer;
            transition: all 0.2s;
            display: inline-flex;
            align-items: center;
            gap: 6px;
        }

        .v-btn:hover {
            opacity: 0.9;
            transform: scale(1.02);
        }

        .v-btn.secondary {
            background: rgba(255, 255, 255, 0.08);
            border: 1px solid rgba(255,255,255,0.12);
            color: #cbd5e1;
        }

        .v-btn.secondary:hover {
            background: rgba(255, 255, 255, 0.12);
        }

        .v-toggle-wrap {
            display: flex;
            align-items: center;
            justify-content: space-between;
        }

        /* 开关滑块 */
        .switch {
            position: relative;
            display: inline-block;
            width: 46px;
            height: 24px;
        }

        .switch input { 
            opacity: 0;
            width: 0;
            height: 0;
        }

        .slider {
            position: absolute;
            cursor: pointer;
            top: 0;
            left: 0;
            right: 0;
            bottom: 0;
            background-color: rgba(255,255,255,0.1);
            transition: .3s;
            border-radius: 24px;
            border: 1px solid rgba(255,255,255,0.05);
        }

        .slider:before {
            position: absolute;
            content: "";
            height: 16px;
            width: 16px;
            left: 3px;
            bottom: 3px;
            background-color: #cbd5e1;
            transition: .3s;
            border-radius: 50%;
        }

        input:checked + .slider {
            background-color: #8b5cf6;
        }

        input:checked + .slider:before {
            transform: translateX(22px);
            background-color: #fff;
        }

    </style>

    <div class="v-admin-wrap">
        <div class="v-admin-header">
            <h1 class="v-admin-title">v-Profiler Control Panel</h1>
            <span class="v-admin-version">Telemetry v0.1.0</span>
        </div>

        <?php if (!empty($message)) : ?>
            <div class="v-alert <?php echo esc_attr($message_type); ?>">
                <?php echo wp_kses_post($message); ?>
            </div>
        <?php endif; ?>

        <!-- Section 1: Telemetry Switch -->
        <div class="v-section">
            <form method="post" action="">
                <?php wp_nonce_field('v_profiler_admin_action', 'v_profiler_nonce'); ?>
                <input type="hidden" name="v_profiler_action" value="save_widget_settings">
                <div class="v-toggle-wrap">
                    <div>
                        <h3 class="v-section-title">📊 Debug Telemetry Widget</h3>
                        <p style="margin:0; font-size:11px; color:#64748b;">控制是否在满足授权条件的浏览器底部渲染可视化性能挂件面板。</p>
                    </div>
                    <div style="display:flex; align-items:center; gap:12px;">
                        <label class="switch">
                            <input type="checkbox" name="widget_enabled" value="1" <?php checked($widget_enabled); ?> onchange="this.form.submit()">
                            <span class="slider"></span>
                        </label>
                        <span style="font-size:12px; font-weight:700; color:<?php echo $widget_enabled ? '#34d399' : '#64748b'; ?>;">
                            <?php echo $widget_enabled ? 'ENABLED' : 'DISABLED'; ?>
                        </span>
                    </div>
                </div>
            </form>
        </div>

        <!-- Section 2: Session Auth -->
        <div class="v-section">
            <h3 class="v-section-title">🛡️ 安全调试会话 (Debug Session)</h3>
            <p style="margin:0 0 15px 0; font-size:11px; color:#94a3b8; line-height:1.4;">
                为当前浏览器颁发加密调试 Cookie。开启后，即使您<b>退出登录以游客身份访问</b>或<b>切换为普通用户测试</b>，该浏览器仍能独占看到性能调试挂件，便于模拟访客全链路体验，且外网普通访客绝对无感。
            </p>
            
            <div style="display:flex; justify-content:space-between; align-items:center; background:rgba(0,0,0,0.15); padding:12px; border-radius:6px;">
                <div style="font-size:12px;">
                    会话状态：
                    <strong style="color:<?php echo $session_active ? '#34d399' : '#f59e0b'; ?>;">
                        <?php echo $session_active ? '● 正在运行 (已授权本浏览器)' : '○ 未授权'; ?>
                    </strong>
                </div>
                <form method="post" action="">
                    <?php wp_nonce_field('v_profiler_admin_action', 'v_profiler_nonce'); ?>
                    <?php if ($session_active) : ?>
                        <input type="hidden" name="v_profiler_action" value="stop_session">
                        <button type="submit" class="v-btn secondary">🧹 退出调试会话 (Clear Cookie)</button>
                    <?php else : ?>
                        <input type="hidden" name="v_profiler_action" value="start_session">
                        <button type="submit" class="v-btn">🔑 开启本浏览器游客调试 (Inject Cookie)</button>
                    <?php endif; ?>
                </form>
            </div>
        </div>

        <!-- Section 3: Engine Mode -->
        <div class="v-section">
            <h3 class="v-section-title">⚡ 极速优化引擎 (Performance Engine Mode)</h3>
            <p style="margin:0 0 15px 0; font-size:11px; color:#94a3b8; line-height:1.4;">
                在“受限模式”与“完整模式”之间切换。切换至完整模式将一键接管 WordPress 底层数据库和对象缓存，启用 vhttpd 高并发连接池和进程内缓存。
            </p>

            <div class="v-status-grid">
                <div class="v-status-card">
                    <span class="v-status-label">Database Connection Pool</span>
                    <span class="v-status-val">
                        <span class="v-dot <?php echo $db_active ? 'active' : 'inactive'; ?>"></span>
                        <?php echo $db_active ? 'db.php (Pool Online)' : 'db.php (Direct MySQL)'; ?>
                    </span>
                </div>
                <div class="v-status-card">
                    <span class="v-status-label">Object Cache Multiplexing</span>
                    <span class="v-status-val">
                        <span class="v-dot <?php echo $oc_active ? 'active' : 'inactive'; ?>"></span>
                        <?php echo $oc_active ? 'object-cache.php (vhttpd Cache)' : 'object-cache.php (Default Memory)'; ?>
                    </span>
                </div>
            </div>

            <div class="v-mode-selector">
                <!-- Restricted Box -->
                <div class="v-mode-box <?php echo $current_mode === 'restricted' ? 'selected' : ''; ?>" 
                     onclick="document.getElementById('switch-restricted-form').submit()">
                    <span class="v-badge-mode orange">Restricted</span>
                    <h4 class="v-mode-title">受限调试模式</h4>
                    <span class="v-mode-desc">
                        不写入 wp-content。仅进行性能与日志诊断。安全兼容 Nginx 架构。
                    </span>
                    <form id="switch-restricted-form" method="post" action="" style="display:none;">
                        <?php wp_nonce_field('v_profiler_admin_action', 'v_profiler_nonce'); ?>
                        <input type="hidden" name="v_profiler_action" value="switch_mode">
                        <input type="hidden" name="target_mode" value="restricted">
                    </form>
                </div>

                <!-- Full vhttpd Box -->
                <div class="v-mode-box <?php echo $current_mode === 'full' ? 'selected' : ''; ?>" 
                     onclick="document.getElementById('switch-full-form').submit()">
                    <span class="v-badge-mode green">Enterprise</span>
                    <h4 class="v-mode-title">完整极速模式</h4>
                    <span class="v-mode-desc">
                        部署加速文件。接管 SQL 握手与缓存管理。获取 10x 商业加速与企业安全加固。
                    </span>
                    <form id="switch-full-form" method="post" action="" style="display:none;">
                        <?php wp_nonce_field('v_profiler_admin_action', 'v_profiler_nonce'); ?>
                        <input type="hidden" name="v_profiler_action" value="switch_mode">
                        <input type="hidden" name="target_mode" value="full">
                    </form>
                </div>
            </div>
        </div>
    </div>
    <?php
}
