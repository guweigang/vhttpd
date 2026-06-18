<?php

declare(strict_types=1);

require_once __DIR__ . '/../src/VHttpd/WordPress/Lifecycle.php';

use VHttpd\WordPress\Lifecycle;

$previousEnv = getenv('VHTTPD_SCHEME');

$_SERVER = [];
putenv('VHTTPD_SCHEME=https');

$lifecycle = new Lifecycle();
$lifecycle->prepareBootstrapDefaults();

assertSame('443', $_SERVER['SERVER_PORT'] ?? null, 'SERVER_PORT');
assertSame('on', $_SERVER['HTTPS'] ?? null, 'HTTPS');
assertSame('https', $_SERVER['REQUEST_SCHEME'] ?? null, 'REQUEST_SCHEME');
assertSame('https', $_SERVER['HTTP_X_FORWARDED_PROTO'] ?? null, 'HTTP_X_FORWARDED_PROTO');

// Test HEAD request rewriting and response body clearing
$reqHead = $lifecycle->normalizeRequest([
    'method' => 'HEAD',
    'path' => '/cart',
]);
assertSame('GET', $reqHead['method'] ?? null, 'HEAD should be mapped to GET');
assertSame('HEAD', $reqHead['original_method'] ?? null, 'Original method should be stored as HEAD');

$res = [
    'status' => 200,
    'body' => 'hello',
];
$finalRes = $lifecycle->finalizeResponse($reqHead, $res);
assertSame('', $finalRes['body'] ?? null, 'Response body should be cleared for HEAD request');

// Test normal GET request is unaffected
$reqGet = $lifecycle->normalizeRequest([
    'method' => 'GET',
    'path' => '/cart',
]);
assertSame('GET', $reqGet['method'] ?? null, 'GET should remain GET');
assertSame('GET', $reqGet['original_method'] ?? null, 'Original method should be GET');

$finalResGet = $lifecycle->finalizeResponse($reqGet, $res);
assertSame('hello', $finalResGet['body'] ?? null, 'Response body should not be cleared for GET request');

if (is_string($previousEnv)) {
    putenv('VHTTPD_SCHEME=' . $previousEnv);
} else {
    putenv('VHTTPD_SCHEME');
}

echo "ok\n";

function assertSame(mixed $expected, mixed $actual, string $label): void
{
    if ($expected !== $actual) {
        fwrite(STDERR, $label . " failed\nexpected: " . var_export($expected, true) . "\nactual: " . var_export($actual, true) . "\n");
        exit(1);
    }
}
