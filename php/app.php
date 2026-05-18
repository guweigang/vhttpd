<?php

declare(strict_types=1);

require_once __DIR__ . '/app/MyFeishuBot.php';

$app = VSlim\App::demo();
$feishuBotApp = new \VSlim\App\Feishu\BotApp(new \VHttpd\App\MyFeishuBot());

$http = static function (mixed $request, array $envelope = []) use ($app): mixed {
    if (is_object($request)) {
        return \VSlim\Psr7Adapter::dispatch($app, $request);
    }

    $toResponse = static function (array $map): array {
        $headers = [];
        foreach ($map as $key => $value) {
            if (is_string($key) && str_starts_with($key, 'headers_')) {
                $name = substr($key, 8);
                if ($name !== '') {
                    $headers[$name] = (string) $value;
                }
            }
        }
        return [
            'status' => (int) ($map['status'] ?? 200),
            'content_type' => (string) ($map['content_type'] ?? ($headers['content-type'] ?? 'text/plain; charset=utf-8')),
            'headers' => $headers,
            'body' => (string) ($map['body'] ?? ''),
        ];
    };

    if (is_array($request)) {
        if (method_exists($app, 'dispatchEnvelopeMap')) {
            return $toResponse($app->dispatchEnvelopeMap($request));
        }
    }

    if ($envelope !== []) {
        if (method_exists($app, 'dispatchEnvelopeMap')) {
            return $toResponse($app->dispatchEnvelopeMap($envelope));
        }
    }

    return [
        'status' => 500,
        'content_type' => 'text/plain; charset=utf-8',
        'body' => 'No request payload available',
    ];
};

return [
    'http' => $http,
    'websocket_upstream' => static fn (array $frame): array => $feishuBotApp->handle($frame),
];
