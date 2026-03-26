<?php

declare(strict_types=1);

namespace CodexBot\Admin;

use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\SettingsRepository;

final class AdminMutationService
{
    public function __construct(
        private ?ProjectRepository $projectRepo = null,
        private ?SettingsRepository $settingsRepo = null,
    ) {
        $this->projectRepo ??= new ProjectRepository();
        $this->settingsRepo ??= new SettingsRepository();
    }

    public function createProject(string $projectKey, ?string $name = null, ?string $repoPath = null): array
    {
        $projectKey = trim($projectKey);
        $name = trim((string) $name);
        $repoPath = trim((string) $repoPath);

        if ($projectKey === '') {
            return ['ok' => false, 'message' => 'Project key is required.'];
        }
        if (!preg_match('/^[a-zA-Z0-9._-]+$/', $projectKey)) {
            return ['ok' => false, 'message' => 'Use letters, numbers, dot, underscore, or dash in project key.'];
        }
        if ($this->projectRepo->findByProjectKey($projectKey)) {
            return ['ok' => false, 'message' => 'Project already exists: ' . $projectKey];
        }

        $projectRootDir = trim((string) ($this->settingsRepo->findValue('project_root_dir') ?? ''));
        if ($repoPath === '') {
            if ($projectRootDir === '') {
                return ['ok' => false, 'message' => 'Set project_root_dir first or provide an explicit repo path.'];
            }
            $repoPath = rtrim($projectRootDir, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . $projectKey;
        }

        if (!is_dir($repoPath) && !mkdir($repoPath, 0777, true) && !is_dir($repoPath)) {
            return ['ok' => false, 'message' => 'Failed to create repo path: ' . $repoPath];
        }

        $this->projectRepo->save([
            'project_key' => $projectKey,
            'name' => $name !== '' ? $name : $projectKey,
            'repo_path' => $repoPath,
            'default_branch' => 'main',
            'current_model' => null,
            'current_thread_id' => null,
            'current_cwd' => $repoPath,
            'is_active' => 1,
        ]);

        return [
            'ok' => true,
            'message' => 'Created project ' . $projectKey,
            'project_key' => $projectKey,
            'repo_path' => $repoPath,
        ];
    }

    public function saveSetting(string $name, string $value): array
    {
        $name = trim($name);
        if ($name === '') {
            return ['ok' => false, 'message' => 'Setting name is required.'];
        }

        $this->settingsRepo->upsert($name, $value);
        return [
            'ok' => true,
            'message' => 'Saved setting ' . $name,
            'name' => $name,
            'value' => $value,
        ];
    }

    public function updateProjectSession(string $projectKey, ?string $model = null, ?string $threadId = null, ?string $cwd = null): array
    {
        $projectKey = trim($projectKey);
        if ($projectKey === '') {
            return ['ok' => false, 'message' => 'Project key is required.'];
        }

        $project = $this->projectRepo->findByProjectKey($projectKey);
        if (!$project) {
            return ['ok' => false, 'message' => 'Project not found: ' . $projectKey];
        }

        $model = trim((string) $model);
        $threadId = trim((string) $threadId);
        $cwd = trim((string) $cwd);

        $nextModel = $model !== '' ? $model : null;
        $nextThread = $threadId !== '' ? $threadId : null;
        $nextCwd = $cwd !== '' ? $cwd : (string) ($project['current_cwd'] ?? $project['repo_path'] ?? '');

        $this->projectRepo->updateCurrentModel($projectKey, $nextModel);
        $this->projectRepo->updateCurrentThread($projectKey, $nextThread, $nextCwd);

        return [
            'ok' => true,
            'message' => 'Updated session defaults for ' . $projectKey,
            'project_key' => $projectKey,
            'current_model' => $nextModel,
            'current_thread_id' => $nextThread,
            'current_cwd' => $nextCwd,
        ];
    }

    public function setProjectModel(string $projectKey, string $model): array
    {
        return $this->updateProjectSession($projectKey, $model, null, null);
    }

    public function clearProjectThread(string $projectKey): array
    {
        $projectKey = trim($projectKey);
        if ($projectKey === '') {
            return ['ok' => false, 'message' => 'Project key is required.'];
        }

        $project = $this->projectRepo->findByProjectKey($projectKey);
        if (!$project) {
            return ['ok' => false, 'message' => 'Project not found: ' . $projectKey];
        }

        $cwd = (string) ($project['current_cwd'] ?? $project['repo_path'] ?? '');
        $this->projectRepo->updateCurrentThread($projectKey, null, $cwd);

        return [
            'ok' => true,
            'message' => 'Cleared current thread for ' . $projectKey,
            'project_key' => $projectKey,
        ];
    }

    public function resetProjectCwd(string $projectKey): array
    {
        $projectKey = trim($projectKey);
        if ($projectKey === '') {
            return ['ok' => false, 'message' => 'Project key is required.'];
        }

        $project = $this->projectRepo->findByProjectKey($projectKey);
        if (!$project) {
            return ['ok' => false, 'message' => 'Project not found: ' . $projectKey];
        }

        $threadId = (string) ($project['current_thread_id'] ?? '');
        $repoPath = (string) ($project['repo_path'] ?? '');
        $this->projectRepo->updateCurrentThread($projectKey, $threadId !== '' ? $threadId : null, $repoPath);

        return [
            'ok' => true,
            'message' => 'Reset cwd to repo root for ' . $projectKey,
            'project_key' => $projectKey,
            'current_cwd' => $repoPath,
        ];
    }
}
