<?php

declare(strict_types=1);

use VPhp\VSlim\Stream\Factory as StreamFactory;

$html = <<<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>vhttpd Stream Dispatch Demo</title>
  <style>
    body { font-family: Georgia, serif; margin: 40px auto; max-width: 840px; color: #17212b; background: #f6f2eb; }
    .card { background: #fffdf9; border: 1px solid #dbcdb8; border-radius: 18px; padding: 20px; box-shadow: 0 12px 30px rgba(0,0,0,.05); }
    button { padding: 10px 16px; border-radius: 999px; border: 0; background: #1f5f8b; color: white; cursor: pointer; }
    pre { min-height: 240px; padding: 16px; background: #0f1720; color: #d6e7ff; border-radius: 16px; overflow: auto; }
    code { background: rgba(0,0,0,.06); padding: .15em .35em; border-radius: 6px; }
  </style>
</head>
<body>
  <div class="card">
    <p><strong>vhttpd Stream Dispatch MVP</strong></p>
    <p>This page uses the <code>stream</code> surface with <code>dispatch</code> strategy. The SSE connection stays in <code>vhttpd</code>, while the worker only handles short-lived <code>open</code>/<code>next</code>/<code>close</code> events.</p>
    <p><button id="start" type="button">Start synthetic SSE stream</button></p>
    <pre id="log">Idle.</pre>
  </div>
  <script>
    const log = document.getElementById('log');
    const start = document.getElementById('start');
    let es = null;
    const write = (line) => {
      log.textContent += (log.textContent === 'Idle.' ? '' : '\n') + line;
    };
    start.addEventListener('click', () => {
      if (es) es.close();
      log.textContent = '';
      es = new EventSource('/events/sse');
      es.addEventListener('tick', (event) => write('tick ' + event.data));
      es.addEventListener('done', (event) => {
        write('done ' + event.data);
        es.close();
      });
      es.onerror = () => write('error');
    });
  </script>
</body>
</html>
HTML;

$http = static function (mixed $request, array $envelope = []) use ($html): array {
    $env = is_array($request) && $envelope === [] ? $request : $envelope;
    $path = (string) ($env['path'] ?? '/');
    if ($path === '/' || $path === '') {
        return [
            'status' => 200,
            'headers' => ['content-type' => 'text/html; charset=utf-8'],
            'body' => $html,
        ];
    }
    if ($path === '/meta') {
        return [
            'status' => 200,
            'headers' => ['content-type' => 'application/json; charset=utf-8'],
            'body' => (string) json_encode([
                'name' => 'vhttpd-stream-dispatch-demo',
                'stream' => '/events/sse',
                'mode' => 'stream',
                'strategy' => 'dispatch',
            ], JSON_UNESCAPED_UNICODE),
        ];
    }
    return [
        'status' => 404,
        'headers' => ['content-type' => 'text/plain; charset=utf-8'],
        'body' => 'Not Found',
    ];
};

$stream = StreamFactory::dispatchSse(
    (static function (): iterable {
        for ($i = 0; $i < 5; $i++) {
            yield ['event' => 'tick', 'data' => (string) $i];
        }
        yield ['event' => 'done', 'data' => 'stream complete'];
    })(),
    200,
    [
        'cache-control' => 'no-cache',
        'x-stream-source' => 'stream',
    ],
    1,
    80,
);

return [
    'http' => $http,
    'stream' => static function (array $frame) use ($stream): mixed {
        if (($frame['path'] ?? '/events/sse') !== '/events/sse' && ($frame['event'] ?? '') === 'open') {
            return ['handled' => false, 'done' => true];
        }
        return $stream->handle($frame);
    },
];
