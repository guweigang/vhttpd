<?php

namespace CodexBot\Repository;

use CodexBot\Db;

class StreamRepository {
    private $db;

    public function __construct() {
        $this->db = Db::getConnection();
    }

    public function create(array $data): void {
        $sql = "INSERT INTO streams 
                (stream_id, task_id, platform, channel_id, thread_key, response_message_id, status, last_render_hash, created_at, updated_at)
                VALUES (:stream_id, :task_id, :platform, :channel_id, :thread_key, :response_message_id, :status, :last_render_hash, :created_at, :updated_at)";
        $stmt = $this->db->prepare($sql);
        
        $now = date('Y-m-d H:i:s');
        $stmt->execute([
            ':stream_id' => $data['stream_id'],
            ':task_id' => $data['task_id'],
            ':platform' => $data['platform'],
            ':channel_id' => $data['channel_id'],
            ':thread_key' => $data['thread_key'] ?? null,
            ':response_message_id' => $data['response_message_id'] ?? null,
            ':status' => $data['status'] ?? 'opened',
            ':last_render_hash' => $data['last_render_hash'] ?? null,
            ':created_at' => $data['created_at'] ?? $now,
            ':updated_at' => $now
        ]);
    }

    public function findByStreamId(string $streamId): ?array {
        $stmt = $this->db->prepare("SELECT * FROM streams WHERE stream_id = ? LIMIT 1");
        $stmt->execute([$streamId]);
        return $stmt->fetch() ?: null;
    }

    public function findRecent(int $limit = 20): array {
        $stmt = $this->db->prepare(
            "SELECT *
             FROM streams
             ORDER BY created_at DESC, stream_id DESC
             LIMIT ?"
        );
        $stmt->bindValue(1, $limit, \PDO::PARAM_INT);
        $stmt->execute();
        $rows = $stmt->fetchAll();
        return is_array($rows) ? $rows : [];
    }

    public function countByStatus(): array {
        $stmt = $this->db->query(
            "SELECT status, COUNT(*) AS total
             FROM streams
             GROUP BY status
             ORDER BY status ASC"
        );
        $rows = $stmt ? $stmt->fetchAll() : [];
        return is_array($rows) ? $rows : [];
    }

    public function bindResponseMessageId(string $streamId, string $messageId): void {
        $stmt = $this->db->prepare("UPDATE streams SET response_message_id = ?, updated_at = ? WHERE stream_id = ?");
        $stmt->execute([$messageId, date('Y-m-d H:i:s'), $streamId]);
    }

    public function updateStatus(string $streamId, string $status): void {
        $stmt = $this->db->prepare("UPDATE streams SET status = ?, updated_at = ? WHERE stream_id = ?");
        $stmt->execute([$status, date('Y-m-d H:i:s'), $streamId]);
    }

    public function updateLastRenderHash(string $streamId, string $hash): void {
        $stmt = $this->db->prepare("UPDATE streams SET last_render_hash = ?, updated_at = ? WHERE stream_id = ?");
        $stmt->execute([$hash, date('Y-m-d H:i:s'), $streamId]);
    }

    public function findMessageIdByStreamId(string $streamId): ?string {
        $stmt = $this->db->prepare("SELECT response_message_id FROM streams WHERE stream_id = ? LIMIT 1");
        $stmt->execute([$streamId]);
        $res = $stmt->fetch();
        return $res ? $res['response_message_id'] : null;
    }
}
