<?php

declare(strict_types=1);

use VPhp\VSlim\WebSocket\App;
use VPhp\VHttpd\PhpWorker\WebSocket\Connection;

$html = <<<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>vhttpd WebSocket Echo Demo</title>
  <script defer src="/assets/websocket_echo_app.js"></script>
  <style>
    :root {
      color-scheme: light;
      --bg: #f5efe3;
      --panel: #fffdf8;
      --line: #dbcdb8;
      --ink: #172033;
      --muted: #667085;
      --accent: #b93815;
      --accent-2: #0c6d68;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", serif;
      color: var(--ink);
      background:
        radial-gradient(circle at top left, rgba(185, 56, 21, 0.14), transparent 28%),
        radial-gradient(circle at top right, rgba(12, 109, 104, 0.16), transparent 24%),
        linear-gradient(180deg, #fbf7ef 0%, var(--bg) 100%);
    }
    main {
      max-width: 1040px;
      margin: 0 auto;
      padding: 36px 20px 56px;
    }
    .hero {
      display: grid;
      gap: 12px;
      margin-bottom: 24px;
    }
    .eyebrow {
      margin: 0;
      color: var(--accent-2);
      font-size: 12px;
      letter-spacing: 0.12em;
      text-transform: uppercase;
    }
    h1 {
      margin: 0;
      font-size: clamp(34px, 5vw, 60px);
      line-height: 0.98;
    }
    .sub {
      margin: 0;
      max-width: 760px;
      color: var(--muted);
      font-size: 18px;
      line-height: 1.7;
    }
    .grid {
      display: grid;
      gap: 18px;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
    }
    .panel {
      background: rgba(255, 253, 248, 0.9);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 18px;
      box-shadow: 0 18px 46px rgba(23, 32, 51, 0.08);
      backdrop-filter: blur(8px);
    }
    .label {
      display: block;
      margin-bottom: 8px;
      color: var(--muted);
      font-size: 13px;
    }
    input, textarea, button {
      width: 100%;
      font: inherit;
    }
    input, textarea {
      border: 1px solid var(--line);
      border-radius: 14px;
      background: white;
      color: var(--ink);
      padding: 12px 14px;
    }
    textarea {
      resize: vertical;
      min-height: 220px;
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 14px;
      line-height: 1.5;
    }
    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 14px;
    }
    button {
      width: auto;
      border: 0;
      border-radius: 999px;
      padding: 10px 16px;
      cursor: pointer;
      background: var(--ink);
      color: white;
    }
    button.secondary {
      background: white;
      color: var(--ink);
      border: 1px solid var(--line);
    }
    .meta {
      margin-top: 12px;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.6;
    }
    code {
      background: rgba(0, 0, 0, 0.04);
      border-radius: 6px;
      padding: 0.15em 0.35em;
    }
  </style>
</head>
<body>
  <main data-websocket-demo="1">
    <section class="hero">
      <p class="eyebrow">vhttpd + php-worker + net.websocket</p>
      <h1>WebSocket Echo Demo</h1>
      <p class="sub">
        This page connects to <code>/ws</code> through <code>vhttpd</code>.
        The HTTP upgrade happens in V, frame handling is delegated to V's built-in
        <code>net.websocket</code>, and message logic runs in the PHP worker.
      </p>
    </section>

    <section class="grid">
      <div class="panel">
        <label class="label" for="ws-url">WebSocket URL</label>
        <input id="ws-url" value="ws://127.0.0.1:19888/ws">

        <label class="label" for="ws-message" style="margin-top: 14px;">Message</label>
        <input id="ws-message" value="hello">

        <div class="actions">
          <button id="ws-connect" type="button">Connect</button>
          <button id="ws-send" type="button">Send</button>
          <button id="ws-bye" type="button">Send bye</button>
          <button id="ws-disconnect" class="secondary" type="button">Disconnect</button>
          <button id="ws-clear" class="secondary" type="button">Clear Log</button>
        </div>

        <div class="meta">
          <div>HTTP page: <code>/</code></div>
          <div>WebSocket endpoint: <code>/ws</code></div>
          <div>Expected echo: <code>echo:&lt;message&gt;</code></div>
        </div>
      </div>

      <div class="panel">
        <div class="label">Log</div>
        <textarea id="ws-log" readonly></textarea>
        <div class="meta" id="ws-status">Idle.</div>
      </div>
    </section>
  </main>
</body>
</html>
HTML;

return [
    'http' => static function (array $envelope) use ($html): array {
        $path = (string) ($envelope['path'] ?? '/');
        if ($path === '/' || str_starts_with($path, '/?')) {
            return [
                'status' => 200,
                'headers' => [
                    'content-type' => 'text/html; charset=utf-8',
                ],
                'body' => $html,
            ];
        }
        if ($path === '/health') {
            return [
                'status' => 200,
                'headers' => [
                    'content-type' => 'text/plain; charset=utf-8',
                ],
                'body' => 'OK',
            ];
        }
        if ($path === '/meta') {
            return [
                'status' => 200,
                'headers' => [
                    'content-type' => 'application/json; charset=utf-8',
                ],
                'body' => json_encode([
                    'name' => 'vhttpd-websocket-echo-demo',
                    'page' => '/',
                    'websocket' => '/ws',
                ], JSON_UNESCAPED_UNICODE),
            ];
        }
        return [
            'status' => 404,
            'headers' => [
                'content-type' => 'text/plain; charset=utf-8',
            ],
            'body' => 'Not Found',
        ];
    },
    'websocket' => new App(
        onOpen: function (Connection $conn, array $frame): void {
            $conn->accept();
            $conn->send('echo:connected');
        },
        onMessage: function (Connection $conn, string $message, array $frame): ?string {
            if ($message === 'bye') {
                $conn->close(1000, 'bye');
                return null;
            }
            return 'echo:' . $message;
        },
        onClose: function (Connection $conn, int $code, string $reason, array $frame): void {
        },
    ),
];
