<?php

declare(strict_types=1);

use VPhp\VSlim\Mcp\App;

$mcp = (new App(
    ['name' => 'vhttpd-mcp-demo', 'version' => '0.1.0'],
    []
))->capabilities([
    'logging' => [],
    'sampling' => [],
])->tool(
    'echo',
    'Echo text back to the caller',
    [
        'type' => 'object',
        'properties' => [
            'text' => ['type' => 'string'],
        ],
        'required' => ['text'],
    ],
    static function (array $arguments): array {
        return [
            'content' => [
                ['type' => 'text', 'text' => (string) ($arguments['text'] ?? '')],
            ],
            'isError' => false,
        ];
    },
)->resource(
    'resource://demo/readme',
    'demo-readme',
    'Read the demo MCP resource payload',
    'text/plain',
    static function (): string {
        return "vhttpd mcp demo resource\n";
    },
)->prompt(
    'welcome',
    'Build a welcome prompt for a named user',
    [
        [
            'name' => 'name',
            'description' => 'Display name for the user',
            'required' => true,
        ],
    ],
    static function (array $arguments): array {
        $name = (string) ($arguments['name'] ?? 'guest');
        return [
            'description' => 'Welcome prompt',
            'messages' => [
                [
                    'role' => 'user',
                    'content' => [
                        [
                            'type' => 'text',
                            'text' => 'Welcome, ' . $name . '!',
                        ],
                    ],
                ],
            ],
        ];
    },
)->register('debug/notify', static function (array $request, array $frame): array {
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $text = (string) ($params['text'] ?? 'hello from server');
    return App::notify(
        $request['id'] ?? null,
        'notifications/message',
        ['text' => $text],
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
        ['queued' => true],
        200,
        ['content-type' => 'application/json; charset=utf-8'],
    );
})->register('debug/sample', static function (array $request, array $frame): array {
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $topic = (string) ($params['topic'] ?? 'vhttpd');
    return App::queueSampling(
        $request['id'] ?? null,
        'sample-' . (string) ($request['id'] ?? '1'),
        [
            [
                'role' => 'user',
                'content' => [
                    [
                        'type' => 'text',
                        'text' => 'Summarize topic: ' . $topic,
                    ],
                ],
            ],
        ],
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
        ['hints' => [['name' => 'qwen2.5']]],
        'You are a concise assistant.',
        128,
    );
})->register('debug/progress', static function (array $request, array $frame): array {
    return App::queueProgress(
        $request['id'] ?? null,
        'demo-progress',
        50,
        100,
        'Half way there',
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
    );
})->register('debug/log', static function (array $request, array $frame): array {
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $message = (string) ($params['message'] ?? 'runtime note');
    return App::queueLog(
        $request['id'] ?? null,
        'info',
        $message,
        ['scope' => 'demo', 'message' => $message],
        'vhttpd-mcp-demo',
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
    );
})->register('debug/request', static function (array $request, array $frame): array {
    $params = is_array($request['params'] ?? null) ? $request['params'] : [];
    $method = (string) ($params['method'] ?? 'ping');
    return App::queueRequest(
        $request['id'] ?? null,
        'req-' . (string) ($request['id'] ?? '1'),
        $method,
        ['from' => 'server'],
        (string) ($frame['session_id'] ?? ''),
        (string) ($frame['protocol_version'] ?? '2025-11-05'),
    );
});

return [
    'mcp' => $mcp,
];
