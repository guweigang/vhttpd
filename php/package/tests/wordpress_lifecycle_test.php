<?php

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

// Mock WooCommerce session base classes for testing
if (!class_exists('WC_Session')) {
    class WC_Session {}
}
if (!class_exists('WC_Session_Handler')) {
    class WC_Session_Handler extends WC_Session {}
}

// Define the WC_SESSION_CACHE_GROUP constant if not defined
if (!defined('WC_SESSION_CACHE_GROUP')) {
    define('WC_SESSION_CACHE_GROUP', 'session');
}

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

// Mock wp_cache_* and serializing functions for WooCommerceSessionHandler testing
$GLOBALS['cacheCalls'] = [];
if (!function_exists('wp_cache_get')) {
    function wp_cache_get($key, $group = '') {
        $GLOBALS['cacheCalls']['get'][] = [$key, $group];
        if ($key === 'session_prefix_cust123') {
            return serialize(['cart_data' => 'yes']);
        }
        return false;
    }
}
if (!function_exists('wp_cache_set')) {
    function wp_cache_set($key, $value, $group = '', $ttl = 0) {
        $GLOBALS['cacheCalls']['set'][] = [$key, $value, $group, $ttl];
        return true;
    }
}
if (!function_exists('wp_cache_delete')) {
    function wp_cache_delete($key, $group = '') {
        $GLOBALS['cacheCalls']['delete'][] = [$key, $group];
        return true;
    }
}
if (!function_exists('maybe_unserialize')) {
    function maybe_unserialize($original) {
        if (is_string($original)) {
            $unserialized = @unserialize($original);
            return $unserialized !== false || $original === serialize(false) ? $unserialized : $original;
        }
        return $original;
    }
}
if (!function_exists('get_user_by')) {
    function get_user_by($field, $value) {
        return false;
    }
}

// Verify that the new Session classes can be autoloaded
assertSame(true, class_exists(\VHttpd\WordPress\WooCommerceSessionHandler::class), 'WooCommerceSessionHandler should be loadable');
assertSame(true, class_exists(\VHttpd\PhpWorker\SessionHandler::class), 'SessionHandler should be loadable');

// Instantiate WooCommerceSessionHandler and test get_session
$GLOBALS['wpdb'] = new stdClass();
$GLOBALS['wpdb']->prefix = 'wp_';

$handler = new \VHttpd\WordPress\WooCommerceSessionHandler();

// Set private expiration via Reflection
$ref = new ReflectionObject($handler);
$expProp = $ref->getProperty('_session_expiration');
$expProp->setAccessible(true);
$expProp->setValue($handler, time() + 3600);

$sessionData = $handler->get_session('cust123');
assertSame(['cart_data' => 'yes'], $sessionData, 'Session data read');
assertSame('session_prefix_cust123', $GLOBALS['cacheCalls']['get'][0][0], 'Key format matching');

// Test save_data
$dataProp = $ref->getProperty('_data');
$dataProp->setAccessible(true);
$dataProp->setValue($handler, ['cart_data' => 'updated']);
$dirtyProp = $ref->getProperty('_dirty');
$dirtyProp->setAccessible(true);
$dirtyProp->setValue($handler, true);
$cookieProp = $ref->getProperty('_has_cookie');
$cookieProp->setAccessible(true);
$cookieProp->setValue($handler, true);
$customerProp = $ref->getProperty('_customer_id');
$customerProp->setAccessible(true);
$customerProp->setValue($handler, 'cust123');

$handler->save_data();
assertSame('session_prefix_cust123', $GLOBALS['cacheCalls']['set'][0][0], 'Save data key');
assertSame(['cart_data' => 'updated'], $GLOBALS['cacheCalls']['set'][0][1], 'Save data value');

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
