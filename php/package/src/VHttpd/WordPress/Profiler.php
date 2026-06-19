<?php

declare(strict_types=1);

namespace VHttpd\WordPress;

use VHttpd\Wire\JsonClient;

final class Profiler
{
    private static float $startTime = 0.0;
    private static array $logs = [];
    private static array $errors = [];
    private static array $timeline = [];
    private static array $hookCounts = [];
    private static bool $started = false;
    private static bool $active = false;
    private static bool $footerInjected = false;
    private static string $currentRequestId = '';
    private static bool $errorHandlersRegistered = false;

    private static int $startMemory = 0;
    private static array $externalRequests = [];
    private static array $tempRequestTimes = [];
    private static array $queryStacks = [];

    /** @var callable|null */
    private static $prevErrorHandler = null;

    /** @var callable|null */
    private static $prevExceptionHandler = null;

    public static function reset(): void
    {
        self::$startMemory = memory_get_usage();
        self::$startTime = microtime(true);
        self::$logs = [];
        self::$errors = [];
        self::$timeline = [];
        self::$timeline['start'] = self::$startTime;
        self::$hookCounts = [];
        self::$footerInjected = false;
        self::$externalRequests = [];
        self::$tempRequestTimes = [];
        self::$queryStacks = [];

        // 清空 WordPress 的全局 queries 缓存，防止在 php-worker 模式下多请求累积
        global $wpdb;
        if (isset($wpdb) && is_object($wpdb)) {
            $wpdb->queries = [];
        }
    }

    public static function start(): void
    {
        $requestId = getenv('VHTTPD_REQUEST_ID') ?: ($_SERVER['VHTTPD_REQUEST_ID'] ?? 'unknown');
        if (self::$currentRequestId === $requestId && $requestId !== 'unknown') {
            return;
        }
        self::$currentRequestId = $requestId;

        self::reset();
        self::$started = true;

        // 拦截早期错误和异常
        if (!self::$errorHandlersRegistered) {
            self::$prevErrorHandler = set_error_handler([self::class, 'handleError']);
            self::$prevExceptionHandler = set_exception_handler([self::class, 'handleException']);
            register_shutdown_function([self::class, 'handleShutdown']);
            self::$errorHandlersRegistered = true;

            // 统计 WordPress hooks 计数
            if (function_exists('add_action')) {
                add_action('all', [self::class, 'countHook']);
            }
        }
    }

    public static function activate(): void
    {
        if (!self::$started) {
            self::start();
        }
        self::$active = true;
        self::$timeline['init'] = microtime(true);

        // 启用 WP_DEBUG 时保存查询，以便获取 SQL 执行记录
        if (!defined('SAVEQUERIES')) {
            define('SAVEQUERIES', true);
        }

        // 挂载核心页面检查点
        if (function_exists('add_action')) {
            add_action('template_redirect', static function (): void {
                self::$timeline['template_redirect'] = microtime(true);
            });

            // 挂载 HTML 尾部数据注入
            add_action('wp_footer', [self::class, 'injectWidget'], 9999);
            add_action('admin_footer', [self::class, 'injectWidget'], 9999);

            // 注册 REST API 路由支持跨请求读取
            add_action('rest_api_init', [self::class, 'registerRestRoute']);
        }

        // 挂载 SQL 调用栈追踪和外部 HTTP 请求拦截
        if (function_exists('add_filter')) {
            add_filter('query', [self::class, 'captureQueryStack']);
            add_filter('pre_http_request', [self::class, 'logExternalRequestStart'], 10, 3);
        }
        if (function_exists('add_action')) {
            add_action('http_api_debug', [self::class, 'logExternalRequestEnd'], 10, 5);
        }
    }

    public static function stopAndDeactivate(): void
    {
        if (!self::$started) {
            return;
        }
        self::$active = false;

        if (self::$prevErrorHandler !== null) {
            set_error_handler(self::$prevErrorHandler);
        } else {
            restore_error_handler();
        }

        if (self::$prevExceptionHandler !== null) {
            set_exception_handler(self::$prevExceptionHandler);
        } else {
            restore_exception_handler();
        }

        if (function_exists('remove_action')) {
            remove_action('all', [self::class, 'countHook']);
            remove_action('http_api_debug', [self::class, 'logExternalRequestEnd'], 10);
        }
        if (function_exists('remove_filter')) {
            remove_filter('query', [self::class, 'captureQueryStack']);
            remove_filter('pre_http_request', [self::class, 'logExternalRequestStart'], 10);
        }
    }

    public static function log(mixed $var, string $label = '', string $level = 'debug'): void
    {
        if (!self::$active) {
            return;
        }
        self::$logs[] = [
            'label' => $label,
            'level' => $level,
            'data' => is_scalar($var) ? $var : print_r($var, true),
            'timestamp' => microtime(true)
        ];
    }

    public static function countHook(string $tag): void
    {
        if (!self::$active) {
            return;
        }
        self::$hookCounts[$tag] = (self::$hookCounts[$tag] ?? 0) + 1;
    }

    public static function captureQueryStack(string $query): string
    {
        if (self::$active) {
            $stack = debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS, 12);
            $filtered = [];
            foreach ($stack as $frame) {
                if (isset($frame['file'])) {
                    $file = self::cleanPath($frame['file']);
                    if (str_contains($file, 'Profiler.php') || str_contains($file, 'wp-db.php') || str_contains($file, 'db.php')) {
                        continue;
                    }
                    $func = $frame['function'] ?? '';
                    $class = $frame['class'] ?? '';
                    $filtered[] = [
                        'file' => $file,
                        'line' => $frame['line'] ?? 0,
                        'caller' => $class !== '' ? "{$class}::{$func}" : $func
                    ];
                }
            }
            self::$queryStacks[] = $filtered;
        }
        return $query;
    }

    public static function logExternalRequestStart(mixed $pre, array $args, string $url): mixed
    {
        if (self::$active) {
            $key = md5($url . serialize($args));
            self::$tempRequestTimes[$key] = microtime(true);
        }
        return $pre;
    }

    public static function logExternalRequestEnd(mixed $response, string $context, string $class, array $args, string $url): void
    {
        if (!self::$active) {
            return;
        }
        $key = md5($url . serialize($args));
        $startTime = self::$tempRequestTimes[$key] ?? null;
        $durationMs = 0.0;
        if ($startTime !== null) {
            $durationMs = round((microtime(true) - $startTime) * 1000, 2);
            unset(self::$tempRequestTimes[$key]);
        }

        $parsedUrl = parse_url($url);
        $cleanUrl = $url;
        if (isset($parsedUrl['query'])) {
            parse_str($parsedUrl['query'], $queryParams);
            $maskedQuery = self::maskSensitiveData($queryParams);
            $parsedUrl['query'] = http_build_query($maskedQuery);
            $cleanUrl = (isset($parsedUrl['scheme']) ? $parsedUrl['scheme'] . '://' : '') .
                         (isset($parsedUrl['host']) ? $parsedUrl['host'] : '') .
                         (isset($parsedUrl['port']) ? ':' . $parsedUrl['port'] : '') .
                         (isset($parsedUrl['path']) ? $parsedUrl['path'] : '') .
                         ($parsedUrl['query'] !== '' ? '?' . $parsedUrl['query'] : '');
        }

        $statusCode = 'unknown';
        if (is_array($response) && isset($response['response']['code'])) {
            $statusCode = (int) $response['response']['code'];
        } elseif ($response instanceof \WP_Error) {
            $statusCode = 'error: ' . $response->get_error_message();
        }

        self::$externalRequests[] = [
            'url' => $cleanUrl,
            'method' => $args['method'] ?? 'GET',
            'status' => $statusCode,
            'duration_ms' => $durationMs,
            'timestamp' => microtime(true)
        ];
    }

    public static function handleError(int $errno, string $errstr, string $errfile, int $errline): bool
    {
        if (!(error_reporting() & $errno)) {
            if (self::$prevErrorHandler !== null) {
                return (bool) call_user_func(self::$prevErrorHandler, $errno, $errstr, $errfile, $errline);
            }
            return false;
        }

        if (!self::$active) {
            if (self::$prevErrorHandler !== null) {
                return (bool) call_user_func(self::$prevErrorHandler, $errno, $errstr, $errfile, $errline);
            }
            return false;
        }

        $errorType = match ($errno) {
            E_ERROR, E_CORE_ERROR, E_COMPILE_ERROR, E_USER_ERROR => 'Error',
            E_WARNING, E_CORE_WARNING, E_COMPILE_WARNING, E_USER_WARNING => 'Warning',
            E_PARSE => 'Parse Error',
            E_NOTICE, E_USER_NOTICE => 'Notice',
            E_DEPRECATED, E_USER_DEPRECATED => 'Deprecated',
            default => 'Unknown Error',
        };

        self::$errors[] = [
            'level' => $errorType,
            'message' => $errstr,
            'file' => self::cleanPath($errfile),
            'line' => $errline,
            'timestamp' => microtime(true)
        ];

        if (self::$prevErrorHandler !== null) {
            return (bool) call_user_func(self::$prevErrorHandler, $errno, $errstr, $errfile, $errline);
        }
        return false;
    }

    public static function handleException(\Throwable $exception): void
    {
        if (self::$active) {
            self::$errors[] = [
                'level' => 'Exception',
                'message' => $exception->getMessage(),
                'file' => self::cleanPath($exception->getFile()),
                'line' => $exception->getLine(),
                'timestamp' => microtime(true),
                'trace' => self::cleanTrace($exception->getTraceAsString())
            ];
        }

        if (self::$prevExceptionHandler !== null) {
            call_user_func(self::$prevExceptionHandler, $exception);
        }
    }

    public static function injectWidget(): void
    {
        if (!self::$active || self::$footerInjected) {
            return;
        }
        self::$footerInjected = true;

        $report = self::buildReport();
        $reportJson = json_encode($report, JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT);

        $jsFile = dirname(__DIR__, 3) . '/wordpress/v-profiler-ui.js';
        $jsCode = '';
        if (is_file($jsFile)) {
            $jsCode = file_get_contents($jsFile);
        } elseif (defined('WPMU_PLUGIN_DIR') && is_file(WPMU_PLUGIN_DIR . '/v-profiler-ui.js')) {
            $jsCode = file_get_contents(WPMU_PLUGIN_DIR . '/v-profiler-ui.js');
        } elseif (defined('WP_PLUGIN_DIR') && is_file(WP_PLUGIN_DIR . '/v-profiler-ui.js')) {
            $jsCode = file_get_contents(WP_PLUGIN_DIR . '/v-profiler-ui.js');
        }

        echo "\n<!-- v-Profiler Start -->\n";
        echo "<script>\n";
        echo "window.vProfilerData = " . $reportJson . ";\n";
        if ($jsCode !== '') {
            echo $jsCode . "\n";
        }
        echo "</script>\n";
        echo "<v-profiler-widget></v-profiler-widget>\n";
        echo "<!-- v-Profiler End -->\n";
    }

    public static function handleShutdown(): void
    {
        if (!self::$active) {
            return;
        }

        if (!self::$footerInjected) {
            $report = self::buildReport();
            if (function_exists('wp_cache_set')) {
                wp_cache_set('report:' . $report['request_id'], $report, 'vprofiler', 300);
            }
        }
    }

    public static function registerRestRoute(): void
    {
        register_rest_route('v-profiler/v1', '/report', [
            'methods' => 'GET',
            'callback' => [self::class, 'getRestReport'],
            'permission_callback' => static function (): bool {
                return current_user_can('manage_options');
            },
        ]);
    }

    public static function getRestReport(\WP_REST_Request $request): \WP_REST_Response
    {
        $requestId = $request->get_param('request_id');
        if (empty($requestId)) {
            return new \WP_REST_Response(['error' => 'request_id is required'], 400);
        }

        if (function_exists('wp_cache_get')) {
            $report = wp_cache_get('report:' . $requestId, 'vprofiler');
            if (is_array($report)) {
                return new \WP_REST_Response($report, 200);
            }
        }

        return new \WP_REST_Response(['error' => 'Report not found or expired'], 404);
    }

    private static function cleanPath(string $path): string
    {
        if (defined('ABSPATH')) {
            return str_replace(ABSPATH, '', $path);
        }
        return $path;
    }

    private static function cleanTrace(string $trace): string
    {
        if (defined('ABSPATH')) {
            return str_replace(ABSPATH, '', $trace);
        }
        return $trace;
    }

    private static function getAdminSocketPath(): string
    {
        $socket = getenv('VHTTPD_INTERNAL_ADMIN_SOCKET') ?: ($_SERVER['VHTTPD_INTERNAL_ADMIN_SOCKET'] ?? ($_ENV['VHTTPD_INTERNAL_ADMIN_SOCKET'] ?? ''));
        if (is_string($socket) && $socket !== '' && file_exists($socket)) {
            return $socket;
        }

        // Fallback: 自动扫描 /tmp 和 /private/tmp 下的 vhttpd admin socket 文件
        $files = array_merge(
            glob('/tmp/vhttpd_admin_*.sock') ?: [],
            glob('/private/tmp/vhttpd_admin_*.sock') ?: []
        );
        if (count($files) > 0) {
            // 按照文件修改时间降序排序，取最新的一个
            usort($files, static function ($a, $b) {
                return filemtime($b) <=> filemtime($a);
            });
            foreach ($files as $file) {
                if (file_exists($file) && is_readable($file)) {
                    return $file;
                }
            }
        }

        return '';
    }

    private static function fetchDbPoolStats(): array
    {
        $socket = self::getAdminSocketPath();
        if ($socket === '') {
            return ['error' => 'Internal admin socket not available: empty'];
        }

        try {
            $client = new JsonClient($socket, 'admin');
            $response = $client->request([
                'mode' => 'vhttpd_admin',
                'method' => 'GET',
                'path' => '/runtime/db',
                'query' => (object) [],
                'body' => '',
            ]);
            if (isset($response['error']) && $response['error'] !== '') {
                return ['error' => $response['error']];
            }
            if (isset($response['body'])) {
                $body = json_decode((string) $response['body'], true);
                if (is_array($body)) {
                    return $body;
                }
            }
            return ['error' => 'Invalid admin socket response'];
        } catch (\Throwable $e) {
            return ['error' => 'Failed to query admin socket: ' . $e->getMessage()];
        }
    }

    private static function fetchVHttpdStats(): array
    {
        $socket = self::getAdminSocketPath();
        if ($socket === '') {
            $globTmp = glob('/tmp/vhttpd_admin_*.sock');
            $globPrivate = glob('/private/tmp/vhttpd_admin_*.sock');
            $envSocket = getenv('VHTTPD_INTERNAL_ADMIN_SOCKET') ?: ($_SERVER['VHTTPD_INTERNAL_ADMIN_SOCKET'] ?? ($_ENV['VHTTPD_INTERNAL_ADMIN_SOCKET'] ?? 'empty'));
            return [
                'error' => sprintf(
                    'Socket not found. Env: %s | Glob(/tmp): %s | Glob(/private/tmp): %s',
                    $envSocket,
                    is_array($globTmp) ? implode(', ', $globTmp) : 'false',
                    is_array($globPrivate) ? implode(', ', $globPrivate) : 'false'
                )
            ];
        }

        try {
            $client = new JsonClient($socket, 'admin');
            $response = $client->request([
                'mode' => 'vhttpd_admin',
                'method' => 'GET',
                'path' => '/runtime',
                'query' => (object) [],
                'body' => '',
            ]);
            if (isset($response['error']) && $response['error'] !== '') {
                return ['error' => $response['error']];
            }
            if (isset($response['body'])) {
                $body = json_decode((string) $response['body'], true);
                if (is_array($body)) {
                    return $body;
                }
            }
            return ['error' => 'Invalid admin socket response'];
        } catch (\Throwable $e) {
            return ['error' => 'Failed to query admin socket: ' . $e->getMessage()];
        }
    }

    private static function fetchExecutors(): array
    {
        $socket = self::getAdminSocketPath();
        if ($socket === '') {
            return [];
        }

        try {
            $client = new JsonClient($socket, 'admin');
            $response = $client->request([
                'mode' => 'vhttpd_admin',
                'method' => 'GET',
                'path' => '/executors',
                'query' => (object) [],
                'body' => '',
            ]);
            if (isset($response['error']) && $response['error'] !== '') {
                return [];
            }
            if (isset($response['body'])) {
                $body = json_decode((string) $response['body'], true);
                if (is_array($body)) {
                    return $body;
                }
            }
            return [];
        } catch (\Throwable $e) {
            return [];
        }
    }


    private static function maskSensitiveData(array $data): array
    {
        $sensitiveKeys = ['password', 'password_referer', 'pwd', 'secret', 'token', 'key', 'auth', 'authorization', 'cookie'];
        $masked = [];
        foreach ($data as $k => $v) {
            $lowK = strtolower((string)$k);
            $isSensitive = false;
            foreach ($sensitiveKeys as $sk) {
                if (str_contains($lowK, $sk)) {
                    $isSensitive = true;
                    break;
                }
            }
            if ($isSensitive) {
                $masked[$k] = '******';
            } elseif (is_array($v)) {
                $masked[$k] = self::maskSensitiveData($v);
            } else {
                $masked[$k] = $v;
            }
        }
        return $masked;
    }

    private static function buildReport(): array
    {
        global $wpdb, $wp_object_cache, $wp_filter;

        $timeline = self::$timeline;
        $timeline['shutdown'] = microtime(true);
        $totalDurationMs = round(($timeline['shutdown'] - self::$startTime) * 1000, 2);

        $checkpoints = [];
        $prevTime = self::$startTime;
        foreach ($timeline as $name => $time) {
            $checkpoints[] = [
                'name' => $name,
                'time_ms' => round(($time - self::$startTime) * 1000, 2),
                'duration_ms' => round(($time - $prevTime) * 1000, 2),
            ];
            $prevTime = $time;
        }

        $queries = [];
        $slowQueryThresholdMs = 50.0;
        $totalSqlDurationMs = 0.0;
        $slowQueriesCount = 0;

        if (isset($wpdb->queries) && is_array($wpdb->queries)) {
            foreach ($wpdb->queries as $idx => $q) {
                $sql = (string) $q[0];
                $durationMs = round((float) $q[1] * 1000, 2);
                $caller = (string) ($q[2] ?? '');
                $totalSqlDurationMs += $durationMs;
                if ($durationMs > $slowQueryThresholdMs) {
                    $slowQueriesCount++;
                }
                
                // 配对并在过滤后的 SQL 调用栈
                $callStack = self::$queryStacks[$idx] ?? [];

                $queries[] = [
                    'sql' => $sql,
                    'duration_ms' => $durationMs,
                    'caller' => $caller,
                    'slow' => $durationMs > $slowQueryThresholdMs,
                    'call_stack' => $callStack
                ];
            }
        }

        $cacheStats = [
            'local_hits' => 0,
            'remote_hits' => 0,
            'misses' => 0,
            'total' => 0,
            'ratio' => 0.0,
            'global_keys' => [],
            'global_key_count' => 0,
        ];
        if (isset($wp_object_cache) && property_exists($wp_object_cache, 'local_hits')) {
            $local = (int) $wp_object_cache->local_hits;
            $remote = (int) $wp_object_cache->remote_hits;
            $misses = (int) $wp_object_cache->cache_misses;
            $total = $local + $remote + $misses;
            $ratio = $total > 0 ? round((($local + $remote) / $total) * 100, 2) : 0.0;
            $cacheStats = [
                'local_hits' => $local,
                'remote_hits' => $remote,
                'misses' => $misses,
                'total' => $total,
                'ratio' => $ratio,
                'global_keys' => [],
                'global_key_count' => 0,
            ];
        }

        // 获取全局缓存键名列表与数量
        try {
            if (class_exists(\VHttpd\Cache\Client::class)) {
                $cacheClient = \VHttpd\Cache\Client::fromEnv();
                $gKeys = $cacheClient->keys();
                $cacheStats['global_keys'] = $gKeys;
                $cacheStats['global_key_count'] = count($gKeys);
            }
        } catch (\Throwable $e) {
            // 忽略连接失败以防崩溃
        }

        arsort(self::$hookCounts);
        $topHooks = [];
        $count = 0;
        foreach (self::$hookCounts as $tag => $num) {
            if ($count >= 10) {
                break;
            }

            // 提取 Callback 定义位置的反射信息
            $callbacks = [];
            if (isset($wp_filter[$tag]) && $wp_filter[$tag] instanceof \WP_Hook) {
                foreach ($wp_filter[$tag]->callbacks as $priority => $priorityCallbacks) {
                    foreach ($priorityCallbacks as $cbInfo) {
                        $function = $cbInfo['function'];
                        $name = 'unknown';
                        $location = 'unknown';

                        try {
                            if (is_string($function)) {
                                $name = $function;
                                if (function_exists($function)) {
                                    $ref = new \ReflectionFunction($function);
                                    $location = self::cleanPath($ref->getFileName()) . ':' . $ref->getStartLine();
                                }
                            } elseif (is_array($function) && count($function) === 2) {
                                $class = $function[0];
                                $method = $function[1];
                                $className = is_object($class) ? get_class($class) : $class;
                                $name = "{$className}::{$method}";
                                if (method_exists($class, $method)) {
                                    $ref = new \ReflectionMethod($class, $method);
                                    $location = self::cleanPath($ref->getFileName()) . ':' . $ref->getStartLine();
                                }
                            } elseif ($function instanceof \Closure) {
                                $name = 'Closure';
                                $ref = new \ReflectionFunction($function);
                                $location = self::cleanPath($ref->getFileName()) . ':' . $ref->getStartLine();
                            } elseif (is_object($function)) {
                                $className = get_class($function);
                                $name = "{$className}::__invoke";
                                if (method_exists($function, '__invoke')) {
                                    $ref = new \ReflectionMethod($function, '__invoke');
                                    $location = self::cleanPath($ref->getFileName()) . ':' . $ref->getStartLine();
                                }
                            }
                        } catch (\Throwable $e) {
                            $location = 'reflection failed';
                        }

                        $callbacks[] = [
                            'name' => $name,
                            'priority' => $priority,
                            'location' => $location
                        ];
                    }
                }
            }

            $topHooks[] = [
                'tag' => $tag,
                'count' => $num,
                'callbacks' => $callbacks
            ];
            $count++;
        }

        $dbPool = self::fetchDbPoolStats();
        $vhttpdStats = self::fetchVHttpdStats();
        $executors = self::fetchExecutors();
        $vhttpdStats['executors'] = $executors;

        $requestId = getenv('VHTTPD_REQUEST_ID') ?: ($_SERVER['VHTTPD_REQUEST_ID'] ?? 'unknown');
        $traceId = getenv('VHTTPD_TRACE_ID') ?: ($_SERVER['VHTTPD_TRACE_ID'] ?? 'unknown');

        $requestHeaders = function_exists('getallheaders') ? getallheaders() : [];
        if (empty($requestHeaders)) {
            foreach ($_SERVER as $key => $value) {
                if (str_starts_with($key, 'HTTP_')) {
                    $name = str_replace('_', '-', substr($key, 5));
                    $requestHeaders[$name] = $value;
                }
            }
        }

        // 提取部分重要的 SERVER 变量并过滤敏感词
        $importantServerVars = [
            'SERVER_SOFTWARE', 'SERVER_NAME', 'SERVER_ADDR', 'SERVER_PORT',
            'REMOTE_ADDR', 'REMOTE_PORT', 'DOCUMENT_ROOT', 'PHP_SELF',
            'SCRIPT_FILENAME', 'REQUEST_TIME_FLOAT', 'HTTPS'
        ];
        $serverVarsFiltered = [];
        foreach ($importantServerVars as $v) {
            if (isset($_SERVER[$v])) {
                $serverVarsFiltered[$v] = $_SERVER[$v];
            }
        }
        foreach ($_SERVER as $k => $v) {
            if (str_starts_with($k, 'VHTTPD_')) {
                $serverVarsFiltered[$k] = $v;
            }
        }

        $peakMemory = memory_get_peak_usage();
        $memoryDiffBytes = memory_get_usage() - self::$startMemory;
        $memoryDiffFormatted = ($memoryDiffBytes >= 0 ? '+' : '-') . 
            (function_exists('size_format') ? size_format(abs($memoryDiffBytes)) : (abs($memoryDiffBytes) . ' B'));

        $envDiagnostics = [
            'php_version' => PHP_VERSION,
            'wp_version' => $GLOBALS['wp_version'] ?? 'unknown',
            'included_files_count' => count(get_included_files()),
            'peak_memory_bytes' => $peakMemory,
            'peak_memory_formatted' => function_exists('size_format') ? size_format($peakMemory) : ($peakMemory . ' B'),
            'request_method' => $_SERVER['REQUEST_METHOD'] ?? 'GET',
            'request_uri' => $_SERVER['REQUEST_URI'] ?? '',
            'request_id' => $requestId,
            'trace_id' => $traceId,
            'executor' => (PHP_SAPI === 'cli') ? 'php (long-running worker)' : 'php-cgi (CGI)',
            'get_params' => self::maskSensitiveData($_GET),
            'post_params' => self::maskSensitiveData($_POST),
            'cookies' => self::maskSensitiveData($_COOKIE),
            'session' => isset($_SESSION) ? self::maskSensitiveData($_SESSION) : [],
            'request_headers' => $requestHeaders,
            'response_headers' => headers_list(),
            'server_variables' => self::maskSensitiveData($serverVarsFiltered),
        ];

        return [
            'request_id' => $requestId,
            'trace_id' => $traceId,
            'timestamp' => time(),
            'overview' => [
                'total_duration_ms' => $totalDurationMs,
                'sql_duration_ms' => round($totalSqlDurationMs, 2),
                'sql_count' => count($queries),
                'slow_queries_count' => $slowQueriesCount,
                'peak_memory' => function_exists('size_format') ? size_format($peakMemory) : ($peakMemory . ' B'),
                'memory_diff' => $memoryDiffFormatted,
                'cache_ratio' => $cacheStats['ratio'],
            ],
            'checkpoints' => $checkpoints,
            'queries' => $queries,
            'cache' => $cacheStats,
            'hooks' => $topHooks,
            'logs' => self::$logs,
            'errors' => self::$errors,
            'env' => $envDiagnostics,
            'db_pool' => $dbPool,
            'vhttpd' => $vhttpdStats,
            'external_requests' => self::$externalRequests,
        ];
    }
}
