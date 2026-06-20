<?php

declare(strict_types=1);

namespace Automattic\WooCommerce\Internal\DataStores\Orders {
    class CustomOrdersTableController {
        public static function is_active_and_enabled(): bool {
            return true;
        }
    }
}

namespace {

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

// Mock WooCommerce and its helpers
if (!defined('COOKIEHASH')) {
    define('COOKIEHASH', 'mock_hash');
}
if (!defined('WC_TEMPLATE_DEBUG')) {
    define('WC_TEMPLATE_DEBUG', true);
}

if (!function_exists('get_option')) {
    function get_option(string $option, mixed $default = false): mixed {
        if ($option === 'woocommerce_calc_taxes') {
            return 'yes';
        }
        if ($option === 'woocommerce_calc_shipping') {
            return 'yes';
        }
        return $default;
    }
}

class WC_Cart {
    public function get_cart_contents_count() { return 3; }
    public function get_cart_subtotal() { return '$99.00'; }
    public function get_cart_total() { return '$109.00'; }
    public function needs_shipping() { return true; }
}

class WC_Session {
    public function get_customer_id() { return 'session_12345'; }
    public function get_session_expiration() { return 1700000000; }
}

class WooCommerce {
    public string $version = '8.5.0';
    public $cart;
    public $session;
    public function __construct() {
        $this->cart = new WC_Cart();
        $this->session = new WC_Session();
    }
}

if (!function_exists('WC')) {
    function WC() {
        static $wc = null;
        if ($wc === null) {
            $wc = new WooCommerce();
        }
        return $wc;
    }
}

if (!function_exists('is_woocommerce')) {
    function is_woocommerce() { return true; }
}
if (!function_exists('is_cart')) {
    function is_cart() { return false; }
}
if (!function_exists('is_checkout')) {
    function is_checkout() { return false; }
}
if (!function_exists('is_account_page')) {
    function is_account_page() { return false; }
}
if (!function_exists('is_wc_endpoint_url')) {
    function is_wc_endpoint_url() { return false; }
}

// 1. Load the bootstrap file
require_once __DIR__ . '/../wordpress/v-profiler.php';

use VHttpd\WordPress\Profiler;

// 2. Activate the profiler
Profiler::activate();

// Mock queries after activation so they won't be cleared by reset
$GLOBALS['wpdb']->queries = [
    ['SELECT * FROM wp_posts WHERE ID = 1', 0.012, 'get_post', 1600000000.123],
    ['UPDATE wp_options SET option_value = "yes" WHERE option_name = "active"', 0.065, 'update_option', 1600000000.145],
    ['SELECT * FROM wp_woocommerce_sessions WHERE session_key = "abc"', 0.005, 'WC_Session_Handler->get_session', 1600000000.150]
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
assertArrayHasKey('woocommerce', $report);

// Verify SQL queries count and slow queries
assertSame(3, count($report['queries']), 'Queries count');
assertSame(1, $report['overview']['slow_queries_count'], 'Slow queries count');
assertSame('SELECT * FROM wp_posts WHERE ID = 1', $report['queries'][0]['sql'], 'Query 1 SQL');
assertSame(12.0, $report['queries'][0]['duration_ms'], 'Query 1 duration ms');
assertSame(65.0, $report['queries'][1]['duration_ms'], 'Query 2 duration ms');
assertSame(true, $report['queries'][1]['slow'], 'Query 2 is slow');

// Verify WooCommerce Telemetry Data
$wc = $report['woocommerce'];
assertSame(true, $wc['is_wc_page'], 'is_wc_page');
assertSame('8.5.0', $wc['version'], 'woocommerce version');
assertSame(3, $wc['cart']['contents_count'], 'cart contents count');
assertSame('$99.00', $wc['cart']['subtotal'], 'cart subtotal');
assertSame('$109.00', $wc['cart']['total'], 'cart total');
assertSame(true, $wc['cart']['needs_shipping'], 'cart needs_shipping');
assertSame('session_12345', $wc['session']['customer_id'], 'session customer_id');
assertSame(1700000000, $wc['session']['session_expiration'], 'session expiration');
assertSame('HPOS Enabled (High-Performance)', $wc['hpos_enabled'], 'hpos_enabled status');
assertSame(true, $wc['settings']['calc_taxes'], 'calc_taxes setting');
assertSame(true, $wc['settings']['calc_shipping'], 'calc_shipping setting');
assertSame(true, $wc['settings']['template_debug'], 'template_debug setting');
assertSame(1, $wc['sql_count'], 'WooCommerce SQL count');
assertSame(5.0, $wc['sql_duration_ms'], 'WooCommerce SQL duration ms');
assertSame('SELECT * FROM wp_woocommerce_sessions WHERE session_key = "abc"', $wc['queries'][0]['sql'], 'WooCommerce SQL query');

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

}

