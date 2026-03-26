<?php
declare(strict_types=1);

use VPhp\VSlim\Stream\OllamaClient;

return static function (mixed $request, array $envelope = []): array|\VPhp\VHttpd\Upstream\Plan {
    $src = is_array($request) ? $request : $envelope;
    $method = strtoupper((string) ($src['method'] ?? 'GET'));
    $pathWithQuery = (string) ($src['path'] ?? '/');
    $path = (string) (parse_url($pathWithQuery, PHP_URL_PATH) ?? '/');

    if ($path === '/ollama/health') {
        return [
            'status' => 200,
            'content_type' => 'text/plain; charset=utf-8',
            'body' => 'OK',
        ];
    }

    if (!in_array($method, ['GET', 'POST'], true)) {
        return [
            'status' => 405,
            'content_type' => 'text/plain; charset=utf-8',
            'body' => 'Method Not Allowed',
        ];
    }

    $normalized = [
        'method' => $method,
        'path' => $path,
        'query' => is_array($src['query'] ?? null) ? $src['query'] : [],
        'body' => (string) ($src['body'] ?? ''),
    ];

    $client = OllamaClient::fromEnv();
    $payload = $client->payload($normalized);

    if ($path === '/ollama/text') {
        return $client->upstreamPlan($payload, 'text');
    }
    if ($path === '/ollama/sse') {
        return $client->upstreamPlan($payload, 'sse');
    }

    return [
        'status' => 404,
        'content_type' => 'application/json; charset=utf-8',
        'body' => json_encode([
            'error' => 'Not Found',
            'hint' => 'Use /ollama/text or /ollama/sse',
            'mode' => 'stream',
            'strategy' => 'upstream_plan',
        ], JSON_UNESCAPED_UNICODE),
    ];
};
