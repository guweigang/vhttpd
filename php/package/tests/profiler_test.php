<?php

declare(strict_types=1);

require_once __DIR__ . '/../vendor/autoload.php';

// Mock WordPress functions so the test can run in CLI
if (!defined('ABSPATH')) {
    define('ABSPATH', __DIR__ . '/');
}

// Mock actions and filters
$GLOBALS['actions'] = [];
function add_action(string $tag, callable $function_to_add, int $priority = 10, int $accepted_args = 1): bool {
    $GLOBALS['actions'][$tag][] = $function_to_add;
    return true;
}
function remove_action(string $tag, callable $function_to_remove, int $priority = 10): bool {
    unset($GLOBALS['actions'][$tag]);
    return true;
}
function add_filter(string $tag, callable $function_to_add, int $priority = 10, int $accepted_args = 1): bool {
    return true;
}

// Mock wpdb queries
class MockWpdb {
    public array $queries = [];
}
$GLOBALS['wpdb'] = new MockWpdb();

// Mock Object Cache
class MockObjectCache {
    public int $local_hits = 5;
    public int $remote_hits = 12;
    public int $cache_misses = 2;
}
$GLOBALS['wp_object_cache'] = new MockObjectCache();
$GLOBALS['wp_version'] = '6.4.2';

// 1. Load the bootstrap file
require_once __DIR__ . '/../wordpress/v-profiler.php';

use VHttpd\WordPress\Profiler;

// 2. Activate the profiler
Profiler::activate();

// Mock queries after activation so they won't be cleared by reset
$GLOBALS['wpdb']->queries = [
    ['SELECT * FROM wp_posts WHERE ID = 1', 0.012, 'get_post', 1600000000.123],
    ['UPDATE wp_options SET option_value = "yes" WHERE option_name = "active"', 0.065, 'update_option', 1600000000.145]
];

// Test that helpers exist and don't throw
v_log('Hello simple message');
v_debug(['user_id' => 42, 'role' => 'admin'], 'User Details');

// 3. Trigger some notices
trigger_error('This is a test notice', E_USER_NOTICE);

// 4. Test error suppression with @
@unserialize('invalid serialized data'); // This should be ignored due to error suppression

// 5. Build report using reflection to call the private buildReport method
$ref = new ReflectionClass(Profiler::class);
$method = $ref->getMethod('buildReport');
$report = $method->invoke(null);

// Validate sections
assertArrayHasKey('request_id', $report);
assertArrayHasKey('trace_id', $report);
assertArrayHasKey('overview', $report);
assertArrayHasKey('queries', $report);
assertArrayHasKey('cache', $report);
assertArrayHasKey('logs', $report);
assertArrayHasKey('errors', $report);
assertArrayHasKey('env', $report);
assertArrayHasKey('vhttpd', $report);

// Verify SQL queries count and slow queries
assertSame(2, count($report['queries']), 'Queries count');
assertSame(1, $report['overview']['slow_queries_count'], 'Slow queries count');
assertSame('SELECT * FROM wp_posts WHERE ID = 1', $report['queries'][0]['sql'], 'Query 1 SQL');
assertSame(12.0, $report['queries'][0]['duration_ms'], 'Query 1 duration ms');
assertSame(65.0, $report['queries'][1]['duration_ms'], 'Query 2 duration ms');
assertSame(true, $report['queries'][1]['slow'], 'Query 2 is slow');

// Verify Cache stats
assertSame(5, $report['cache']['local_hits'], 'Local hits');
assertSame(12, $report['cache']['remote_hits'], 'Remote hits');
assertSame(2, $report['cache']['misses'], 'Misses');
assertSame(17, $report['cache']['local_hits'] + $report['cache']['remote_hits'], 'Total hits');

// Verify Logs
assertSame(2, count($report['logs']), 'Logs count');
assertSame('User Details', $report['logs'][1]['label'], 'Log 2 label');
assertSame('info', $report['logs'][0]['level'], 'Log 1 level');

// Verify Errors (Only E_USER_NOTICE should exist. The @unserialize should be ignored.)
if (count($report['errors']) !== 1) {
    fwrite(STDERR, "Errors count failed: expected exactly 1 (test notice), actual: " . count($report['errors']) . "\n");
    print_r($report['errors']);
    exit(1);
}
assertSame('Notice', $report['errors'][0]['level'], 'Error 1 level');
assertSame('This is a test notice', $report['errors'][0]['message'], 'Error 1 message');

// 6. Test state reset
putenv('VHTTPD_REQUEST_ID=new_request_123');
Profiler::start();

// Re-fetch report
$report2 = $method->invoke(null);

// Verify reset
assertSame(0, count($report2['logs']), 'Logs should be reset');
assertSame(0, count($report2['errors']), 'Errors should be reset');
assertSame(0, count($GLOBALS['wpdb']->queries), 'Queries in wpdb should be reset');

// Deactivate and restore handlers
Profiler::stopAndDeactivate();

echo "Profiler unit test completed successfully!\n";

function assertArrayHasKey(string $key, array $arr): void {
    if (!array_key_exists($key, $arr)) {
        fwrite(STDERR, "Assertion failed: Key '{$key}' not found in array.\n");
        exit(1);
    }
}

function assertSame(mixed $expected, mixed $actual, string $label): void {
    if ($expected !== $actual) {
        fwrite(STDERR, $label . " failed\nexpected: " . var_export($expected, true) . "\nactual: " . var_export($actual, true) . "\n");
        exit(1);
    }
}
