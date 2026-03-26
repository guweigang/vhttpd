<?php

declare(strict_types=1);

namespace CodexBot\Admin;

use CodexBot\Db;
use CodexBot\Repository\ProjectChannelRepository;
use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\SettingsRepository;
use CodexBot\Repository\StreamRepository;
use CodexBot\Repository\TaskRepository;

final class AdminDashboardLiveView extends \VSlim\Live\View
{
    private const TOPIC = 'codexbot-admin-dashboard';

    public function __construct(
        private ?AdminMutationService $mutations = null,
    ) {
        $this->mutations ??= new AdminMutationService();
    }

    public function mount(\VSlim\Request $req, \VSlim\Live\Socket $socket): void
    {
        $socket
            ->set_root_id('admin-live-root')
            ->set_target((string) ($req->path ?? '/admin'))
            ->assign('title', 'CodexBot Admin')
            ->assign('subtitle', 'Live operations panel for projects, settings, and runtime state.')
            ->assign('request_path', (string) ($req->path ?? '/admin'))
            ->assign('live_endpoint', '/admin/live')
            ->assign('create_project_key', (string) $socket->get('create_project_key'))
            ->assign('create_project_name', (string) $socket->get('create_project_name'))
            ->assign('create_project_repo_path', (string) $socket->get('create_project_repo_path'))
            ->assign('create_project_error', (string) $socket->get('create_project_error'))
            ->assign('setting_name', (string) $socket->get('setting_name'))
            ->assign('setting_value', (string) $socket->get('setting_value'))
            ->assign('setting_error', (string) $socket->get('setting_error'))
            ->assign('project_session_key', (string) $socket->get('project_session_key'))
            ->assign('project_session_model', (string) $socket->get('project_session_model'))
            ->assign('project_session_thread_id', (string) $socket->get('project_session_thread_id'))
            ->assign('project_session_cwd', (string) $socket->get('project_session_cwd'))
            ->assign('project_session_error', (string) $socket->get('project_session_error'))
            ->assign('task_filter_status', (string) ($socket->get('task_filter_status') ?: 'all'))
            ->assign('stream_filter_status', (string) ($socket->get('stream_filter_status') ?: 'all'))
            ->assign('task_filter_project', (string) $socket->get('task_filter_project'));

        if ($socket->connected()) {
            $socket->join_topic(self::TOPIC);
        }

        $this->reloadState($socket);
    }

    public function handleEvent(string $event, array $payload, \VSlim\Live\Socket $socket): void
    {
        if ($event === 'refresh_dashboard') {
            $this->clearErrors($socket);
            $this->reloadState($socket, 'Dashboard refreshed.');
            return;
        }

        if ($event === 'create_project') {
            $projectKey = trim((string) ($payload['project_key'] ?? ''));
            $projectName = trim((string) ($payload['name'] ?? ''));
            $repoPath = trim((string) ($payload['repo_path'] ?? ''));

            $socket
                ->assign('create_project_key', $projectKey)
                ->assign('create_project_name', $projectName)
                ->assign('create_project_repo_path', $repoPath);

            $result = $this->mutations->createProject($projectKey, $projectName, $repoPath);
            if (!($result['ok'] ?? false)) {
                $socket
                    ->assign('create_project_error', (string) ($result['message'] ?? 'Unable to create project.'))
                    ->flash('error', (string) ($result['message'] ?? 'Unable to create project.'));
                $this->reloadState($socket);
                return;
            }

            $socket
                ->assign('create_project_key', '')
                ->assign('create_project_name', '')
                ->assign('create_project_repo_path', '')
                ->assign('create_project_error', '')
                ->flash('info', (string) ($result['message'] ?? 'Project created.'));
            $this->reloadState($socket);
            $socket->broadcast_info(self::TOPIC, 'dashboard_refresh', ['source' => 'create_project'], false);
            return;
        }

        if ($event === 'save_setting') {
            $name = trim((string) ($payload['name'] ?? ''));
            $value = (string) ($payload['value'] ?? '');

            $socket
                ->assign('setting_name', $name)
                ->assign('setting_value', $value);

            $result = $this->mutations->saveSetting($name, $value);
            if (!($result['ok'] ?? false)) {
                $socket
                    ->assign('setting_error', (string) ($result['message'] ?? 'Unable to save setting.'))
                    ->flash('error', (string) ($result['message'] ?? 'Unable to save setting.'));
                $this->reloadState($socket);
                return;
            }

            $socket
                ->assign('setting_error', '')
                ->flash('info', (string) ($result['message'] ?? 'Setting saved.'));
            $this->reloadState($socket);
            $socket->broadcast_info(self::TOPIC, 'dashboard_refresh', ['source' => 'save_setting'], false);
            return;
        }

        if ($event === 'update_project_session') {
            $projectKey = trim((string) ($payload['project_key'] ?? ''));
            $model = trim((string) ($payload['current_model'] ?? ''));
            $threadId = trim((string) ($payload['current_thread_id'] ?? ''));
            $cwd = trim((string) ($payload['current_cwd'] ?? ''));

            $socket
                ->assign('project_session_key', $projectKey)
                ->assign('project_session_model', $model)
                ->assign('project_session_thread_id', $threadId)
                ->assign('project_session_cwd', $cwd);

            $result = $this->mutations->updateProjectSession($projectKey, $model, $threadId, $cwd);
            if (!($result['ok'] ?? false)) {
                $socket
                    ->assign('project_session_error', (string) ($result['message'] ?? 'Unable to update project session.'))
                    ->flash('error', (string) ($result['message'] ?? 'Unable to update project session.'));
                $this->reloadState($socket);
                return;
            }

            $socket
                ->assign('project_session_error', '')
                ->flash('info', (string) ($result['message'] ?? 'Project session updated.'));
            $this->reloadState($socket);
            $socket->broadcast_info(self::TOPIC, 'dashboard_refresh', ['source' => 'update_project_session'], false);
            return;
        }

        if ($event === 'set_task_filter') {
            $socket->assign('task_filter_status', trim((string) ($payload['status'] ?? 'all')) ?: 'all');
            $this->reloadState($socket);
            return;
        }

        if ($event === 'set_stream_filter') {
            $socket->assign('stream_filter_status', trim((string) ($payload['status'] ?? 'all')) ?: 'all');
            $this->reloadState($socket);
            return;
        }

        if ($event === 'set_project_model') {
            $projectKey = trim((string) ($payload['project_key'] ?? ''));
            $model = trim((string) ($payload['model'] ?? 'gpt-5.4-codex'));
            $result = $this->mutations->setProjectModel($projectKey, $model);
            $this->handleMutationResult($socket, $result, 'set_project_model');
            return;
        }

        if ($event === 'clear_project_thread') {
            $projectKey = trim((string) ($payload['project_key'] ?? ''));
            $result = $this->mutations->clearProjectThread($projectKey);
            $this->handleMutationResult($socket, $result, 'clear_project_thread');
            return;
        }

        if ($event === 'reset_project_cwd') {
            $projectKey = trim((string) ($payload['project_key'] ?? ''));
            $result = $this->mutations->resetProjectCwd($projectKey);
            $this->handleMutationResult($socket, $result, 'reset_project_cwd');
            return;
        }

        if ($event === 'filter_tasks_by_project') {
            $projectKey = trim((string) ($payload['project_key'] ?? ''));
            $socket->assign('task_filter_project', $projectKey);
            $this->reloadState($socket, $projectKey === '' ? 'Cleared project task filter.' : 'Filtered tasks for ' . $projectKey);
            return;
        }
    }

    public function handleInfo(string $event, array $payload, \VSlim\Live\Socket $socket): void
    {
        if ($event !== 'dashboard_refresh') {
            return;
        }

        $this->reloadState($socket, 'Dashboard synced from another admin session.');
    }

    public function render(\VSlim\Request $req, \VSlim\Live\Socket $socket): string
    {
        $socket
            ->assign('generated_at', date('Y-m-d H:i:s'))
            ->assign('live_script', $this->liveRuntimeScriptTag())
            ->assign('live_attrs', $this->liveBootstrapAttrs($socket, '/admin/live'));

        if ($socket->connected()) {
            return $this->renderTemplate('admin_live_panel.html', $socket);
        }

        return $this->renderTemplate('admin_live_page.html', $socket);
    }

    private function reloadState(\VSlim\Live\Socket $socket, string $flash = ''): void
    {
        $projects = (new ProjectRepository())->findAll(12);
        $bindings = (new ProjectChannelRepository())->findAll(12);
        $taskFilter = (string) ($socket->get('task_filter_status') ?: 'all');
        $streamFilter = (string) ($socket->get('stream_filter_status') ?: 'all');
        $taskProjectFilter = trim((string) $socket->get('task_filter_project'));
        $tasks = $this->filterTaskRows((new TaskRepository())->findRecent(36), $taskFilter, $taskProjectFilter);
        $streams = $this->filterRowsByStatus((new StreamRepository())->findRecent(36), $streamFilter);
        $settings = (new SettingsRepository())->findAll();
        $projectRoot = (string) ((new SettingsRepository())->findValue('project_root_dir') ?? '');

        $socket
            ->assign('db_path', (string) (getenv('VHTTPD_BOT_DB_PATH') ?: dirname(__DIR__, 2) . '/codex.db'))
            ->assign('project_root_dir', $projectRoot !== '' ? $projectRoot : 'not set')
            ->assign('project_total', (string) count($projects))
            ->assign('binding_total', (string) count($bindings))
            ->assign('task_total', (string) count($tasks))
            ->assign('stream_total', (string) count($streams))
            ->assign('project_cards_html', $this->renderProjectCardsHtml($this->projectCards($projects)))
            ->assign('binding_cards_html', $this->renderCardsHtml($this->bindingCards($bindings)))
            ->assign('task_cards_html', $this->renderCardsHtml($this->taskCards($tasks)))
            ->assign('stream_cards_html', $this->renderCardsHtml($this->streamCards($streams)))
            ->assign('setting_cards_html', $this->renderCardsHtml($this->settingCards($settings)))
            ->assign('task_status_cards_html', $this->renderCardsHtml($this->statusCards((new TaskRepository())->countByStatus(), 'task')))
            ->assign('stream_status_cards_html', $this->renderCardsHtml($this->statusCards((new StreamRepository())->countByStatus(), 'stream')))
            ->assign('task_filter_status', $taskFilter)
            ->assign('stream_filter_status', $streamFilter)
            ->assign('task_filter_project', $taskProjectFilter)
            ->assign('task_filter_label', strtoupper($taskFilter))
            ->assign('stream_filter_label', strtoupper($streamFilter))
            ->assign('task_filter_project_label', $taskProjectFilter !== '' ? $taskProjectFilter : 'ALL')
            ->assign('table_counts_html', $this->renderCardsHtml($this->tableCounts()))
            ->assign('empty_project_path_hint', $projectRoot !== '' ? rtrim($projectRoot, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . '{project_key}' : 'set project_root_dir first')
            ->assign('project_session_hint', $this->projectSessionHint($projects));

        if ($flash !== '') {
            $socket->flash('info', $flash);
        }
    }

    private function clearErrors(\VSlim\Live\Socket $socket): void
    {
        $socket
            ->assign('create_project_error', '')
            ->assign('setting_error', '')
            ->assign('project_session_error', '');
    }

    private function renderTemplate(string $template, \VSlim\Live\Socket $socket): string
    {
        $view = new \VSlim\View(dirname(__DIR__, 2) . '/views', '/assets');
        $html = $view->render($template, $socket->assigns());
        if (!is_string($html)) {
            throw new \RuntimeException('Unable to render admin live template: ' . $template);
        }

        return $html;
    }

    private function liveRuntimeScriptTag(): string
    {
        return '<script defer src="/assets/vphp_live.js"></script>';
    }

    private function liveBootstrapAttrs(\VSlim\Live\Socket $socket, string $endpoint): string
    {
        $target = (string) $socket->target();
        if ($target === '') {
            $target = '/admin';
        }

        $rootId = (string) $socket->root_id();
        if ($rootId === '') {
            $rootId = 'admin-live-root';
        }

        return 'data-vphp-live="1"'
            . ' data-vphp-live-endpoint="' . $this->escape($endpoint) . '"'
            . ' data-vphp-live-path="' . $this->escape($target) . '"'
            . ' data-vphp-live-root="' . $this->escape($rootId) . '"';
    }

    private function projectCards(array $rows): array
    {
        $cards = [];
        foreach ($rows as $row) {
            $cards[] = [
                'title' => (string) ($row['name'] ?? $row['project_key'] ?? 'project'),
                'meta' => 'key: ' . (string) ($row['project_key'] ?? 'n/a'),
                'detail' => 'branch ' . (string) ($row['default_branch'] ?? 'main')
                    . ' | model ' . (string) (($row['current_model'] ?? '') !== '' ? $row['current_model'] : 'unset')
                    . ' | thread ' . (string) (($row['current_thread_id'] ?? '') !== '' ? $row['current_thread_id'] : 'none'),
                'foot' => 'cwd: ' . (string) ($row['current_cwd'] ?? $row['repo_path'] ?? ''),
                'project_key' => (string) ($row['project_key'] ?? ''),
                'repo_path' => (string) ($row['repo_path'] ?? ''),
                'quick_model' => (string) (($row['current_model'] ?? '') !== '' ? $row['current_model'] : 'gpt-5.4-codex'),
                'tone' => ((int) ($row['is_active'] ?? 0) === 1) ? 'ok' : 'muted',
            ];
        }
        return $cards;
    }

    private function bindingCards(array $rows): array
    {
        $cards = [];
        foreach ($rows as $row) {
            $cards[] = [
                'title' => (string) ($row['project_name'] ?? $row['project_key'] ?? 'binding'),
                'meta' => (string) ($row['platform'] ?? 'unknown') . ' -> ' . (string) ($row['channel_id'] ?? 'n/a'),
                'detail' => 'thread_key ' . (string) (($row['thread_key'] ?? '') !== '' ? $row['thread_key'] : 'none'),
                'foot' => 'primary ' . (((int) ($row['is_primary'] ?? 0) === 1) ? 'yes' : 'no')
                    . ' | active ' . (((int) ($row['is_active'] ?? 0) === 1) ? 'yes' : 'no'),
                'tone' => ((int) ($row['is_active'] ?? 0) === 1) ? 'ok' : 'muted',
            ];
        }
        return $cards;
    }

    private function taskCards(array $rows): array
    {
        $cards = [];
        foreach ($rows as $row) {
            $prompt = trim((string) ($row['prompt'] ?? ''));
            if (strlen($prompt) > 72) {
                $prompt = substr($prompt, 0, 69) . '...';
            }
            $cards[] = [
                'title' => (string) ($row['task_type'] ?? 'task') . ' | ' . (string) ($row['status'] ?? 'unknown'),
                'meta' => 'task ' . (string) ($row['task_id'] ?? 'n/a'),
                'detail' => $prompt === '' ? '(empty prompt)' : $prompt,
                'foot' => 'project ' . (string) ($row['project_key'] ?? 'n/a')
                    . ' | stream ' . (string) (($row['stream_id'] ?? '') !== '' ? $row['stream_id'] : 'none'),
                'tone' => $this->statusTone((string) ($row['status'] ?? '')),
            ];
        }
        return $cards;
    }

    private function streamCards(array $rows): array
    {
        $cards = [];
        foreach ($rows as $row) {
            $cards[] = [
                'title' => (string) ($row['status'] ?? 'stream'),
                'meta' => 'stream ' . (string) ($row['stream_id'] ?? 'n/a'),
                'detail' => 'task ' . (string) ($row['task_id'] ?? 'n/a')
                    . ' | channel ' . (string) ($row['channel_id'] ?? 'n/a'),
                'foot' => 'response message ' . (string) (($row['response_message_id'] ?? '') !== '' ? $row['response_message_id'] : 'none'),
                'tone' => $this->statusTone((string) ($row['status'] ?? '')),
            ];
        }
        return $cards;
    }

    private function settingCards(array $rows): array
    {
        $cards = [];
        foreach ($rows as $row) {
            $cards[] = [
                'title' => (string) ($row['name'] ?? 'setting'),
                'meta' => 'runtime setting',
                'detail' => (string) ($row['value'] ?? ''),
                'foot' => '',
                'tone' => 'muted',
            ];
        }
        if ($cards === []) {
            $cards[] = [
                'title' => 'No settings yet',
                'meta' => 'runtime setting',
                'detail' => 'The settings table is empty.',
                'foot' => '',
                'tone' => 'muted',
            ];
        }
        return $cards;
    }

    private function statusCards(array $rows, string $prefix): array
    {
        $cards = [];
        foreach ($rows as $row) {
            $status = (string) ($row['status'] ?? 'unknown');
            $cards[] = [
                'title' => strtoupper($status),
                'meta' => $prefix . ' status',
                'detail' => (string) ($row['total'] ?? '0') . ' record(s)',
                'foot' => '',
                'tone' => $this->statusTone($status),
            ];
        }
        if ($cards === []) {
            $cards[] = [
                'title' => 'EMPTY',
                'meta' => $prefix . ' status',
                'detail' => 'No records yet.',
                'foot' => '',
                'tone' => 'muted',
            ];
        }
        return $cards;
    }

    private function tableCounts(): array
    {
        $pdo = Db::getConnection();
        $tables = ['projects', 'project_channels', 'tasks', 'streams', 'settings', 'command_contexts'];
        $cards = [];
        foreach ($tables as $table) {
            $count = (int) $pdo->query('SELECT COUNT(*) FROM ' . $table)->fetchColumn();
            $cards[] = [
                'title' => $table,
                'meta' => 'sqlite table',
                'detail' => (string) $count . ' row(s)',
                'foot' => '',
                'tone' => $count > 0 ? 'ok' : 'muted',
            ];
        }
        return $cards;
    }

    private function statusTone(string $status): string
    {
        return match ($status) {
            'completed', 'opened', 'saved' => 'ok',
            'queued', 'streaming', 'pending_bind' => 'warn',
            'failed', 'error', 'cancelled' => 'bad',
            default => 'muted',
        };
    }

    private function filterRowsByStatus(array $rows, string $status): array
    {
        if ($status === '' || $status === 'all') {
            return array_slice($rows, 0, 12);
        }

        $filtered = array_values(array_filter($rows, static function (array $row) use ($status): bool {
            return (string) ($row['status'] ?? '') === $status;
        }));

        return array_slice($filtered, 0, 12);
    }

    private function filterTaskRows(array $rows, string $status, string $projectKey): array
    {
        $filtered = $rows;
        if ($projectKey !== '') {
            $filtered = array_values(array_filter($filtered, static function (array $row) use ($projectKey): bool {
                return (string) ($row['project_key'] ?? '') === $projectKey;
            }));
        }

        return $this->filterRowsByStatus($filtered, $status);
    }

    private function projectSessionHint(array $projects): string
    {
        if ($projects === []) {
            return 'Create a project first, then set its current model, thread, or cwd here.';
        }

        $first = $projects[0];
        return (string) ($first['project_key'] ?? 'demo');
    }

    private function handleMutationResult(\VSlim\Live\Socket $socket, array $result, string $source): void
    {
        if (!($result['ok'] ?? false)) {
            $socket->flash('error', (string) ($result['message'] ?? 'Operation failed.'));
            $this->reloadState($socket);
            return;
        }

        $socket->flash('info', (string) ($result['message'] ?? 'Operation completed.'));
        $this->reloadState($socket);
        $socket->broadcast_info(self::TOPIC, 'dashboard_refresh', ['source' => $source], false);
    }

    private function renderCardsHtml(array $cards): string
    {
        $html = '';
        foreach ($cards as $card) {
            $tone = $this->escape((string) ($card['tone'] ?? 'muted'));
            $html .= '<div class="card tone-' . $tone . '">';
            $html .= '<strong>' . $this->escape((string) ($card['title'] ?? '')) . '</strong>';
            $html .= '<p>' . $this->escape((string) ($card['meta'] ?? '')) . '</p>';
            $html .= '<p>' . $this->escape((string) ($card['detail'] ?? '')) . '</p>';
            if (($card['foot'] ?? '') !== '') {
                $html .= '<p>' . $this->escape((string) $card['foot']) . '</p>';
            }
            $html .= '</div>';
        }
        return $html;
    }

    private function renderProjectCardsHtml(array $cards): string
    {
        $html = '';
        foreach ($cards as $card) {
            $tone = $this->escape((string) ($card['tone'] ?? 'muted'));
            $projectKey = $this->escape((string) ($card['project_key'] ?? ''));
            $quickModel = $this->escape((string) ($card['quick_model'] ?? 'gpt-5.4-codex'));
            $html .= '<div class="card tone-' . $tone . '">';
            $html .= '<strong>' . $this->escape((string) ($card['title'] ?? '')) . '</strong>';
            $html .= '<p>' . $this->escape((string) ($card['meta'] ?? '')) . '</p>';
            $html .= '<p>' . $this->escape((string) ($card['detail'] ?? '')) . '</p>';
            if (($card['foot'] ?? '') !== '') {
                $html .= '<p>' . $this->escape((string) $card['foot']) . '</p>';
            }
            $html .= '<div class="actions">';
            $html .= '<button type="button" class="alt" vphp-click="set_project_model" vphp-value-project_key="' . $projectKey . '" vphp-value-model="' . $quickModel . '">Set Model</button>';
            $html .= '<button type="button" class="alt" vphp-click="clear_project_thread" vphp-value-project_key="' . $projectKey . '">Clear Thread</button>';
            $html .= '<button type="button" class="alt" vphp-click="reset_project_cwd" vphp-value-project_key="' . $projectKey . '">Reset Cwd</button>';
            $html .= '<button type="button" class="alt" vphp-click="filter_tasks_by_project" vphp-value-project_key="' . $projectKey . '">Filter Tasks</button>';
            $html .= '</div></div>';
        }
        return $html;
    }

    private function escape(string $value): string
    {
        return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
    }
}
