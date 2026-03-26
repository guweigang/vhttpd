<?php

namespace CodexBot\Repository;

use CodexBot\Db;

class ProjectChannelRepository {
    private $db;

    public function __construct() {
        $this->db = Db::getConnection();
    }

    public function findProjectByTarget(string $platform, string $channelId, ?string $threadKey = null): ?array {
        $sql = "SELECT p.*, pc.thread_key as channel_thread_key 
                FROM projects p
                JOIN project_channels pc ON p.project_key = pc.project_key
                WHERE pc.platform = :platform 
                  AND pc.channel_id = :channel_id 
                  AND (pc.thread_key IS NULL OR pc.thread_key = :thread_key)
                  AND pc.is_active = 1
                  AND p.is_active = 1
                ORDER BY pc.thread_key DESC, pc.is_primary DESC 
                LIMIT 1";
        
        $stmt = $this->db->prepare($sql);
        $stmt->execute([
            ':platform' => $platform,
            ':channel_id' => $channelId,
            ':thread_key' => $threadKey
        ]);
        
        $res = $stmt->fetch();
        return $res ?: null;
    }

    public function findAll(int $limit = 20): array {
        $stmt = $this->db->prepare(
            "SELECT pc.*, p.name AS project_name
             FROM project_channels pc
             JOIN projects p ON p.project_key = pc.project_key
             ORDER BY pc.updated_at DESC, pc.id DESC
             LIMIT ?"
        );
        $stmt->bindValue(1, $limit, \PDO::PARAM_INT);
        $stmt->execute();
        $rows = $stmt->fetchAll();
        return is_array($rows) ? $rows : [];
    }

    public function listProjectsByTarget(string $platform, string $channelId, ?string $threadKey = null): array {
        $sql = "SELECT p.*, pc.thread_key as channel_thread_key, pc.is_primary, pc.is_active as channel_is_active
                FROM projects p
                JOIN project_channels pc ON p.project_key = pc.project_key
                WHERE pc.platform = :platform
                  AND pc.channel_id = :channel_id
                  AND (pc.thread_key IS NULL OR pc.thread_key = :thread_key)
                  AND pc.is_active = 1
                  AND p.is_active = 1
                ORDER BY pc.thread_key DESC, pc.is_primary DESC, p.project_key ASC";

        $stmt = $this->db->prepare($sql);
        $stmt->execute([
            ':platform' => $platform,
            ':channel_id' => $channelId,
            ':thread_key' => $threadKey
        ]);

        $rows = $stmt->fetchAll();
        return is_array($rows) ? $rows : [];
    }

    public function bindChannel(array $data): void {
        $sql = "INSERT INTO project_channels 
                (project_key, platform, channel_id, thread_key, is_primary, is_active, created_at, updated_at)
                VALUES (:project_key, :platform, :channel_id, :thread_key, :is_primary, :is_active, :created_at, :updated_at)";
        $stmt = $this->db->prepare($sql);
        
        $now = date('Y-m-d H:i:s');
        $stmt->execute([
            ':project_key' => $data['project_key'],
            ':platform' => $data['platform'],
            ':channel_id' => $data['channel_id'],
            ':thread_key' => $data['thread_key'] ?? null,
            ':is_primary' => $data['is_primary'] ?? 1,
            ':is_active' => $data['is_active'] ?? 1,
            ':created_at' => $data['created_at'] ?? $now,
            ':updated_at' => $now
        ]);
    }

    public function bindOrSwitchProject(string $projectKey, string $platform, string $channelId, ?string $threadKey = null): void {
        $now = date('Y-m-d H:i:s');
        $this->db->beginTransaction();
        try {
            $reset = $this->db->prepare(
                "UPDATE project_channels
                 SET is_primary = 0, updated_at = ?
                 WHERE platform = ? AND channel_id = ? AND ((thread_key IS NULL AND ? IS NULL) OR thread_key = ?)"
            );
            $reset->execute([$now, $platform, $channelId, $threadKey, $threadKey]);

            $find = $this->db->prepare(
                "SELECT id FROM project_channels
                 WHERE project_key = ? AND platform = ? AND channel_id = ?
                   AND ((thread_key IS NULL AND ? IS NULL) OR thread_key = ?)
                 LIMIT 1"
            );
            $find->execute([$projectKey, $platform, $channelId, $threadKey, $threadKey]);
            $row = $find->fetch();

            if ($row) {
                $update = $this->db->prepare(
                    "UPDATE project_channels
                     SET is_primary = 1, is_active = 1, updated_at = ?
                     WHERE id = ?"
                );
                $update->execute([$now, $row['id']]);
            } else {
                $insert = $this->db->prepare(
                    "INSERT INTO project_channels
                     (project_key, platform, channel_id, thread_key, is_primary, is_active, created_at, updated_at)
                     VALUES (?, ?, ?, ?, 1, 1, ?, ?)"
                );
                $insert->execute([$projectKey, $platform, $channelId, $threadKey, $now, $now]);
            }

            $this->db->commit();
        } catch (\Throwable $e) {
            $this->db->rollBack();
            throw $e;
        }
    }

    public function bindProject(string $projectKey, string $platform, string $channelId, ?string $threadKey = null): void {
        $now = date('Y-m-d H:i:s');
        $this->db->beginTransaction();
        try {
            $find = $this->db->prepare(
                "SELECT id FROM project_channels
                 WHERE project_key = ? AND platform = ? AND channel_id = ?
                   AND ((thread_key IS NULL AND ? IS NULL) OR thread_key = ?)
                 LIMIT 1"
            );
            $find->execute([$projectKey, $platform, $channelId, $threadKey, $threadKey]);
            $row = $find->fetch();

            if ($row) {
                $update = $this->db->prepare(
                    "UPDATE project_channels
                     SET is_active = 1, updated_at = ?
                     WHERE id = ?"
                );
                $update->execute([$now, $row['id']]);
            } else {
                $primaryCheck = $this->db->prepare(
                    "SELECT COUNT(*) AS cnt
                     FROM project_channels
                     WHERE platform = ? AND channel_id = ?
                       AND ((thread_key IS NULL AND ? IS NULL) OR thread_key = ?)
                       AND is_active = 1"
                );
                $primaryCheck->execute([$platform, $channelId, $threadKey, $threadKey]);
                $countRow = $primaryCheck->fetch();
                $isPrimary = ((int) ($countRow['cnt'] ?? 0) === 0) ? 1 : 0;

                $insert = $this->db->prepare(
                    "INSERT INTO project_channels
                     (project_key, platform, channel_id, thread_key, is_primary, is_active, created_at, updated_at)
                     VALUES (?, ?, ?, ?, ?, 1, ?, ?)"
                );
                $insert->execute([$projectKey, $platform, $channelId, $threadKey, $isPrimary, $now, $now]);
            }

            $this->db->commit();
        } catch (\Throwable $e) {
            $this->db->rollBack();
            throw $e;
        }
    }
}
