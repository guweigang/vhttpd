<?php

namespace CodexBot\Repository;

use CodexBot\Db;

class CommandContextRepository {
    private $db;

    public function __construct() {
        $this->db = Db::getConnection();
    }

    public function setSelectionScope(string $platform, string $channelId, ?string $selectionScope): void {
        $now = date('Y-m-d H:i:s');
        $stmt = $this->db->prepare(
            "INSERT INTO command_contexts (platform, channel_id, selection_scope, created_at, updated_at)
             VALUES (:platform, :channel_id, :selection_scope, :created_at, :updated_at)
             ON CONFLICT(platform, channel_id) DO UPDATE SET
               selection_scope = excluded.selection_scope,
               updated_at = excluded.updated_at"
        );
        $stmt->execute([
            ':platform' => $platform,
            ':channel_id' => $channelId,
            ':selection_scope' => $selectionScope,
            ':created_at' => $now,
            ':updated_at' => $now,
        ]);
    }

    public function findSelectionScope(string $platform, string $channelId): ?string {
        $stmt = $this->db->prepare(
            "SELECT selection_scope
             FROM command_contexts
             WHERE platform = ? AND channel_id = ?
             LIMIT 1"
        );
        $stmt->execute([$platform, $channelId]);
        $row = $stmt->fetch();
        $scope = trim((string) ($row['selection_scope'] ?? ''));
        return $scope !== '' ? $scope : null;
    }

    public function clearSelectionScope(string $platform, string $channelId): void {
        $stmt = $this->db->prepare(
            "DELETE FROM command_contexts
             WHERE platform = ? AND channel_id = ?"
        );
        $stmt->execute([$platform, $channelId]);
    }
}
