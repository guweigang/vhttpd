<?php

declare(strict_types=1);

require_once __DIR__ . '/VHttpd/PhpWorker/Server.php';

if (!function_exists('vhttpd_stream_sse')) {
    function vhttpd_stream_sse(
        iterable $events,
        int $status = 200,
        array $headers = [],
    ): \VPhp\VHttpd\PhpWorker\StreamResponse {
        return \VPhp\VHttpd\PhpWorker\StreamResponse::sse($events, $status, $headers);
    }
}

if (!function_exists('vhttpd_stream_text')) {
    function vhttpd_stream_text(
        iterable $chunks,
        int $status = 200,
        string $contentType = 'text/plain; charset=utf-8',
        array $headers = [],
    ): \VPhp\VHttpd\PhpWorker\StreamResponse {
        return \VPhp\VHttpd\PhpWorker\StreamResponse::text($chunks, $status, $contentType, $headers);
    }
}
