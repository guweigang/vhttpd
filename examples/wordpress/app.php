<?php
declare(strict_types=1);

use VHttpd\WordPress\Lifecycle;

class WpRedirectException extends \Exception {
    private $location;
    private $status;
    public function __construct(string $location, int $status) {
        parent::__construct("Redirecting to {$location}");
        $this->location = $location;
        $this->status = $status;
    }
    public function getLocation(): string { return $this->location; }
    public function getStatus(): int { return $this->status; }
}

if (!function_exists('wp_redirect')) {
    function wp_redirect($location, $status = 302, $x_redirect_by = 'WordPress') {
        throw new WpRedirectException($location, (int)$status);
    }
}

/**
 * WordPress bridge demo for vhttpd/php-worker.
 *
 * Required env:
 * - VPHP_WP_ROOT=/abs/path/to/wordpress
 */

require_once __DIR__ . '/vendor/autoload.php';

$lifecycle = new Lifecycle();

// 初始化加载 WordPress (只加载一次)
$wpRoot = $lifecycle->rootFromEnv();
$lifecycle->prepareBootstrapDefaults();

// 如果配置文件已存在，则可以安全地在全局 require 进来
$lifecycle->bootstrapIfInstalled($wpRoot);

return static function ($requestOrEnvelope, array $envelope = []) use ($lifecycle, $wpRoot): array {
    try {
    $request = $lifecycle->normalizeRequest($requestOrEnvelope, $envelope);
    $lifecycle->prepareEnvironment($request);

    $path = (string)$request['path'];
    $queryParams = $request['query'];

    // 1. 静态资源直达支持 (提取任意路由前缀后的静态文件相对路径)
    $cleanStaticPath = '';
    if (preg_match('#/(wp-content/.*|wp-includes/.*|wp-admin/.*|favicon\.ico|robots\.txt)$#', $path, $m) === 1) {
        $cleanStaticPath = $m[1];
    }
    if ($cleanStaticPath !== '') {
        $localFile = rtrim($wpRoot, '/') . '/' . $cleanStaticPath;
        if (is_file($localFile)) {
            $ext = strtolower(pathinfo($localFile, PATHINFO_EXTENSION));
            $mimeTypes = [
                'css'   => 'text/css; charset=utf-8',
                'js'    => 'application/javascript; charset=utf-8',
                'png'   => 'image/png',
                'jpg'   => 'image/jpeg',
                'jpeg'  => 'image/jpeg',
                'gif'   => 'image/gif',
                'svg'   => 'image/svg+xml',
                'ico'   => 'image/x-icon',
                'woff'  => 'font/woff',
                'woff2' => 'font/woff2',
                'ttf'   => 'font/ttf',
                'xml'   => 'application/xml; charset=utf-8',
                'txt'   => 'text/plain; charset=utf-8',
            ];
            if (isset($mimeTypes[$ext])) {
                return [
                    'status' => 200,
                    'content_type' => $mimeTypes[$ext],
                    'headers' => [
                        'cache-control' => 'public, max-age=31536000',
                        'x-static-pass' => 'true',
                    ],
                    'body' => file_get_contents($localFile),
                ];
            }
        }
    }

    // 3. WordPress worker mode requires an installed site.
    if (!$lifecycle->isInstalled($wpRoot)) {
        if (str_ends_with($path, '/meta')) {
            return [
                'status' => 200,
                'content_type' => 'application/json; charset=utf-8',
                'headers' => [
                    'x-framework' => 'wordpress',
                ],
                'body' => json_encode([
                    'framework' => 'wordpress',
                    'installed' => false,
                    'error' => 'wp_config_missing',
                    'message' => 'Create wp-config.php before running WordPress under vphp-worker.',
                    'trace' => (string)($queryParams['trace_id'] ?? ''),
                ], JSON_UNESCAPED_SLASHES),
            ];
        }

        return [
            'status' => 302,
            'content_type' => 'text/html; charset=utf-8',
            'headers' => [
                'location' => '/wp-admin/setup-config.php',
            ],
            'body' => 'Redirecting to WordPress setup...',
        ];
    }

    $localPhpFile = rtrim($wpRoot, '/') . '/' . ltrim($path, '/');
    if (is_dir($localPhpFile)) {
        $localPhpFile = rtrim($localPhpFile, '/') . '/index.php';
    }
    $isPhpFile = is_file($localPhpFile) && str_ends_with($localPhpFile, '.php');
    if ($isPhpFile) {
        $cleanPath = '/' . ltrim($path, '/');
        if ($cleanPath !== '/' && $cleanPath !== '/index.php') {
            return [
                'status' => 501,
                'content_type' => 'application/json; charset=utf-8',
                'headers' => [
                    'x-framework' => 'wordpress',
                ],
                'body' => json_encode([
                    'error' => 'direct_php_script_unsupported',
                    'path' => $path,
                    'message' => 'Direct WordPress PHP entrypoints require a separate CGI/compat executor, not this long-running worker app.',
                ], JSON_UNESCAPED_SLASHES),
            ];
        }
    }

    // 4. 常驻加载：已安装且不是物理 PHP 入口时，交给 WordPress runtime 处理。
    $lifecycle->bootstrap($wpRoot);
    $lifecycle->resetRequestRuntime();

    // 4. 原有的 API 路由接口
    if (str_ends_with($path, '/meta')) {
        return [
            'status' => 200,
            'content_type' => 'application/json; charset=utf-8',
            'headers' => [
                'x-framework' => 'wordpress',
            ],
            'body' => wp_json_encode([
                'framework' => 'wordpress',
                'home' => function_exists('home_url') ? home_url('/') : '',
                'site_name' => function_exists('get_bloginfo') ? get_bloginfo('name') : '',
                'trace' => (string)($queryParams['trace_id'] ?? ''),
            ]),
        ];
    }

    if (preg_match('#/post/(\d+)$#', $path, $m) === 1) {
        $postId = (int)$m[1];
        $post = function_exists('get_post') ? get_post($postId) : null;
        if (!$post) {
            return [
                'status' => 404,
                'content_type' => 'application/json; charset=utf-8',
                'headers' => [
                    'x-framework' => 'wordpress',
                ],
                'body' => wp_json_encode([
                    'error' => 'post_not_found',
                    'post_id' => $postId,
                ]),
            ];
        }

        return [
            'status' => 200,
            'content_type' => 'application/json; charset=utf-8',
            'headers' => [
                'x-framework' => 'wordpress',
            ],
            'body' => wp_json_encode([
                'id' => (int)$post->ID,
                'slug' => (string)$post->post_name,
                'title' => function_exists('get_the_title') ? (string)get_the_title($post->ID) : '',
                'status' => (string)$post->post_status,
            ]),
        ];
    }

    // 调用 wp() 进行路由和查询
    global $wp, $wp_query, $wp_the_query, $post, $posts, $wp_did_header;
    $wp_did_header = true;

    if (function_exists('wp')) {
        wp();
    }

    // 渲染 HTML
    ob_start();
    try {
        if (defined('ABSPATH') && defined('WPINC')) {
            require ABSPATH . WPINC . '/template-loader.php';
        }
    } catch (\Throwable $t) {
        ob_end_clean();
        throw $t;
    }
    $html = ob_get_clean();

    return [
        'status' => 200,
        'content_type' => 'text/html; charset=utf-8',
        'headers' => [
            'x-framework' => 'wordpress',
        ],
        'body' => $html,
    ];
    } catch (\Throwable $t) {
        if ($t instanceof WpRedirectException) {
            return [
                'status' => $t->getStatus(),
                'content_type' => 'text/html; charset=utf-8',
                'headers' => [
                    'location' => $t->getLocation(),
                    'x-redirect-by' => 'vhttpd-worker-intercept',
                ],
                'body' => 'Redirecting to ' . htmlspecialchars($t->getLocation()),
            ];
        }
        return [
            'status' => 500,
            'content_type' => 'text/html; charset=utf-8',
            'headers' => [
                'x-framework' => 'wordpress',
            ],
            'body' => '<h1>WordPress Worker Mode Error</h1>' .
                      '<p><strong>Message:</strong> ' . htmlspecialchars($t->getMessage()) . '</p>' .
                      '<p><strong>File:</strong> ' . htmlspecialchars($t->getFile()) . ':' . $t->getLine() . '</p>' .
                      '<pre>' . htmlspecialchars($t->getTraceAsString()) . '</pre>',
        ];
    }
};
