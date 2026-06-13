<?php
declare(strict_types=1);

/**
 * WordPress bridge demo for vhttpd/php-worker.
 *
 * Required env:
 * - VPHP_WP_ROOT=/abs/path/to/wordpress
 */

require_once __DIR__ . '/vendor/autoload.php';

// 自适应延迟退出类，用于支持安装阶段
class AutoExitHelper
{
    public function __destruct()
    {
        // 延迟 20 毫秒，确保 vhttpd-worker 成功发送 TCP/Unix 响应包
        usleep(20000);
        exit(0);
    }
}
// 使用独立的 php-cgi 进程来防 exit/die 夭折，并正确保留响应 Header 的辅助桥接函数
function run_via_cgi(string $phpCgiBin, string $scriptFile, array $envelope, string $wpRoot): array {
    $method = strtoupper((string)($envelope['method'] ?? 'GET'));
    $path = (string)($envelope['path'] ?? '/');
    $queryStr = '';
    if (str_contains($path, '?')) {
        $parts = explode('?', $path, 2);
        $path = $parts[0];
        $queryStr = $parts[1] ?? '';
    }
    $queryParams = $envelope['query'] ?? [];
    if (empty($queryStr) && !empty($queryParams)) {
        $queryStr = http_build_query($queryParams);
    }
    $body = (string)($envelope['body'] ?? '');
    
    // 准备标准的 CGI 环境变量
    $env = [
        'GATEWAY_INTERFACE' => 'CGI/1.1',
        'SCRIPT_FILENAME'   => $scriptFile,
        'REQUEST_METHOD'    => $method,
        'REQUEST_URI'       => $path . ($queryStr !== '' ? '?' . $queryStr : ''),
        'QUERY_STRING'      => $queryStr,
        'HTTP_HOST'         => $envelope['host'] ?: '127.0.0.1',
        'SERVER_NAME'       => $envelope['host'] ?: '127.0.0.1',
        'SERVER_PORT'       => $envelope['port'] ?: '19881',
        'HTTPS'             => (($envelope['scheme'] ?? 'http') === 'https') ? 'on' : 'off',
        'REMOTE_ADDR'       => $envelope['remote_addr'] ?: '127.0.0.1',
        'REDIRECT_STATUS'   => '200', // 绕过 PHP-CGI 安全限制
        'VPHP_WP_ROOT'      => $wpRoot,
    ];
    
    // 导入 HTTP Headers
    foreach ($envelope['headers'] ?? [] as $name => $values) {
        $headerName = 'HTTP_' . strtoupper(str_replace('-', '_', $name));
        $env[$headerName] = is_array($values) ? implode(', ', $values) : (string)$values;
    }
    
    $descriptors = [
        0 => ['pipe', 'r'], // stdin
        1 => ['pipe', 'w'], // stdout
        2 => ['pipe', 'w'], // stderr
    ];
    
    $vslimSo = dirname(__DIR__, 2) . '/vphpx/vslim/vslim.so';
    $cmd = '"' . $phpCgiBin . '"';
    if (is_file($vslimSo)) {
        $cmd .= ' -d extension="' . $vslimSo . '"';
    }
    
    $process = proc_open($cmd, $descriptors, $pipes, null, $env);
    if (!is_resource($process)) {
        throw new RuntimeException("Failed to run php-cgi");
    }
    
    if ($body !== '') {
        fwrite($pipes[0], $body);
    }
    fclose($pipes[0]);
    
    $stdout = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    
    proc_close($process);
    
    // 解析 CGI 响应（Header 和 Body）
    $parts = explode("\r\n\r\n", $stdout, 2);
    if (count($parts) < 2) {
        $parts = explode("\n\n", $stdout, 2);
    }
    
    $headerRaw = $parts[0] ?? '';
    $respBody = $parts[1] ?? '';
    
    $status = 200;
    $contentType = 'text/html; charset=utf-8';
    $headers = [];
    
    foreach (explode("\n", str_replace("\r", "", $headerRaw)) as $line) {
        $line = trim($line);
        if ($line === '') continue;
        if (!str_contains($line, ':')) continue;
        
        list($name, $val) = explode(':', $line, 2);
        $name = strtolower(trim($name));
        $val = trim($val);
        
        if ($name === 'status') {
            $status = (int)$val;
        } elseif ($name === 'content-type') {
            $contentType = $val;
        } else {
            $headers[$name] = $val;
        }
    }
    
    return [
        'status' => $status,
        'content_type' => $contentType,
        'headers' => $headers,
        'body' => $respBody,
    ];
}

// 初始化加载 WordPress (只加载一次)
$wpRoot = getenv('VPHP_WP_ROOT');
if (!is_string($wpRoot) || $wpRoot === '') {
    throw new RuntimeException('VPHP_WP_ROOT is required for wordpress demo');
}
$wpLoad = rtrim($wpRoot, '/') . '/wp-load.php';
if (!is_file($wpLoad)) {
    throw new RuntimeException('wp-load.php not found: ' . $wpLoad);
}

// 设置全局超全局变量 Fallback 默认值，以防 WordPress 首次加载初始化时抛出 Undefined Key Notice/Warning
$_SERVER['HTTP_HOST'] = $_SERVER['HTTP_HOST'] ?? 'localhost';
$_SERVER['REQUEST_URI'] = $_SERVER['REQUEST_URI'] ?? '/';
$_SERVER['REQUEST_METHOD'] = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$_SERVER['SERVER_NAME'] = $_SERVER['SERVER_NAME'] ?? 'localhost';
$_SERVER['SERVER_PORT'] = $_SERVER['SERVER_PORT'] ?? '80';
$_SERVER['REMOTE_ADDR'] = $_SERVER['REMOTE_ADDR'] ?? '127.0.0.1';

// 如果配置文件已存在，则可以安全地在全局 require 进来
$hasConfig = file_exists(rtrim($wpRoot, '/') . '/wp-config.php');
if ($hasConfig) {
    if (!defined('WP_USE_THEMES')) {
        define('WP_USE_THEMES', true);
    }
    require_once $wpLoad;
}

return static function ($requestOrEnvelope, array $envelope = []): array {
    // 兼容 PSR-7 和 数组 envelope
    if ($requestOrEnvelope instanceof \Psr\Http\Message\ServerRequestInterface) {
        $request = $requestOrEnvelope;
        $path = $request->getUri()->getPath();
        $queryStr = $request->getUri()->getQuery();
        $method = $request->getMethod();
        $queryParams = $request->getQueryParams();
        $body = (string)$request->getBody();
        $headers = [];
        foreach ($request->getHeaders() as $name => $values) {
            $headers[$name] = implode(', ', $values);
        }
        $cookies = $request->getCookieParams();
        $serverParams = $request->getServerParams();
        $host = $request->getUri()->getHost();
        $port = (string)$request->getUri()->getPort();
        $scheme = $request->getUri()->getScheme();
        $remoteAddr = $serverParams['REMOTE_ADDR'] ?? '';
    } else {
        $payload = is_array($requestOrEnvelope) ? $requestOrEnvelope : $envelope;
        $path = (string)($payload['path'] ?? '/');
        $queryStr = '';
        if (str_contains($path, '?')) {
            $parts = explode('?', $path, 2);
            $path = $parts[0];
            $queryStr = $parts[1] ?? '';
        }
        $method = strtoupper((string)($payload['method'] ?? 'GET'));
        $queryParams = $payload['query'] ?? [];
        if (empty($queryStr) && !empty($queryParams)) {
            $queryStr = http_build_query($queryParams);
        }
        $body = (string)($payload['body'] ?? '');
        $headers = $payload['headers'] ?? [];
        $cookies = $payload['cookies'] ?? [];
        $serverParams = $payload['server'] ?? [];
        $host = (string)($payload['host'] ?? '');
        $port = (string)($payload['port'] ?? '');
        $scheme = (string)($payload['scheme'] ?? 'http');
        $remoteAddr = (string)($payload['remote_addr'] ?? '');
    }

    $wpRoot = getenv('VPHP_WP_ROOT');
    $wpLoad = rtrim($wpRoot, '/') . '/wp-load.php';

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

    // 2. 重置超全局变量以模拟此次真实请求。透传前端发来的真实 REQUEST_URI，这一步必须在加载 wp-load.php 之前执行
    $requestUri = $path . ($queryStr !== '' ? '?' . $queryStr : '');
    $_SERVER['REQUEST_URI'] = $requestUri;
    $_SERVER['REQUEST_METHOD'] = $method;
    $_SERVER['QUERY_STRING'] = $queryStr;
    $_SERVER['HTTP_HOST'] = $host ?: 'localhost';
    $_SERVER['SERVER_NAME'] = $host ?: 'localhost';
    if ($port !== '') {
        $_SERVER['SERVER_PORT'] = $port;
    } else {
        $_SERVER['SERVER_PORT'] = ($scheme === 'https') ? '443' : '80';
    }
    $_SERVER['HTTPS'] = ($scheme === 'https') ? 'on' : 'off';
    $_SERVER['REMOTE_ADDR'] = $remoteAddr ?: '127.0.0.1';

    $_GET = $queryParams;
    $_POST = [];
    if ($method === 'POST') {
        $contentType = $headers['content-type'] ?? $headers['Content-Type'] ?? '';
        if (is_array($contentType)) {
            $contentType = implode(', ', $contentType);
        }
        if (str_contains(strtolower($contentType), 'application/x-www-form-urlencoded')) {
            parse_str($body, $_POST);
        }
    }
    $_COOKIE = $cookies;
    $_REQUEST = array_merge($_GET, $_POST, $_COOKIE);

    // 3. 判定当前是否是未安装阶段，或者访问的是物理存在的特定 .php 文件（如后台 setup-config）
    $hasConfig = file_exists(rtrim($wpRoot, '/') . '/wp-config.php');

    // 首次安装若访问根路径，由闭包直接 302 重定向到 setup-config.php，不走 require_once 以免 exit 导致进程夭折
    if (!$hasConfig && ($path === '/' || $path === '')) {
        return [
            'status' => 302,
            'content_type' => 'text/html; charset=utf-8',
            'headers' => [
                'location' => '/wp-admin/setup-config.php',
            ],
            'body' => '',
        ];
    }

    $localPhpFile = rtrim($wpRoot, '/') . '/' . ltrim($path, '/');
    if (is_dir($localPhpFile)) {
        $localPhpFile = rtrim($localPhpFile, '/') . '/index.php';
    }
    $isPhpFile = is_file($localPhpFile) && str_ends_with($localPhpFile, '.php');

    // 处于未安装阶段，或者是请求了物理存在的特定 .php 脚本（特别是 wp-admin 下的安装/配置页面）
    // 为了防止 wp-load 或页面自身执行 exit/die 导致主 worker 进程 502 死亡，我们通过独立的 php-cgi 进程来托管运行
    if (!$hasConfig || $isPhpFile) {
        $phpCgiBin = '/opt/homebrew/bin/php-cgi';
        if (!is_file($phpCgiBin)) {
            $phpCgiBin = 'php-cgi';
        }
        
        $envelopeWrapper = [
            'method' => $method,
            'path' => $path,
            'query' => $queryParams,
            'body' => $body,
            'headers' => $headers,
            'cookies' => $cookies,
            'host' => $host,
            'port' => $port,
            'scheme' => $scheme,
            'remote_addr' => $remoteAddr,
        ];
        
        return run_via_cgi($phpCgiBin, $localPhpFile, $envelopeWrapper, $wpRoot);
    }

    // 4. 常规前驻加载：如果已安装且不是物理 PHP 请求，安全 require $wpLoad 提供常驻高性能
    if (!defined('WP_USE_THEMES')) {
        define('WP_USE_THEMES', true);
    }
    require_once $wpLoad;

    // 4. 原有的 API 路由接口（采用后缀匹配，解耦 /wordpress 硬编码）
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

    $response = [
        'status' => 200,
        'content_type' => 'text/html; charset=utf-8',
        'headers' => [
            'x-framework' => 'wordpress',
        ],
        'body' => $html,
    ];

    // 如果还没有生成 wp-config.php，注册 AutoExitHelper 在该请求发送完毕后退出进程，以便重启干净的 Worker 加载全新配置
    if (!$hasConfig) {
        $response['auto_exit'] = new AutoExitHelper();
    }

    return $response;
};
