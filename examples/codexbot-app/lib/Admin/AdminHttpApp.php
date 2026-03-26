<?php

declare(strict_types=1);

namespace CodexBot\Admin;

final class AdminHttpApp
{
    private ?\VSlim\App $app = null;
    private ?DashboardController $fallbackController = null;

    public function app(): \VSlim\App
    {
        if ($this->app instanceof \VSlim\App) {
            return $this->app;
        }

        $app = new \VSlim\App();
        $app->set_view_base_path(dirname(__DIR__, 2) . '/views');
        $app->set_assets_prefix('/assets');

        $container = $app->container();
        $container->set(DashboardController::class, new DashboardController($app));
        $container->set(AdminDashboardLiveView::class, new AdminDashboardLiveView());

        $app->set_not_found_handler(static function (\VSlim\Request $req): array {
            return [
                'status' => 404,
                'content_type' => 'application/json',
                'body' => json_encode([
                    'error' => 'Not Found',
                    'path' => $req->path,
                ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
            ];
        });

        $app->set_error_handler(static function (\VSlim\Request $req, string $message, int $status): array {
            return [
                'status' => $status,
                'content_type' => 'application/json',
                'body' => json_encode([
                    'error' => 'Runtime Error',
                    'message' => $message,
                    'path' => $req->path,
                ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
            ];
        });

        $app->get('/', static function (): array {
            return [
                'status' => 302,
                'headers' => ['location' => '/admin'],
                'body' => '',
            ];
        });

        $app->get('/health', static function (): array {
            return [
                'status' => 200,
                'content_type' => 'text/plain; charset=utf-8',
                'body' => 'OK',
            ];
        });

        if (class_exists(\VSlim\Live\View::class)) {
            /** @var AdminDashboardLiveView $live */
            $live = $container->get(AdminDashboardLiveView::class);
            $live->set_app($app);
            $live->set_root_id('admin-live-root');
            $live->set_template('admin_live_page.html');
            $app->live('/admin', $live);
            $app->websocket('/admin/live', $live);
        } else {
            $app->get('/admin', [DashboardController::class, 'index']);
        }

        $this->app = $app;
        return $this->app;
    }

    public function handle(array $request): array
    {
        if (!class_exists(\VSlim\App::class)) {
            return $this->handleFallback($request);
        }

        $app = $this->app();

        if (method_exists($app, 'dispatch_envelope_map')) {
            return $this->normalizeEnvelopeMap($app->dispatch_envelope_map($request));
        }

        if (method_exists($app, 'dispatch_envelope_worker')) {
            $app->dispatch_envelope_worker($request);
            if (method_exists($app, 'dispatch_envelope')) {
                return $this->normalizeResponse($app->dispatch_envelope($request));
            }
            return [
                'status' => 500,
                'content_type' => 'application/json',
                'body' => json_encode(['error' => 'VSlim worker dispatch returned no envelope response']),
            ];
        }

        if (method_exists($app, 'dispatch_envelope')) {
            return $this->normalizeResponse($app->dispatch_envelope($request));
        }

        return [
            'status' => 500,
            'content_type' => 'application/json',
            'body' => json_encode(['error' => 'VSlim dispatch method unavailable']),
        ];
    }

    private function normalizeEnvelopeMap(array $map): array
    {
        $headers = [];
        foreach ($map as $key => $value) {
            if (!is_string($key) || !str_starts_with($key, 'headers_')) {
                continue;
            }
            $headerName = str_replace('_', '-', substr($key, 8));
            $headers[$headerName] = (string) $value;
        }

        if (
            !isset($headers['content-type']) &&
            isset($map['content_type']) &&
            is_string($map['content_type'])
        ) {
            $headers['content-type'] = $map['content_type'];
        }

        return [
            'status' => (int) ($map['status'] ?? 500),
            'content_type' => (string) ($map['content_type'] ?? 'text/plain; charset=utf-8'),
            'headers' => $headers,
            'body' => (string) ($map['body'] ?? ''),
        ];
    }

    private function normalizeResponse(object $response): array
    {
        $headers = [];
        if (method_exists($response, 'headers')) {
            $rawHeaders = $response->headers();
            if (is_array($rawHeaders)) {
                foreach ($rawHeaders as $name => $value) {
                    $headers[(string) $name] = (string) $value;
                }
            }
        }

        return [
            'status' => (int) ($response->status ?? 500),
            'content_type' => (string) ($response->content_type ?? 'text/plain; charset=utf-8'),
            'headers' => $headers,
            'body' => (string) ($response->body ?? ''),
        ];
    }

    private function handleFallback(array $request): array
    {
        $path = (string) ($request['path'] ?? '/');
        if ($path === '/') {
            return [
                'status' => 302,
                'headers' => ['location' => '/admin'],
                'body' => '',
            ];
        }
        if ($path === '/health') {
            return [
                'status' => 200,
                'content_type' => 'text/plain; charset=utf-8',
                'body' => 'OK',
            ];
        }
        if ($path === '/admin') {
            return $this->fallbackController()->fallbackResponse($path);
        }

        return [
            'status' => 404,
            'content_type' => 'application/json',
            'body' => json_encode([
                'error' => 'Not Found',
                'path' => $path,
            ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES),
        ];
    }

    private function fallbackController(): DashboardController
    {
        if (!$this->fallbackController instanceof DashboardController) {
            $this->fallbackController = new DashboardController();
        }

        return $this->fallbackController;
    }
}
