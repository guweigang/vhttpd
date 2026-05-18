<?php
declare(strict_types=1);

$app = new VSlim\App();

$app->getNamed('hello.show', '/hello/:name', function (mixed $req) {
    $name = method_exists($req, 'getAttribute') ? (string) $req->getAttribute('name') : (string) $req->param('name');
    return [
        'status' => 200,
        'content_type' => 'text/plain; charset=utf-8',
        'headers' => ['x-runtime' => 'vslim'],
        'body' => 'Hello, ' . $name,
    ];
});

$app->get('/go/:name', function (mixed $req) use ($app) {
    $name = method_exists($req, 'getAttribute') ? (string) $req->getAttribute('name') : (string) $req->param('name');
    return [
        'status' => 302,
        'content_type' => 'text/plain; charset=utf-8',
        'headers' => [
            'location' => $app->urlFor('hello.show', ['name' => $name]),
            'x-runtime' => 'vslim',
        ],
        'body' => '',
    ];
});

$api = $app->group('/api');
$api->get('/meta', function (mixed $req) use ($app) {
    $uri = method_exists($req, 'getUri') ? $req->getUri() : null;
    $path = $uri !== null && method_exists($uri, 'getPath') ? $uri->getPath() : (string) $req->path;
    $secure = $uri !== null && method_exists($uri, 'getScheme') ? $uri->getScheme() === 'https' : $req->isSecure();
    $host = $uri !== null && method_exists($uri, 'getHost') ? $uri->getHost() : (string) $req->host;
    return [
        'status' => 200,
        'content_type' => 'application/json; charset=utf-8',
        "headers" => ["x-runtime" => "vslim"],
        'body' => json_encode([
            'path' => $path,
            'secure' => $secure,
            'host' => $host,
            'hello_url' => $app->urlFor('hello.show', ['name' => 'codex']),
        ]),
    ];
});

return $app;
