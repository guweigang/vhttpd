<?php

declare(strict_types=1);

namespace CodexBot\Admin;

use CodexBot\Db;
use CodexBot\Repository\ProjectChannelRepository;
use CodexBot\Repository\ProjectRepository;
use CodexBot\Repository\SettingsRepository;
use CodexBot\Repository\StreamRepository;
use CodexBot\Repository\TaskRepository;

final class DashboardController
{
    public function __construct(private ?object $app = null) {}

    public function index(\VSlim\Request $req): \VSlim\Response
    {
        if (!$this->app || !method_exists($this->app, 'view')) {
            throw new \RuntimeException('VSlim app is not available for dashboard rendering');
        }

        return $this->app->view('admin_dashboard.html', $this->dashboardData($req->path));
    }

    public function fallbackResponse(string $path): array
    {
        return [
            'status' => 200,
            'content_type' => 'text/html; charset=utf-8',
            'body' => $this->renderFallbackHtml($path),
        ];
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
                'foot' => 'response message '
                    . (string) (($row['response_message_id'] ?? '') !== '' ? $row['response_message_id'] : 'none'),
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

    private function dashboardData(string $requestPath): array
    {
        $projects = (new ProjectRepository())->findAll(12);
        $bindings = (new ProjectChannelRepository())->findAll(12);
        $tasks = (new TaskRepository())->findRecent(12);
        $streams = (new StreamRepository())->findRecent(12);
        $settings = (new SettingsRepository())->findAll();

        return [
            'title' => 'CodexBot Admin',
            'subtitle' => 'A first VSlim-backed control surface for codexbot-app.',
            'db_path' => (string) (getenv('VHTTPD_BOT_DB_PATH') ?: dirname(__DIR__, 2) . '/codex.db'),
            'generated_at' => date('Y-m-d H:i:s'),
            'project_total' => (string) count($projects),
            'binding_total' => (string) count($bindings),
            'task_total' => (string) count($tasks),
            'stream_total' => (string) count($streams),
            'project_cards' => $this->projectCards($projects),
            'binding_cards' => $this->bindingCards($bindings),
            'task_cards' => $this->taskCards($tasks),
            'stream_cards' => $this->streamCards($streams),
            'setting_cards' => $this->settingCards($settings),
            'task_status_cards' => $this->statusCards((new TaskRepository())->countByStatus(), 'task'),
            'stream_status_cards' => $this->statusCards((new StreamRepository())->countByStatus(), 'stream'),
            'table_counts' => $this->tableCounts(),
            'request_path' => $requestPath,
        ];
    }

    private function renderFallbackHtml(string $requestPath): string
    {
        $data = $this->dashboardData($requestPath);
        $html = [];
        $html[] = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">';
        $html[] = '<title>' . $this->escape((string) $data['title']) . '</title>';
        $html[] = '<style>body{font-family:Georgia,serif;background:#f7f3eb;color:#1d2733;margin:0;padding:24px}main{max-width:1100px;margin:0 auto}section{background:#fffaf3;border:1px solid #d7c9b6;border-radius:18px;padding:18px;margin-bottom:18px}h1,h2{margin:0 0 10px}p,li{line-height:1.6}ul{padding-left:20px}.muted{color:#66707c}</style>';
        $html[] = '</head><body><main>';
        $html[] = '<section><h1>' . $this->escape((string) $data['title']) . '</h1><p>' . $this->escape((string) $data['subtitle']) . '</p>';
        $html[] = '<p class="muted">request ' . $this->escape((string) $data['request_path']) . ' | generated ' . $this->escape((string) $data['generated_at']) . ' | db ' . $this->escape((string) $data['db_path']) . '</p></section>';
        $html[] = '<section><h2>Overview</h2><ul>';
        $html[] = '<li>Projects: ' . $this->escape((string) $data['project_total']) . '</li>';
        $html[] = '<li>Bindings: ' . $this->escape((string) $data['binding_total']) . '</li>';
        $html[] = '<li>Tasks: ' . $this->escape((string) $data['task_total']) . '</li>';
        $html[] = '<li>Streams: ' . $this->escape((string) $data['stream_total']) . '</li>';
        $html[] = '</ul></section>';
        $html[] = $this->fallbackSection('Projects', $data['project_cards']);
        $html[] = $this->fallbackSection('Bindings', $data['binding_cards']);
        $html[] = $this->fallbackSection('Recent Tasks', $data['task_cards']);
        $html[] = $this->fallbackSection('Recent Streams', $data['stream_cards']);
        $html[] = $this->fallbackSection('Settings', $data['setting_cards']);
        $html[] = '</main></body></html>';
        return implode('', $html);
    }

    private function fallbackSection(string $title, array $cards): string
    {
        $html = '<section><h2>' . $this->escape($title) . '</h2><ul>';
        foreach ($cards as $card) {
            $html .= '<li><strong>' . $this->escape((string) ($card['title'] ?? '')) . '</strong><br>';
            $html .= $this->escape((string) ($card['meta'] ?? ''));
            $html .= '<br>' . $this->escape((string) ($card['detail'] ?? ''));
            if (($card['foot'] ?? '') !== '') {
                $html .= '<br>' . $this->escape((string) $card['foot']);
            }
            $html .= '</li>';
        }
        $html .= '</ul></section>';
        return $html;
    }

    private function escape(string $value): string
    {
        return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
    }
}
