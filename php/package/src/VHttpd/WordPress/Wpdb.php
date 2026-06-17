<?php

declare(strict_types=1);

namespace VHttpd\WordPress;

use RuntimeException;
use VHttpd\DbGateway\Client;

/**
 * WordPress wpdb drop-in backed by the vhttpd DB runtime.
 *
 * This class intentionally replaces the wpdb connection/query layer only. It
 * does not shim direct mysqli_* calls made by plugins.
 */
class Wpdb extends \wpdb
{
    private ?Client $client = null;
    private string $activeSessionId = '';
    private string $serverInfo = '8.0.0-vhttpd';

    public function __construct(
        string $dbuser,
        #[\SensitiveParameter]
        string $dbpassword,
        string $dbname,
        string $dbhost,
        private readonly string $socketPath,
        private readonly string $pool = 'default',
        private readonly int $timeoutMs = 1000,
    ) {
        if (defined('WP_DEBUG') && defined('WP_DEBUG_DISPLAY') && WP_DEBUG && WP_DEBUG_DISPLAY) {
            $this->show_errors();
        }

        $this->dbuser = $dbuser;
        $this->dbpassword = $dbpassword;
        $this->dbname = $dbname;
        $this->dbhost = $dbhost;
        $this->is_mysql = true;

        if (defined('WP_SETUP_CONFIG')) {
            return;
        }

        $this->db_connect();
    }

    public function db_connect($allow_bail = true)
    {
        try {
            $this->client()->ping($this->timeoutMs);
            $this->init_charset();
            $this->ready = true;
            return true;
        } catch (\Throwable $e) {
            $this->ready = false;
            $this->last_error = $e->getMessage();
            if ($allow_bail) {
                $this->bailConnectionError($e);
            }
            return false;
        }
    }

    public function check_connection($allow_bail = true)
    {
        try {
            $this->client()->ping($this->timeoutMs);
            $this->ready = true;
            return true;
        } catch (\Throwable) {
            return $this->db_connect($allow_bail);
        }
    }

    public function select($db, $dbh = null)
    {
        $this->dbname = (string) $db;
        return true;
    }

    public function set_charset($dbh, $charset = null, $collate = null)
    {
        $this->charset = $charset ?? $this->charset;
        $this->collate = $collate ?? $this->collate;
    }

    public function query($query)
    {
        if (!$this->ready) {
            return false;
        }

        if (function_exists('apply_filters')) {
            $query = apply_filters('query', $query);
        }
        if (!$query) {
            $this->insert_id = 0;
            return false;
        }

        $this->flush();
        $this->func_call = "\$db->query(\"$query\")";
        $this->last_query = (string) $query;

        if (defined('SAVEQUERIES') && SAVEQUERIES) {
            $this->timer_start();
        }

        try {
            $returnValue = $this->dispatchQuery((string) $query);
            ++$this->num_queries;
            $this->logSavedQuery((string) $query);
            return $returnValue;
        } catch (\Throwable $e) {
            $this->last_error = $e->getMessage();
            $this->insert_id = 0;
            $this->logSavedQuery((string) $query);
            $this->print_error();
            return false;
        }
    }

    public function print_error($str = '')
    {
        if ($str === '') {
            $str = $this->last_error ?: 'vhttpd DB gateway query failed';
        }

        return parent::print_error($str);
    }

    public function _real_escape($data)
    {
        if (!is_scalar($data)) {
            return '';
        }

        $value = (string) $data;
        try {
            $escaped = $this->client()->escape($value, $this->activeSessionId, $this->timeoutMs);
        } catch (\Throwable) {
            $escaped = addslashes($value);
        }

        return $this->add_placeholder_escape($escaped);
    }

    public function has_cap($db_cap)
    {
        return match (strtolower((string) $db_cap)) {
            'collation',
            'group_concat',
            'subqueries',
            'set_charset',
            'utf8mb4',
            'utf8mb4_520',
            'identifier_placeholders' => true,
            default => false,
        };
    }

    public function db_server_info()
    {
        return $this->serverInfo;
    }

    public function db_version()
    {
        return preg_replace('/[^0-9.].*/', '', $this->serverInfo);
    }

    /** @return int|bool */
    private function dispatchQuery(string $query)
    {
        $tx = $this->transactionOp($query);
        if ($tx !== null) {
            return $this->dispatchTransactionOp($tx);
        }

        if ($this->isReadQuery($query)) {
            $response = $this->client()->query($query, [], $this->activeSessionId, $this->timeoutMs);
            $this->last_result = $this->rowsToObjects($response['rows'] ?? []);
            $this->col_info = $this->fieldInfo($response, $this->last_result);
            $this->num_rows = count($this->last_result);
            $this->rows_affected = (int) ($response['affected_rows'] ?? 0);
            $this->insert_id = 0;
            return $this->num_rows;
        }

        $response = $this->client()->execute($query, [], $this->activeSessionId, $this->timeoutMs);
        $this->rows_affected = (int) ($response['affected_rows'] ?? 0);
        $this->insert_id = (int) ($response['last_insert_id'] ?? 0);

        if (preg_match('/^\s*(create|alter|truncate|drop)\s/i', $query)) {
            return true;
        }

        return $this->rows_affected;
    }

    private function dispatchTransactionOp(string $op): bool
    {
        if ($op === 'begin') {
            if ($this->activeSessionId === '') {
                $this->activeSessionId = $this->client()->beginTransaction($this->timeoutMs);
            }
            return true;
        }

        if ($op === 'commit') {
            if ($this->activeSessionId !== '') {
                $this->client()->commit($this->activeSessionId, $this->timeoutMs);
                $this->activeSessionId = '';
            }
            return true;
        }

        if ($op === 'rollback') {
            if ($this->activeSessionId !== '') {
                $this->client()->rollback($this->activeSessionId, $this->timeoutMs);
                $this->activeSessionId = '';
            }
            return true;
        }

        return false;
    }

    private function transactionOp(string $query): ?string
    {
        $normalized = strtoupper(trim(rtrim($query, " \t\r\n;")));
        return match ($normalized) {
            'BEGIN',
            'START TRANSACTION' => 'begin',
            'COMMIT' => 'commit',
            'ROLLBACK' => 'rollback',
            default => null,
        };
    }

    private function isReadQuery(string $query): bool
    {
        $prefix = strtoupper(strtok(ltrim($query), " \t\r\n(") ?: '');
        return in_array($prefix, ['SELECT', 'SHOW', 'DESCRIBE', 'DESC', 'EXPLAIN', 'WITH'], true);
    }

    /** @param mixed $rows
     *  @return list<object>
     */
    private function rowsToObjects(mixed $rows): array
    {
        if (!is_array($rows)) {
            return [];
        }

        $out = [];
        foreach ($rows as $row) {
            if (!is_array($row)) {
                continue;
            }
            $obj = new \stdClass();
            foreach ($row as $key => $value) {
                $obj->{(string) $key} = $value;
            }
            $out[] = $obj;
        }

        return $out;
    }

    /** @param array<string,mixed> $response
     *  @param list<object> $rows
     *  @return list<object>
     */
    private function fieldInfo(array $response, array $rows): array
    {
        $fields = $response['fields'] ?? $response['columns'] ?? [];
        if (!is_array($fields) || $fields === []) {
            $first = $rows[0] ?? null;
            $fields = $first ? array_keys(get_object_vars($first)) : [];
        }

        $out = [];
        foreach ($fields as $field) {
            if (is_array($field)) {
                $name = (string) ($field['name'] ?? $field['orgname'] ?? '');
                $table = (string) ($field['table'] ?? $field['orgtable'] ?? '');
                $type = (string) ($field['type'] ?? '');
            } else {
                $name = (string) $field;
                $table = '';
                $type = '';
            }
            if ($name === '') {
                continue;
            }
            $meta = new \stdClass();
            $meta->name = $name;
            $meta->orgname = $name;
            $meta->table = $table;
            $meta->orgtable = $table;
            $meta->type = $type;
            $meta->max_length = 0;
            $out[] = $meta;
        }

        return $out;
    }

    private function logSavedQuery(string $query): void
    {
        if (!defined('SAVEQUERIES') || !SAVEQUERIES) {
            return;
        }

        $this->log_query(
            $query,
            $this->timer_stop(),
            $this->get_caller(),
            $this->time_start,
            ['transport' => 'vhttpd_db']
        );
    }

    private function client(): Client
    {
        if ($this->client === null) {
            $this->client = new Client($this->socketPath, $this->pool);
        }

        return $this->client;
    }

    private function bailConnectionError(\Throwable $e): void
    {
        if (function_exists('wp_load_translations_early')) {
            wp_load_translations_early();
        }

        if (function_exists('__')) {
            $title = __('Error establishing a database connection');
        } else {
            $title = 'Error establishing a database connection';
        }

        $message = '<h1>' . $title . "</h1>\n";
        $message .= '<p>vhttpd DB gateway connection failed: <code>' . htmlspecialchars($e->getMessage(), ENT_QUOTES) . '</code></p>';
        $this->bail($message, 'db_connect_fail');
    }
}
