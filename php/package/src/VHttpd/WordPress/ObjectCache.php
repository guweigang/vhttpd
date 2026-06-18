<?php

declare(strict_types=1);

namespace VHttpd\WordPress;

use VHttpd\Cache\Client;

final class ObjectCache
{
    /** @var array<string,array<string,mixed>> */
    private array $cache = [];

    /** @var array<string,bool> */
    private array $globalGroups = [];

    /** @var array<string,bool> */
    private array $nonPersistentGroups = [];

    public int $cache_hits = 0;
    public int $cache_misses = 0;

    private string $blogPrefix = '';
    private bool $multisite = false;

    public function __construct(private readonly ?Client $client = null)
    {
        $this->multisite = function_exists('is_multisite') && is_multisite();
        if ($this->multisite && function_exists('get_current_blog_id')) {
            $this->blogPrefix = (string) get_current_blog_id() . ':';
        }
    }

    public function add($key, $data, $group = 'default', $expire = 0): bool
    {
        if (function_exists('wp_suspend_cache_addition') && wp_suspend_cache_addition()) {
            return false;
        }
        if (!$this->isValidKey($key)) {
            return false;
        }

        [$group, $id] = $this->normalizeKey($key, $group);
        if ($this->existsLocal($id, $group)) {
            return false;
        }
        if ($this->isPersistent($group) && $this->remoteExists($group, $id)) {
            return false;
        }

        return $this->set($key, $data, $group, (int) $expire);
    }

    /** @param array<int|string,mixed> $data
     *  @return array<int|string,bool>
     */
    public function add_multiple(array $data, $group = '', $expire = 0): array
    {
        $values = [];
        foreach ($data as $key => $value) {
            $values[$key] = $this->add($key, $value, $group, $expire);
        }
        return $values;
    }

    public function replace($key, $data, $group = 'default', $expire = 0): bool
    {
        if (!$this->isValidKey($key)) {
            return false;
        }

        [$group, $id] = $this->normalizeKey($key, $group);
        if (!$this->existsLocal($id, $group) && (!$this->isPersistent($group) || !$this->remoteExists($group, $id))) {
            return false;
        }

        return $this->set($key, $data, $group, (int) $expire);
    }

    public function set($key, $data, $group = 'default', $expire = 0): bool
    {
        if (!$this->isValidKey($key)) {
            return false;
        }

        [$group, $id] = $this->normalizeKey($key, $group);
        $value = is_object($data) ? clone $data : $data;
        $this->cache[$group][$id] = $value;

        if ($this->isPersistent($group)) {
            $this->remoteSet($group, $id, $value, (int) $expire);
        }

        return true;
    }

    /** @param array<int|string,mixed> $data
     *  @return array<int|string,bool>
     */
    public function set_multiple(array $data, $group = '', $expire = 0): array
    {
        $values = [];
        foreach ($data as $key => $value) {
            $values[$key] = $this->set($key, $value, $group, $expire);
        }
        return $values;
    }

    public function get($key, $group = 'default', $force = false, &$found = null): mixed
    {
        if (!$this->isValidKey($key)) {
            $found = false;
            return false;
        }

        [$group, $id] = $this->normalizeKey($key, $group);
        if (!$force && $this->existsLocal($id, $group)) {
            $found = true;
            ++$this->cache_hits;
            return $this->cloneIfObject($this->cache[$group][$id]);
        }

        if ($this->isPersistent($group)) {
            $remote = $this->remoteGet($group, $id);
            if ($remote['found']) {
                $this->cache[$group][$id] = $remote['value'];
                $found = true;
                ++$this->cache_hits;
                return $this->cloneIfObject($remote['value']);
            }
        }

        $found = false;
        ++$this->cache_misses;
        return false;
    }

    /** @param array<int|string> $keys
     *  @return array<int|string,mixed>
     */
    public function get_multiple($keys, $group = 'default', $force = false): array
    {
        $values = [];
        foreach ($keys as $key) {
            $values[$key] = $this->get($key, $group, $force);
        }
        return $values;
    }

    public function delete($key, $group = 'default', $deprecated = false): bool
    {
        if (!$this->isValidKey($key)) {
            return false;
        }

        [$group, $id] = $this->normalizeKey($key, $group);
        $existed = $this->existsLocal($id, $group);
        unset($this->cache[$group][$id]);

        if ($this->isPersistent($group)) {
            $remoteDeleted = $this->remoteDelete($group, $id);
            return $existed || $remoteDeleted;
        }

        return $existed;
    }

    /** @param array<int|string> $keys
     *  @return array<int|string,bool>
     */
    public function delete_multiple(array $keys, $group = ''): array
    {
        $values = [];
        foreach ($keys as $key) {
            $values[$key] = $this->delete($key, $group);
        }
        return $values;
    }

    public function incr($key, $offset = 1, $group = 'default'): int|false
    {
        return $this->changeNumeric($key, (int) $offset, $group);
    }

    public function decr($key, $offset = 1, $group = 'default'): int|false
    {
        return $this->changeNumeric($key, -1 * (int) $offset, $group);
    }

    public function flush(): bool
    {
        $this->cache = [];
        if ($this->client === null) {
            return true;
        }

        try {
            foreach ($this->client->keys() as $key) {
                $this->client->delete($key);
            }
        } catch (\Throwable) {
            return true;
        }

        return true;
    }

    public function flush_group($group): bool
    {
        $group = $this->normalizeGroup($group);
        unset($this->cache[$group]);

        if ($this->client === null || !$this->isPersistent($group)) {
            return true;
        }

        $prefix = $group . ':';
        try {
            foreach ($this->client->keys() as $key) {
                if (str_starts_with($key, $prefix)) {
                    $this->client->delete($key);
                }
            }
        } catch (\Throwable) {
            return true;
        }

        return true;
    }

    public function add_global_groups($groups): void
    {
        foreach ((array) $groups as $group) {
            $group = $this->normalizeGroup($group);
            if ($group !== '') {
                $this->globalGroups[$group] = true;
            }
        }
    }

    public function add_non_persistent_groups($groups): void
    {
        foreach ((array) $groups as $group) {
            $group = $this->normalizeGroup($group);
            if ($group !== '') {
                $this->nonPersistentGroups[$group] = true;
            }
        }
    }

    public function switch_to_blog($blog_id): void
    {
        $this->blogPrefix = $this->multisite ? (int) $blog_id . ':' : '';
    }

    public function reset(): void
    {
        foreach (array_keys($this->cache) as $group) {
            if (!isset($this->globalGroups[$group])) {
                unset($this->cache[$group]);
            }
        }
    }

    public function clearLocalCache(): void
    {
        $this->cache = [];
        $this->cache_hits = 0;
        $this->cache_misses = 0;
    }

    private function changeNumeric($key, int $offset, string $group): int|false
    {
        $found = false;
        $value = $this->get($key, $group, false, $found);
        if (!$found) {
            return false;
        }

        $next = is_numeric($value) ? (int) $value : 0;
        $next += $offset;
        if ($next < 0) {
            $next = 0;
        }

        $this->set($key, $next, $group);
        return $next;
    }

    private function isValidKey($key): bool
    {
        return is_int($key) || (is_string($key) && trim($key) !== '');
    }

    /** @return array{0:string,1:string} */
    private function normalizeKey(int|string $key, $group): array
    {
        $id = (string) $key;
        $group = (string) $group;

        $group = $this->normalizeGroup($group);
        if ($this->multisite && !isset($this->globalGroups[$group])) {
            $id = $this->blogPrefix . $id;
        }

        return [$group, $id];
    }

    private function normalizeGroup(string $group): string
    {
        $group = trim($group);
        return $group === '' || is_numeric($group) ? 'default' : $group;
    }

    private function existsLocal(string $id, string $group): bool
    {
        return isset($this->cache[$group])
            && (isset($this->cache[$group][$id]) || array_key_exists($id, $this->cache[$group]));
    }

    private function isPersistent(string $group): bool
    {
        return $this->client !== null && !isset($this->nonPersistentGroups[$group]);
    }

    private function remoteKey(string $group, string $id): string
    {
        return $group . ':' . $id;
    }

    private function remoteExists(string $group, string $id): bool
    {
        try {
            return $this->client?->exists($this->remoteKey($group, $id)) ?? false;
        } catch (\Throwable) {
            return false;
        }
    }

    /** @return array{found:bool,value:mixed} */
    private function remoteGet(string $group, string $id): array
    {
        try {
            $raw = $this->client?->get($this->remoteKey($group, $id));
            if ($raw === null) {
                return ['found' => false, 'value' => null];
            }
            $value = @unserialize($raw);
            if ($value === false && $raw !== serialize(false)) {
                return ['found' => false, 'value' => null];
            }
            return ['found' => true, 'value' => $value];
        } catch (\Throwable) {
            return ['found' => false, 'value' => null];
        }
    }

    private function remoteSet(string $group, string $id, mixed $value, int $expire): bool
    {
        try {
            return $this->client?->set(
                $this->remoteKey($group, $id),
                serialize($value),
                max(0, $expire) * 1000,
            ) ?? false;
        } catch (\Throwable) {
            return false;
        }
    }

    private function remoteDelete(string $group, string $id): bool
    {
        try {
            return $this->client?->delete($this->remoteKey($group, $id)) ?? false;
        } catch (\Throwable) {
            return false;
        }
    }

    private function cloneIfObject(mixed $value): mixed
    {
        return is_object($value) ? clone $value : $value;
    }
}
