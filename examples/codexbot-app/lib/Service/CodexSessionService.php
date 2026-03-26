<?php

namespace CodexBot\Service;

use CodexBot\Repository\ProjectRepository;

class CodexSessionService {
    private $projectRepo;

    public function __construct(ProjectRepository $projectRepo) {
        $this->projectRepo = $projectRepo;
    }

    public function getSession(string $projectKey): array {
        $project = $this->projectRepo->findByProjectKey($projectKey);
        if (!$project) {
            throw new \Exception("Project not found: {$projectKey}");
        }

        return [
            'model' => $project['current_model'] ?? null,
            'thread_id' => $project['current_thread_id'],
            'cwd' => $project['current_cwd'] ?: $project['repo_path'],
            'repo_path' => $project['repo_path']
        ];
    }

    public function updateThread(string $projectKey, ?string $threadId, ?string $cwd): void {
        $this->projectRepo->updateCurrentThread($projectKey, $threadId, $cwd);
    }

    public function updateModel(string $projectKey, ?string $model): void {
        $this->projectRepo->updateCurrentModel($projectKey, $model);
    }
}
