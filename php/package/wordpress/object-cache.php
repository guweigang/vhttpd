<?php

declare(strict_types=1);

use VHttpd\Cache\Client;
use VHttpd\WordPress\ObjectCache;

$vhttpdPackageRoot = dirname(__DIR__);

if (!class_exists(ObjectCache::class)) {
    $autoload = getenv('VHTTPD_PHP_PACKAGE_AUTOLOAD');
    if ((!is_string($autoload) || $autoload === '') && defined('VHTTPD_PHP_PACKAGE_AUTOLOAD')) {
        $autoload = (string) VHTTPD_PHP_PACKAGE_AUTOLOAD;
    }
    if (is_string($autoload) && $autoload !== '' && is_file($autoload)) {
        require_once $autoload;
    } elseif (is_file($vhttpdPackageRoot . '/vendor/autoload.php')) {
        require_once $vhttpdPackageRoot . '/vendor/autoload.php';
    }
}

if (!class_exists(ObjectCache::class)) {
    spl_autoload_register(static function (string $class) use ($vhttpdPackageRoot): void {
        $prefix = 'VHttpd\\';
        if (!str_starts_with($class, $prefix)) {
            return;
        }

        $relative = str_replace('\\', '/', substr($class, strlen($prefix)));
        $file = $vhttpdPackageRoot . '/src/VHttpd/' . $relative . '.php';
        if (is_file($file)) {
            require_once $file;
        }
    });
}

if (!function_exists('wp_cache_init')) {
    function wp_cache_init(): void
    {
        $client = null;
        $socket = getenv('VHTTPD_CACHE_SOCKET');
        if (!is_string($socket) || $socket === '') {
            $socket = $_SERVER['VHTTPD_CACHE_SOCKET'] ?? '';
        }

        if (class_exists(Client::class) && $socket !== '') {
            $client = Client::fromEnv(defaultNamespace: 'wordpress');
        }

        $GLOBALS['wp_object_cache'] = new ObjectCache($client);
    }
}

if (!function_exists('wp_cache_add')) {
    function wp_cache_add($key, $data, $group = '', $expire = 0): bool
    {
        global $wp_object_cache;
        return $wp_object_cache->add($key, $data, $group, (int) $expire);
    }
}

if (!function_exists('wp_cache_add_multiple')) {
    function wp_cache_add_multiple(array $data, $group = '', $expire = 0): array
    {
        global $wp_object_cache;
        return $wp_object_cache->add_multiple($data, $group, (int) $expire);
    }
}

if (!function_exists('wp_cache_replace')) {
    function wp_cache_replace($key, $data, $group = '', $expire = 0): bool
    {
        global $wp_object_cache;
        return $wp_object_cache->replace($key, $data, $group, (int) $expire);
    }
}

if (!function_exists('wp_cache_set')) {
    function wp_cache_set($key, $data, $group = '', $expire = 0): bool
    {
        global $wp_object_cache;
        return $wp_object_cache->set($key, $data, $group, (int) $expire);
    }
}

if (!function_exists('wp_cache_set_multiple')) {
    function wp_cache_set_multiple(array $data, $group = '', $expire = 0): array
    {
        global $wp_object_cache;
        return $wp_object_cache->set_multiple($data, $group, (int) $expire);
    }
}

if (!function_exists('wp_cache_get')) {
    function wp_cache_get($key, $group = '', $force = false, &$found = null): mixed
    {
        global $wp_object_cache;
        return $wp_object_cache->get($key, $group, (bool) $force, $found);
    }
}

if (!function_exists('wp_cache_get_multiple')) {
    function wp_cache_get_multiple($keys, $group = '', $force = false): array
    {
        global $wp_object_cache;
        return $wp_object_cache->get_multiple($keys, $group, (bool) $force);
    }
}

if (!function_exists('wp_cache_delete')) {
    function wp_cache_delete($key, $group = ''): bool
    {
        global $wp_object_cache;
        return $wp_object_cache->delete($key, $group);
    }
}

if (!function_exists('wp_cache_delete_multiple')) {
    function wp_cache_delete_multiple(array $keys, $group = ''): array
    {
        global $wp_object_cache;
        return $wp_object_cache->delete_multiple($keys, $group);
    }
}

if (!function_exists('wp_cache_incr')) {
    function wp_cache_incr($key, $offset = 1, $group = ''): int|false
    {
        global $wp_object_cache;
        return $wp_object_cache->incr($key, (int) $offset, $group);
    }
}

if (!function_exists('wp_cache_decr')) {
    function wp_cache_decr($key, $offset = 1, $group = ''): int|false
    {
        global $wp_object_cache;
        return $wp_object_cache->decr($key, (int) $offset, $group);
    }
}

if (!function_exists('wp_cache_flush')) {
    function wp_cache_flush(): bool
    {
        global $wp_object_cache;
        return $wp_object_cache->flush();
    }
}

if (!function_exists('wp_cache_flush_runtime')) {
    function wp_cache_flush_runtime(): bool
    {
        return wp_cache_flush();
    }
}

if (!function_exists('wp_cache_flush_group')) {
    function wp_cache_flush_group($group): bool
    {
        global $wp_object_cache;
        return $wp_object_cache->flush_group($group);
    }
}

if (!function_exists('wp_cache_supports')) {
    function wp_cache_supports($feature): bool
    {
        return in_array($feature, [
            'add_multiple',
            'set_multiple',
            'get_multiple',
            'delete_multiple',
            'flush_runtime',
            'flush_group',
        ], true);
    }
}

if (!function_exists('wp_cache_close')) {
    function wp_cache_close(): bool
    {
        return true;
    }
}

if (!function_exists('wp_cache_add_global_groups')) {
    function wp_cache_add_global_groups($groups): void
    {
        global $wp_object_cache;
        $wp_object_cache->add_global_groups($groups);
    }
}

if (!function_exists('wp_cache_add_non_persistent_groups')) {
    function wp_cache_add_non_persistent_groups($groups): void
    {
        global $wp_object_cache;
        $wp_object_cache->add_non_persistent_groups($groups);
    }
}

if (!function_exists('wp_cache_switch_to_blog')) {
    function wp_cache_switch_to_blog($blog_id): void
    {
        global $wp_object_cache;
        $wp_object_cache->switch_to_blog($blog_id);
    }
}

if (!function_exists('wp_cache_reset')) {
    function wp_cache_reset(): void
    {
        global $wp_object_cache;
        $wp_object_cache->reset();
    }
}
