<?php

namespace CodexBot\Repository;

use CodexBot\Db;

class SettingsRepository {
    private $db;

    public function __construct() {
        $this->db = Db::getConnection();
    }

    public function upsert(string $name, string $value): void {
        $now = date('Y-m-d H:i:s');
        $stmt = $this->db->prepare(
            "INSERT INTO settings (name, value, created_at, updated_at)
             VALUES (:name, :value, :created_at, :updated_at)
             ON CONFLICT(name) DO UPDATE SET
               value = excluded.value,
               updated_at = excluded.updated_at"
        );
        $stmt->execute([
            ':name' => $name,
            ':value' => $value,
            ':created_at' => $now,
            ':updated_at' => $now,
        ]);
    }

    public function findValue(string $name): ?string {
        $stmt = $this->db->prepare(
            "SELECT value
             FROM settings
             WHERE name = ?
             LIMIT 1"
        );
        $stmt->execute([$name]);
        $row = $stmt->fetch();
        if (!$row) {
            return null;
        }

        return (string) ($row['value'] ?? '');
    }

    public function findAll(): array {
        $stmt = $this->db->query(
            "SELECT name, value
             FROM settings
             ORDER BY name ASC"
        );
        $rows = $stmt->fetchAll();
        return is_array($rows) ? $rows : [];
    }
}
