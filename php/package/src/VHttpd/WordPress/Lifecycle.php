<?php

declare(strict_types=1);

namespace VHttpd\WordPress;

use ReflectionObject;
use RuntimeException;
use Throwable;

final class Lifecycle
{
    public function rootFromEnv(string $envName = 'VPHP_WP_ROOT'): string
    {
        $root = getenv($envName);
        if (!is_string($root) || $root === '') {
            throw new RuntimeException("{$envName} is required for wordpress runtime");
        }

        return rtrim($root, '/');
    }

    public function wpLoadPath(string $root): string
    {
        $wpLoad = rtrim($root, '/') . '/wp-load.php';
        if (!is_file($wpLoad)) {
            throw new RuntimeException('wp-load.php not found: ' . $wpLoad);
        }

        return $wpLoad;
    }

    public function isInstalled(string $root): bool
    {
        return is_file(rtrim($root, '/') . '/wp-config.php');
    }

    public function bootstrap(string $root): void
    {
        if (!defined('WP_USE_THEMES')) {
            define('WP_USE_THEMES', true);
        }

        require_once $this->wpLoadPath($root);
    }

    public function bootstrapIfInstalled(string $root): bool
    {
        if (!$this->isInstalled($root)) {
            return false;
        }

        $this->bootstrap($root);
        return true;
    }

    /** @return array<string,mixed> */
    public function normalizeRequest(mixed $requestOrEnvelope, array $envelope = []): array
    {
        if ($requestOrEnvelope instanceof \Psr\Http\Message\ServerRequestInterface) {
            $request = $requestOrEnvelope;
            $headers = [];
            foreach ($request->getHeaders() as $name => $values) {
                $headers[$name] = implode(', ', $values);
            }

            $serverParams = $request->getServerParams();
            $method = strtoupper($request->getMethod());
            $originalMethod = $method;
            if ($method === 'HEAD') {
                $method = 'GET';
            }

            return $this->normalizeCookieState([
                'path' => $request->getUri()->getPath(),
                'query_string' => $request->getUri()->getQuery(),
                'method' => $method,
                'original_method' => $originalMethod,
                'query' => $request->getQueryParams(),
                'body' => (string) $request->getBody(),
                'headers' => $headers,
                'cookies' => $request->getCookieParams(),
                'server' => $serverParams,
                'host' => $request->getUri()->getHost(),
                'port' => (string) $request->getUri()->getPort(),
                'scheme' => $request->getUri()->getScheme(),
                'remote_addr' => (string) ($serverParams['REMOTE_ADDR'] ?? ''),
                'trace_id' => $this->headerValue($headers, ['x-vhttpd-trace-id', 'X-Vhttpd-Trace-Id', 'X-VHTTPD-TRACE-ID'])
                    ?: (string) ($serverParams['VHTTPD_TRACE_ID'] ?? $serverParams['HTTP_X_VHTTPD_TRACE_ID'] ?? ''),
                'request_id' => $this->headerValue($headers, ['x-request-id', 'X-Request-Id'])
                    ?: (string) ($serverParams['VHTTPD_REQUEST_ID'] ?? $serverParams['HTTP_X_REQUEST_ID'] ?? ''),
            ]);
        }

        $payload = is_array($requestOrEnvelope) ? $requestOrEnvelope : $envelope;
        $path = (string) ($payload['path'] ?? '/');
        $queryString = '';
        if (str_contains($path, '?')) {
            [$path, $queryString] = explode('?', $path, 2);
        }

        $query = $payload['query'] ?? [];
        if ($queryString === '' && is_array($query) && $query !== []) {
            $queryString = http_build_query($query);
        }

        $method = strtoupper((string) ($payload['method'] ?? 'GET'));
        $originalMethod = $method;
        if ($method === 'HEAD') {
            $method = 'GET';
        }

        return $this->normalizeCookieState([
            'path' => $path,
            'query_string' => $queryString,
            'method' => $method,
            'original_method' => $originalMethod,
            'query' => is_array($query) ? $query : [],
            'body' => (string) ($payload['body'] ?? ''),
            'headers' => is_array($payload['headers'] ?? null) ? $payload['headers'] : [],
            'cookies' => is_array($payload['cookies'] ?? null) ? $payload['cookies'] : [],
            'server' => is_array($payload['server'] ?? null) ? $payload['server'] : [],
            'host' => (string) ($payload['host'] ?? ''),
            'port' => (string) ($payload['port'] ?? ''),
            'scheme' => $this->requestScheme(
                is_array($payload['headers'] ?? null) ? $payload['headers'] : [],
                (string) ($payload['scheme'] ?? 'http'),
            ),
            'remote_addr' => (string) ($payload['remote_addr'] ?? ''),
            'trace_id' => $this->requestTraceId($payload),
            'request_id' => $this->requestRequestId($payload),
        ]);
    }

    /** @param array<string,mixed> $request */
    public function prepareEnvironment(array $request): void
    {
        $path = (string) ($request['path'] ?? '/');
        $queryString = (string) ($request['query_string'] ?? '');
        $method = strtoupper((string) ($request['method'] ?? 'GET'));
        $headers = is_array($request['headers'] ?? null) ? $request['headers'] : [];
        $query = is_array($request['query'] ?? null) ? $request['query'] : [];
        $cookies = is_array($request['cookies'] ?? null) ? $request['cookies'] : [];
        $body = (string) ($request['body'] ?? '');
        $host = (string) ($request['host'] ?? '');
        $port = (string) ($request['port'] ?? '');
        $scheme = (string) ($request['scheme'] ?? 'http');
        $traceId = (string) ($request['trace_id'] ?? '');
        $requestId = (string) ($request['request_id'] ?? '');

        $_SERVER['REQUEST_URI'] = $path . ($queryString !== '' ? '?' . $queryString : '');
        $_SERVER['REQUEST_METHOD'] = $method;
        $_SERVER['QUERY_STRING'] = $queryString;
        $_SERVER['HTTP_HOST'] = $this->hostHeader($host, $port);
        $_SERVER['SERVER_NAME'] = $host !== '' ? $host : 'localhost';
        $_SERVER['SERVER_PORT'] = $port !== '' ? $port : ($scheme === 'https' ? '443' : '80');
        $_SERVER['HTTPS'] = $scheme === 'https' ? 'on' : 'off';
        $_SERVER['REQUEST_SCHEME'] = $scheme;
        $_SERVER['HTTP_X_FORWARDED_PROTO'] = $scheme;
        $_SERVER['REMOTE_ADDR'] = (string) ($request['remote_addr'] ?? '127.0.0.1') ?: '127.0.0.1';
        $_SERVER['HTTP_COOKIE'] = (string) ($request['cookie_header'] ?? '');
        $_SERVER['VHTTPD_TRACE_ID'] = $traceId;
        $_SERVER['VHTTPD_REQUEST_ID'] = $requestId;
        $_SERVER['HTTP_X_VHTTPD_TRACE_ID'] = $traceId;
        $_SERVER['HTTP_X_REQUEST_ID'] = $requestId;
        putenv('VHTTPD_TRACE_ID=' . $traceId);
        putenv('VHTTPD_REQUEST_ID=' . $requestId);
        $this->refreshDependencyUrls($scheme);

        $_GET = $query;
        $_POST = [];
        if ($method === 'POST') {
            $contentType = $headers['content-type'] ?? $headers['Content-Type'] ?? '';
            if (is_array($contentType)) {
                $contentType = implode(', ', $contentType);
            }
            if (str_contains(strtolower((string) $contentType), 'application/x-www-form-urlencoded')) {
                parse_str($body, $_POST);
            }
        }
        $_COOKIE = $cookies;
        $_REQUEST = array_merge($_GET, $_POST, $_COOKIE);
    }

    public function prepareBootstrapDefaults(): void
    {
        $scheme = $this->bootstrapScheme();

        $_SERVER['HTTP_HOST'] = $_SERVER['HTTP_HOST'] ?? 'localhost';
        $_SERVER['REQUEST_URI'] = $_SERVER['REQUEST_URI'] ?? '/';
        $_SERVER['REQUEST_METHOD'] = $_SERVER['REQUEST_METHOD'] ?? 'GET';
        $_SERVER['SERVER_NAME'] = $_SERVER['SERVER_NAME'] ?? 'localhost';
        $_SERVER['SERVER_PORT'] = $_SERVER['SERVER_PORT'] ?? ($scheme === 'https' ? '443' : '80');
        $_SERVER['HTTPS'] = $_SERVER['HTTPS'] ?? ($scheme === 'https' ? 'on' : 'off');
        $_SERVER['REQUEST_SCHEME'] = $_SERVER['REQUEST_SCHEME'] ?? $scheme;
        $_SERVER['HTTP_X_FORWARDED_PROTO'] = $_SERVER['HTTP_X_FORWARDED_PROTO'] ?? $scheme;
        $_SERVER['REMOTE_ADDR'] = $_SERVER['REMOTE_ADDR'] ?? '127.0.0.1';
    }

    public function resetRequestRuntime(): void
    {
        global $wp_styles, $wp_scripts, $wp_script_modules, $current_user, $wp_admin_bar;

        if ($wp_styles instanceof \WP_Styles) {
            $this->resetDependencyRuntime($wp_styles);
            $this->setPrivateProperty($wp_styles, 'all_queued_deps', null);
        }
        if ($wp_scripts instanceof \WP_Scripts) {
            $this->resetDependencyRuntime($wp_scripts);
            $this->setPrivateProperty($wp_scripts, 'all_queued_deps', null);
            $this->setPrivateProperty($wp_scripts, 'dependents_map', []);
        }
        if (isset($wp_script_modules) && $wp_script_modules instanceof \WP_Script_Modules) {
            $this->setPrivateProperty($wp_script_modules, 'queue', []);
            $this->setPrivateProperty($wp_script_modules, 'done', []);
            $this->setPrivateProperty($wp_script_modules, 'dependents_map', []);
        }

        $current_user = null;
        $wp_admin_bar = null;
        unset($GLOBALS['show_admin_bar']);
        $GLOBALS['vhttpd_wp_admin_bar_rendered'] = false;

        if (function_exists('remove_action')) {
            remove_action('wp_body_open', 'wp_admin_bar_render', 0);
            remove_action('wp_footer', 'wp_admin_bar_render', 1000);
        }
        if (function_exists('add_action')) {
            if (false === has_action('wp_body_open', [self::class, 'renderAdminBar'])) {
                add_action('wp_body_open', [self::class, 'renderAdminBar'], 0);
            }
            if (false === has_action('wp_footer', [self::class, 'renderAdminBar'])) {
                add_action('wp_footer', [self::class, 'renderAdminBar'], 1000);
            }
        }
    }

    public static function renderAdminBar(): void
    {
        global $wp_admin_bar;

        if (!empty($GLOBALS['vhttpd_wp_admin_bar_rendered'])) {
            return;
        }
        if (!function_exists('is_admin_bar_showing') || !is_admin_bar_showing() || !is_object($wp_admin_bar)) {
            return;
        }

        do_action_ref_array('admin_bar_menu', [&$wp_admin_bar]);
        do_action('wp_before_admin_bar_render');
        $wp_admin_bar->render();
        do_action('wp_after_admin_bar_render');

        $GLOBALS['vhttpd_wp_admin_bar_rendered'] = true;
    }

    /** @param array<string,mixed> $request */
    private function normalizeCookieState(array $request): array
    {
        $headers = is_array($request['headers'] ?? null) ? $request['headers'] : [];
        $cookies = is_array($request['cookies'] ?? null) ? $request['cookies'] : [];
        $cookieHeader = $this->cookieHeader($headers);
        if ($cookieHeader !== '') {
            $cookies = array_merge($cookies, $this->parseCookieHeader($cookieHeader));
        }
        foreach ($cookies as $name => $value) {
            if (is_string($value)) {
                $cookies[$name] = urldecode($value);
            }
        }

        $request['headers'] = $headers;
        $request['cookies'] = $cookies;
        $request['cookie_header'] = $cookieHeader;

        return $request;
    }

    /** @param array<string,mixed> $headers */
    private function cookieHeader(array $headers): string
    {
        foreach (['cookie', 'Cookie', 'COOKIE', 'http_cookie', 'HTTP_COOKIE'] as $name) {
            $value = $headers[$name] ?? '';
            if (is_array($value)) {
                $value = implode('; ', $value);
            }
            if (is_string($value) && $value !== '') {
                return $value;
            }
        }
        return '';
    }

    /** @param array<string,mixed> $headers */
    private function requestScheme(array $headers, string $fallback): string
    {
        foreach (['x-forwarded-proto', 'X-Forwarded-Proto', 'HTTP_X_FORWARDED_PROTO', 'x-scheme', 'X-Scheme'] as $name) {
            $value = $headers[$name] ?? '';
            if (is_array($value)) {
                $value = reset($value);
            }
            if (is_string($value) && strtolower(trim($value)) === 'https') {
                return 'https';
            }
        }

        return strtolower(trim($fallback)) === 'https' ? 'https' : 'http';
    }

    private function bootstrapScheme(): string
    {
        foreach (['VHTTPD_SCHEME', 'VHTTPD_REQUEST_SCHEME', 'REQUEST_SCHEME', 'HTTP_X_FORWARDED_PROTO'] as $name) {
            $value = getenv($name);
            if (is_string($value) && strtolower(trim($value)) === 'https') {
                return 'https';
            }
        }

        return 'http';
    }

    /** @param array<string,mixed> $payload */
    private function requestTraceId(array $payload): string
    {
        $headers = is_array($payload['headers'] ?? null) ? $payload['headers'] : [];
        $traceId = $this->headerValue($headers, ['x-vhttpd-trace-id', 'X-Vhttpd-Trace-Id', 'X-VHTTPD-TRACE-ID', 'HTTP_X_VHTTPD_TRACE_ID']);
        if ($traceId !== '') {
            return $traceId;
        }
        return (string) ($payload['trace_id'] ?? $payload['id'] ?? '');
    }

    /** @param array<string,mixed> $payload */
    private function requestRequestId(array $payload): string
    {
        $headers = is_array($payload['headers'] ?? null) ? $payload['headers'] : [];
        $requestId = $this->headerValue($headers, ['x-request-id', 'X-Request-Id', 'HTTP_X_REQUEST_ID']);
        if ($requestId !== '') {
            return $requestId;
        }
        return (string) ($payload['request_id'] ?? '');
    }

    /**
     * @param array<string,mixed> $headers
     * @param array<int,string> $names
     */
    private function headerValue(array $headers, array $names): string
    {
        foreach ($names as $name) {
            $value = $headers[$name] ?? '';
            if (is_array($value)) {
                $value = reset($value);
            }
            if (is_string($value) && trim($value) !== '') {
                return trim($value);
            }
        }
        return '';
    }

    /** @return array<string,string> */
    private function parseCookieHeader(string $header): array
    {
        $cookies = [];
        foreach (explode(';', $header) as $part) {
            $part = trim($part);
            if ($part === '' || !str_contains($part, '=')) {
                continue;
            }
            [$name, $value] = explode('=', $part, 2);
            $name = trim($name);
            if ($name === '') {
                continue;
            }
            $cookies[$name] = urldecode($value);
        }
        return $cookies;
    }

    private function hostHeader(string $host, string $port): string
    {
        $hostHeader = $host !== '' ? $host : 'localhost';
        if ($port !== '' && $port !== '80' && $port !== '443') {
            $hostHeader .= ':' . $port;
        }
        return $hostHeader;
    }

    private function resetDependencyRuntime(object $deps): void
    {
        foreach (['queue', 'to_do', 'done', 'args', 'groups'] as $property) {
            if (property_exists($deps, $property)) {
                $deps->{$property} = [];
            }
        }
        foreach (['concat', 'concat_version', 'print_html', 'print_code', 'ext_handles', 'ext_version'] as $property) {
            if (property_exists($deps, $property)) {
                $deps->{$property} = '';
            }
        }
        if (property_exists($deps, 'do_concat')) {
            $deps->do_concat = false;
        }
        if (property_exists($deps, 'in_footer')) {
            $deps->in_footer = [];
        }
    }

    private function refreshDependencyUrls(string $scheme): void
    {
        global $wp_styles, $wp_scripts;

        $baseUrl = function_exists('site_url') ? site_url('', $scheme) : '';
        $contentUrl = function_exists('content_url') ? content_url() : '';
        if ($contentUrl !== '' && function_exists('set_url_scheme')) {
            $contentUrl = set_url_scheme($contentUrl, $scheme);
        }

        foreach ([$wp_styles ?? null, $wp_scripts ?? null] as $deps) {
            if (!is_object($deps)) {
                continue;
            }
            if ($baseUrl !== '' && property_exists($deps, 'base_url')) {
                $deps->base_url = $baseUrl;
            }
            if ($contentUrl !== '' && property_exists($deps, 'content_url')) {
                $deps->content_url = $contentUrl;
            }
            if (property_exists($deps, 'registered') && is_array($deps->registered) && function_exists('set_url_scheme')) {
                foreach ($deps->registered as $handle) {
                    if (is_object($handle) && property_exists($handle, 'src') && is_string($handle->src)
                        && preg_match('#^https?://#i', $handle->src) === 1) {
                        $handle->src = set_url_scheme($handle->src, $scheme);
                    }
                }
            }
        }
    }

    private function setPrivateProperty(object $object, string $property, mixed $value): void
    {
        try {
            $reflection = new ReflectionObject($object);
            if (!$reflection->hasProperty($property)) {
                return;
            }
            $refProperty = $reflection->getProperty($property);
            $refProperty->setValue($object, $value);
        } catch (Throwable) {
            // WordPress internals differ by version; request cleanup is best-effort.
        }
    }

    /**
     * @param array<string,mixed> $request
     * @param array<string,mixed> $response
     * @return array<string,mixed>
     */
    public function finalizeResponse(array $request, array $response): array
    {
        $originalMethod = strtoupper((string) ($request['original_method'] ?? $request['method'] ?? 'GET'));
        if ($originalMethod === 'HEAD') {
            $response['body'] = '';
        }
        return $response;
    }
}

