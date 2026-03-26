<?php

namespace CodexBot\Repository;

use CodexBot\Db;

class ProjectRepository {
    private $db;

    public function __construct() {
        $this->db = Db::getConnection();
    }

    public function findByProjectKey(string $projectKey): ?array {
        $stmt = $this->db->prepare("SELECT * FROM projects WHERE project_key = ? LIMIT 1");
        $stmt->execute([$projectKey]);
        $res = $stmt->fetch();
        return $res ?: null;
    }

    public function findAll(int $limit = 20): array {
        $stmt = $this->db->prepare(
            "SELECT *
             FROM projects
             ORDER BY is_active DESC, updated_at DESC, project_key ASC
             LIMIT ?"
        );
        $stmt->bindValue(1, $limit, \PDO::PARAM_INT);
        $stmt->execute();
        $rows = $stmt->fetchAll();
        return is_array($rows) ? $rows : [];
    }

    public function save(array $data): void {
        $sql = "INSERT OR REPLACE INTO projects 
                (project_key, name, repo_path, default_branch, current_model, current_thread_id, current_cwd, is_active, created_at, updated_at)
                VALUES (:project_key, :name, :repo_path, :default_branch, :current_model, :current_thread_id, :current_cwd, :is_active, :created_at, :updated_at)";
        $stmt = $this->db->prepare($sql);
        
        $now = date('Y-m-d H:i:s');
        $params = [
            ':project_key' => $data['project_key'],
            ':name' => $data['name'] ?? $data['project_key'],
            ':repo_path' => $data['repo_path'],
            ':default_branch' => $data['default_branch'] ?? 'main',
            ':current_model' => $data['current_model'] ?? null,
            ':current_thread_id' => $data['current_thread_id'] ?? null,
            ':current_cwd' => $data['current_cwd'] ?? $data['repo_path'],
            ':is_active' => $data['is_active'] ?? 1,
            ':created_at' => $data['created_at'] ?? $now,
            ':updated_at' => $now
        ];
        
        $stmt->execute($params);
    }

    public function updateCurrentThread(string $projectKey, ?string $threadId, ?string $cwd): void {
        $stmt = $this->db->prepare("UPDATE projects SET current_thread_id = ?, current_cwd = ?, updated_at = ? WHERE project_key = ?");
        $stmt->execute([$threadId, $cwd, date('Y-m-d H:i:s'), $projectKey]);
    }

    public function updateCurrentModel(string $projectKey, ?string $model): void {
        $stmt = $this->db->prepare("UPDATE projects SET current_model = ?, updated_at = ? WHERE project_key = ?");
        $stmt->execute([$model, date('Y-m-d H:i:s'), $projectKey]);
    }
}
