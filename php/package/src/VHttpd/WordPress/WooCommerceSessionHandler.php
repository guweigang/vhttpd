<?php

declare(strict_types=1);

namespace VHttpd\WordPress;

use WC_Session_Handler;

defined('ABSPATH') || exit;

/**
 * Custom WooCommerce session handler that stores session data entirely in vhttpd cachex (Object Cache)
 * and bypasses any database reads or writes on the `woocommerce_sessions` table.
 */
class WooCommerceSessionHandler extends WC_Session_Handler
{
    /**
     * Retrieve the cache prefix, using WooCommerce Cache Helper if available.
     * Overrides/re-implements the private parent method.
     */
    private function get_cache_prefix(): string
    {
        if (class_exists('WC_Cache_Helper') && method_exists('WC_Cache_Helper', 'get_cache_prefix')) {
            return \WC_Cache_Helper::get_cache_prefix(WC_SESSION_CACHE_GROUP);
        }
        return 'session_prefix_';
    }

    /**
     * Get session data from cachex.
     *
     * @param string $customer_id Customer ID.
     * @param mixed  $default_value Default session value.
     * @return mixed Returns either the session data or the default value.
     */
    public function get_session($customer_id, $default_value = false)
    {
        if (defined('WP_SETUP_CONFIG')) {
            return $default_value;
        }

        // Directly query the object cache, which is backed by vhttpd cachex
        $value = wp_cache_get($this->get_cache_prefix() . $customer_id, WC_SESSION_CACHE_GROUP);

        if (false === $value) {
            $value = $default_value;

            $cache_duration = $this->_session_expiration - time();
            if (0 < $cache_duration && !empty($value)) {
                wp_cache_add($this->get_cache_prefix() . $customer_id, $value, WC_SESSION_CACHE_GROUP, $cache_duration);
            }
        }

        return maybe_unserialize($value);
    }

    /**
     * Save session data to cachex and delete guest session if migrating.
     * Bypasses the $wpdb insert query to woocommerce_sessions table.
     *
     * @param string|mixed $old_session_key Optional session ID prior to user log-in.
     */
    public function save_data($old_session_key = '')
    {
        if ($this->_dirty && $this->has_session()) {
            wp_cache_set(
                $this->get_cache_prefix() . $this->get_customer_id(),
                $this->_data,
                WC_SESSION_CACHE_GROUP,
                $this->_session_expiration - time()
            );
            $this->_dirty = false;

            if (!empty($old_session_key) && $this->get_customer_id() !== $old_session_key && !is_object(get_user_by('id', $old_session_key))) {
                $this->delete_session($old_session_key);
            }
        }
    }

    /**
     * Delete session data from cachex.
     * Bypasses the $wpdb delete query.
     *
     * @param string $customer_id Customer session ID.
     */
    public function delete_session($customer_id)
    {
        if (!$customer_id) {
            return;
        }
        wp_cache_delete($this->get_cache_prefix() . $customer_id, WC_SESSION_CACHE_GROUP);
    }

    /**
     * Update session expiry timestamp in memory/cachex.
     * Bypasses the $wpdb update query.
     *
     * @param string $customer_id Customer ID.
     * @param int    $timestamp Timestamp to expire the cookie.
     */
    public function update_session_timestamp($customer_id, $timestamp)
    {
        // No SQL update is required, cache entry TTL controls expiration automatically.
    }

    /**
     * Check if a session exists in cachex.
     * Bypasses the $wpdb get_var query.
     *
     * @param string $customer_id Customer ID.
     * @return bool
     */
    protected function session_exists($customer_id)
    {
        if (!$customer_id) {
            return false;
        }
        $value = wp_cache_get($this->get_cache_prefix() . $customer_id, WC_SESSION_CACHE_GROUP);
        return $value !== false;
    }
}
