<?php

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

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

$reqCookie = $lifecycle->normalizeRequest([
    'method' => 'GET',
    'path' => '/cart',
    'headers' => [
        'cookie' => 'wordpress_logged_in_test=token%252Fstill_encoded; plain=value',
    ],
]);
assertSame(
    'token%2Fstill_encoded',
    $reqCookie['cookies']['wordpress_logged_in_test'] ?? null,
    'Cookie values should be decoded exactly once'
);
assertSame('value', $reqCookie['cookies']['plain'] ?? null, 'Plain cookie should survive normalization');

$finalResGet = $lifecycle->finalizeResponse($reqGet, $res);
assertSame('hello', $finalResGet['body'] ?? null, 'Response body should not be cleared for GET request');

// Verify that the new Session classes can be autoloaded
assertSame(true, class_exists(\VHttpd\PhpWorker\SessionHandler::class), 'SessionHandler should be loadable');

// Test SessionHandler using Mock cache client
$mockClient = new class {
    public array $storage = [];
    public function get(string $key): ?string {
        return $this->storage[$key] ?? null;
    }
    public function set(string $key, string $value, int $ttlMs = 0): bool {
        $this->storage[$key] = $value;
        return true;
    }
    public function delete(string $key): bool {
        unset($this->storage[$key]);
        return true;
    }
};

// Ensure mockClient conforms to a shape containing get/set/delete (like Cache\Client)
$phpSessionHandler = new \VHttpd\PhpWorker\SessionHandler($mockClient); // @phpstan-ignore-line
$phpSessionHandler->write('sess_id', 'some_session_data');
assertSame('some_session_data', $mockClient->storage['php_session:sess_id'], 'General PHP Session write');
assertSame('some_session_data', $phpSessionHandler->read('sess_id'), 'General PHP Session read');
$phpSessionHandler->destroy('sess_id');
assertSame(null, $mockClient->storage['php_session:sess_id'] ?? null, 'General PHP Session destroy');

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
