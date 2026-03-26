<?php

namespace CodexBot;

class Db {
    private static $pdo = null;

    public static function getConnection() {
        if (self::$pdo === null) {
            $dbPath = getenv('VHTTPD_BOT_DB_PATH') ?: (__DIR__ . '/../../codex.db');
            self::$pdo = new \PDO("sqlite:" . $dbPath);
            self::$pdo->setAttribute(\PDO::ATTR_ERRMODE, \PDO::ERRMODE_EXCEPTION);
            self::$pdo->setAttribute(\PDO::ATTR_DEFAULT_FETCH_MODE, \PDO::FETCH_ASSOC);
            self::initialize(self::$pdo);
        }
        return self::$pdo;
    }

    public static function resetConnectionForTests(): void {
        self::$pdo = null;
    }

    private static function initialize(\PDO $pdo): void {
        $pdo->exec("PRAGMA foreign_keys = ON;");

        $schemaPath = dirname(__DIR__) . '/codex.sql';
        if (!is_file($schemaPath)) {
            return;
        }

        $pdo->exec((string) file_get_contents($schemaPath));
        self::migrate($pdo);
    }

    private static function migrate(\PDO $pdo): void {
        self::ensureColumn(
            $pdo,
            'projects',
            'current_model',
            'ALTER TABLE projects ADD COLUMN current_model TEXT'
        );
    }

    private static function ensureColumn(\PDO $pdo, string $table, string $column, string $alterSql): void {
        $stmt = $pdo->query("PRAGMA table_info({$table})");
        $columns = $stmt ? $stmt->fetchAll(\PDO::FETCH_ASSOC) : [];
        foreach ($columns as $row) {
            if ((string) ($row['name'] ?? '') === $column) {
                return;
            }
        }

        $pdo->exec($alterSql);
    }
}
