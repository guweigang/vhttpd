<?php
/**
 * Plugin Name: vhttpd WooCommerce Session Integration
 * Description: Intercepts WooCommerce session class initialization and redirects to vhttpd cachex (Object Cache).
 * Author: Antigravity
 */

defined('ABSPATH') || exit;

// Register our custom session handler class into WooCommerce
add_filter('woocommerce_session_handler', static function (): string {
    return \VHttpd\WordPress\WooCommerceSessionHandler::class;
});
