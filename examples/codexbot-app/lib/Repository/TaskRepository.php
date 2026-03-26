<?php

namespace CodexBot\Repository;

use CodexBot\Db;

class TaskRepository {
    private $db;

    public function __construct() {
        $this->db = Db::getConnection();
    }

    public function create(array $data): void {
        $sql = "INSERT INTO tasks 
                (task_id, project_key, thread_id, platform, channel_id, thread_key, user_id, request_message_id, stream_id, task_type, prompt, status, codex_turn_id, created_at, updated_at)
                VALUES (:task_id, :project_key, :thread_id, :platform, :channel_id, :thread_key, :user_id, :request_message_id, :stream_id, :task_type, :prompt, :status, :codex_turn_id, :created_at, :updated_at)";
        $stmt = $this->db->prepare($sql);
        
        $now = date('Y-m-d H:i:s');
        $stmt->execute([
            ':task_id' => $data['task_id'],
            ':project_key' => $data['project_key'],
            ':thread_id' => $data['thread_id'] ?? null,
            ':platform' => $data['platform'],
            ':channel_id' => $data['channel_id'],
            ':thread_key' => $data['thread_key'] ?? null,
            ':user_id' => $data['user_id'] ?? null,
            ':request_message_id' => $data['request_message_id'] ?? null,
            ':stream_id' => $data['stream_id'] ?? null,
            ':task_type' => $data['task_type'],
            ':prompt' => $data['prompt'],
            ':status' => $data['status'] ?? 'queued',
            ':codex_turn_id' => $data['codex_turn_id'] ?? null,
            ':created_at' => $data['created_at'] ?? $now,
            ':updated_at' => $now
        ]);
    }

    public function findByTaskId(string $taskId): ?array {
        $stmt = $this->db->prepare("SELECT * FROM tasks WHERE task_id = ? LIMIT 1");
        $stmt->execute([$taskId]);
        return $stmt->fetch() ?: null;
    }

    public function findRecent(int $limit = 20): array {
        $stmt = $this->db->prepare(
            "SELECT t.*, s.response_message_id
             FROM tasks t
             LEFT JOIN streams s ON t.stream_id = s.stream_id
             ORDER BY t.created_at DESC, t.task_id DESC
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
             FROM tasks
             GROUP BY status
             ORDER BY status ASC"
        );
        $rows = $stmt ? $stmt->fetchAll() : [];
        return is_array($rows) ? $rows : [];
    }

    public function findLatestCancelableTask(string $platform, string $channelId): ?array {
        $stmt = $this->db->prepare(
            "SELECT t.*, s.response_message_id
             FROM tasks t
             LEFT JOIN streams s ON t.stream_id = s.stream_id
             WHERE t.platform = ?
               AND t.channel_id = ?
               AND t.status IN ('queued', 'streaming')
               AND t.task_type NOT IN ('thread_list', 'thread_read', 'use_thread', 'use_thread_latest')
             ORDER BY t.created_at DESC
             LIMIT 1"
        );
        $stmt->execute([$platform, $channelId]);
        $row = $stmt->fetch();
        return $row ?: null;
    }

    public function updateStatus(string $taskId, string $status, ?string $errorMessage = null): void {
        $sql = "UPDATE tasks SET status = :status, error_message = :error, updated_at = :now WHERE task_id = :task_id";
        $stmt = $this->db->prepare($sql);
        $stmt->execute([
            ':status' => $status,
            ':error' => $errorMessage,
            ':now' => date('Y-m-d H:i:s'),
            ':task_id' => $taskId
        ]);
    }

    public function bindThread(string $taskId, string $threadId): void {
        $stmt = $this->db->prepare("UPDATE tasks SET thread_id = ?, updated_at = ? WHERE task_id = ?");
        $stmt->execute([$threadId, date('Y-m-d H:i:s'), $taskId]);
    }

    public function bindStream(string $taskId, string $streamId): void {
        $stmt = $this->db->prepare("UPDATE tasks SET stream_id = ?, updated_at = ? WHERE task_id = ?");
        $stmt->execute([$streamId, date('Y-m-d H:i:s'), $taskId]);
    }

    public function bindCodexTurn(string $taskId, string $turnId): void {
        $stmt = $this->db->prepare("UPDATE tasks SET codex_turn_id = ?, updated_at = ? WHERE task_id = ?");
        $stmt->execute([$turnId, date('Y-m-d H:i:s'), $taskId]);
    }

    public function findPendingThreadSelection(string $projectKey): ?array {
        $stmt = $this->db->prepare(
            "SELECT task_id, project_key, thread_id, prompt, status, updated_at
             FROM tasks
             WHERE project_key = ? AND task_type = 'use_thread' AND status = 'pending_bind'
               AND thread_id <> 'latest'
             ORDER BY updated_at DESC, created_at DESC
             LIMIT 1"
        );
        $stmt->execute([$projectKey]);
        $row = $stmt->fetch();
        return $row ?: null;
    }

    public function resolvePendingThreadSelection(string $projectKey, string $threadId): void {
        $stmt = $this->db->prepare(
            "UPDATE tasks
             SET status = 'completed', updated_at = ?
             WHERE project_key = ?
               AND task_type = 'use_thread'
               AND status = 'pending_bind'
               AND thread_id = ?"
        );
        $stmt->execute([date('Y-m-d H:i:s'), $projectKey, $threadId]);
    }

    public function clearPendingThreadSelections(string $projectKey): void {
        $stmt = $this->db->prepare(
            "UPDATE tasks
             SET status = 'completed', updated_at = ?
             WHERE project_key = ?
               AND task_type = 'use_thread'
               AND status = 'pending_bind'"
        );
        $stmt->execute([date('Y-m-d H:i:s'), $projectKey]);
    }

    public function findLatestByThreadId(string $threadId): ?array {
        $stmt = $this->db->prepare(
            "SELECT t.task_id, t.project_key, t.thread_id, t.stream_id, t.task_type, t.prompt, t.status, t.codex_turn_id, t.error_message, t.created_at, t.updated_at, s.response_message_id
             FROM tasks t
             LEFT JOIN streams s ON t.stream_id = s.stream_id
             WHERE t.thread_id = ?
             ORDER BY t.created_at DESC
             LIMIT 1"
        );
        $stmt->execute([$threadId]);
        $row = $stmt->fetch();
        return $row ?: null;
    }

    public function findRecentByThreadId(string $threadId, int $limit = 3): array {
        $stmt = $this->db->prepare(
            "SELECT t.task_id, t.project_key, t.thread_id, t.stream_id, t.task_type, t.prompt, t.status, t.codex_turn_id, t.error_message, t.created_at, t.updated_at, s.response_message_id
             FROM tasks t
             LEFT JOIN streams s ON t.stream_id = s.stream_id
             WHERE t.thread_id = ?
             ORDER BY t.created_at DESC
             LIMIT ?"
        );
        $stmt->bindValue(1, $threadId);
        $stmt->bindValue(2, $limit, \PDO::PARAM_INT);
        $stmt->execute();
        $rows = $stmt->fetchAll();
        return is_array($rows) ? $rows : [];
    }

    public function findLatestErrorByThreadId(string $threadId): ?array {
        $stmt = $this->db->prepare(
            "SELECT error_message, status
             FROM tasks
             WHERE thread_id = ?
             ORDER BY created_at DESC
             LIMIT 1"
        );
        $stmt->execute([$threadId]);
        $row = $stmt->fetch();
        return $row ?: null;
    }

    public function resolveStreamContext(?string $streamId, ?string $threadId = null, ?string $turnId = null, ?string $channelId = null): ?array {
        $channelId = trim((string) ($channelId ?? ''));
        $sql = "SELECT t.task_id, t.stream_id, t.channel_id, t.thread_id, t.status, s.response_message_id
                FROM tasks t
                LEFT JOIN streams s ON t.stream_id = s.stream_id";

        if (!empty($streamId)) {
            $query = $sql . " WHERE t.stream_id = ?";
            $params = [$streamId];
            if ($channelId !== '') {
                $query .= " AND t.channel_id = ?";
                $params[] = $channelId;
            }
            $stmt = $this->db->prepare($query . " ORDER BY t.created_at DESC LIMIT 1");
            $stmt->execute($params);
            $row = $stmt->fetch();
            if ($row) {
                return $row;
            }
        }

        if (!empty($turnId)) {
            $query = $sql . " WHERE t.codex_turn_id = ?";
            $params = [$turnId];
            if ($channelId !== '') {
                $query .= " AND t.channel_id = ?";
                $params[] = $channelId;
            }
            $stmt = $this->db->prepare($query . " ORDER BY t.created_at DESC LIMIT 1");
            $stmt->execute($params);
            $row = $stmt->fetch();
            if ($row) {
                return $row;
            }
        }

        if (!empty($threadId)) {
            $query = $sql . " WHERE t.thread_id = ?";
            $params = [$threadId];
            if ($channelId !== '') {
                $query .= " AND t.channel_id = ?";
                $params[] = $channelId;
            }
            $stmt = $this->db->prepare($query . " ORDER BY t.created_at DESC LIMIT 1");
            $stmt->execute($params);
            $row = $stmt->fetch();
            if ($row) {
                return $row;
            }
        }

        return null;
    }

    public function resolveRecoveryContext(?string $turnId = null, ?string $threadId = null, ?string $channelId = null): ?array {
        return $this->resolveStreamContext(null, $threadId, $turnId, $channelId);
    }
}
