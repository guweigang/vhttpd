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
                (stream_id, task_id, platform, channel_id, thread_key, response_message_id, stream_generation, stream_creation_token, stream_creation_request, stream_instance, stream_publication_id, status, last_render_hash, created_at, updated_at)
                VALUES (:stream_id, :task_id, :platform, :channel_id, :thread_key, :response_message_id, :stream_generation, :stream_creation_token, :stream_creation_request, :stream_instance, :stream_publication_id, :status, :last_render_hash, :created_at, :updated_at)";
        $stmt = $this->db->prepare($sql);
        
        $now = date('Y-m-d H:i:s');
        $stmt->execute([
            ':stream_id' => $data['stream_id'],
            ':task_id' => $data['task_id'],
            ':platform' => $data['platform'],
            ':channel_id' => $data['channel_id'],
            ':thread_key' => $data['thread_key'] ?? null,
            ':response_message_id' => $data['response_message_id'] ?? null,
            ':stream_instance' => $data['stream_instance'] ?? 'main',
            ':stream_publication_id' => $data['stream_publication_id'] ?? '',
            ':stream_generation' => $data['stream_generation'] ?? '',
            ':stream_creation_token' => $data['stream_creation_token'] ?? '',
            ':stream_creation_request' => $data['stream_creation_request'] ?? '{}',
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

    // Reserve BEFORE emitting a rebind. A receipt can only complete this intent;
    // it cannot manufacture an intent by naming an existing stream/message ID.
    public function prepareBindingPublication(string $streamId, string $messageId, string $generation, string $expectedPublication, string $instance = 'main'): ?array {
        if ($streamId === '' || $messageId === '' || $generation === '' || $expectedPublication === '' || $instance === '') return null;
        $publication = bin2hex(random_bytes(32));
        $stmt = $this->db->prepare("UPDATE streams SET stream_publication_id = ?, stream_receipt_sequence = 0, updated_at = ?
            WHERE stream_id = ? AND response_message_id = ? AND stream_generation = ? AND stream_publication_id = ? AND stream_instance = ?
            AND platform = 'feishu' AND status IN ('opened', 'streaming')
            AND EXISTS (SELECT 1 FROM tasks WHERE tasks.task_id = streams.task_id AND tasks.status IN ('queued', 'streaming', 'active'))");
        $stmt->execute([$publication, date('Y-m-d H:i:s'), $streamId, $messageId, $generation, $expectedPublication, $instance]);
        return $stmt->rowCount() === 1 ? ['publication_id' => $publication, 'stream_generation' => $generation] : null;
    }

    public function acceptSentReceipt(array $receipt): bool {
        foreach (['stream_id', 'message_id', 'stream_generation', 'instance', 'publication_id'] as $key) {
            if (!is_string($receipt[$key] ?? null) || trim($receipt[$key]) === '') return false;
        }
        $sequence = $receipt['publication_sequence'] ?? null;
        if (!is_int($sequence) || $sequence < 1 || !preg_match('/^[a-f0-9]{64}$/D', $receipt['publication_id'])) return false;
        // One atomic SQLite statement: cancellation, a newer reservation, another
        // worker's receipt, and same-generation reordered segments all fence it.
        $stmt = $this->db->prepare("UPDATE streams SET response_message_id = :message, stream_generation = :generation,
            stream_receipt_sequence = :sequence, updated_at = :now
            WHERE stream_id = :stream AND stream_instance = :instance AND stream_publication_id = :publication
            AND stream_receipt_sequence < :sequence AND (stream_receipt_sequence = 0 OR stream_generation = :generation)
            AND platform = 'feishu' AND status IN ('opened', 'streaming')
            AND EXISTS (SELECT 1 FROM tasks WHERE tasks.task_id = streams.task_id AND tasks.status IN ('queued', 'streaming', 'active'))");
        $stmt->bindValue(':sequence', $sequence, \PDO::PARAM_INT);
        foreach ([':message' => $receipt['message_id'], ':generation' => $receipt['stream_generation'], ':now' => date('Y-m-d H:i:s'),
            ':stream' => $receipt['stream_id'], ':instance' => $receipt['instance'], ':publication' => $receipt['publication_id']] as $key => $value) {
            $stmt->bindValue($key, $value, \PDO::PARAM_STR);
        }
        $stmt->execute();
        return $stmt->rowCount() === 1;
    }

    public function updateStatus(string $streamId, string $status): void {
        $stmt = $this->db->prepare("UPDATE streams SET status = ?, stream_publication_id = CASE WHEN ? IN ('opened', 'streaming') THEN stream_publication_id ELSE '' END, updated_at = ? WHERE stream_id = ?");
        $stmt->execute([$status, $status, date('Y-m-d H:i:s'), $streamId]);
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
