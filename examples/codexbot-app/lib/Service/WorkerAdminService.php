<?php

declare(strict_types=1);

namespace CodexBot\Service;

final class WorkerAdminService
{
    public function status(): array
    {
        $fixture = getenv('VHTTPD_ADMIN_STATUS_FIXTURE_JSON');
        if (is_string($fixture) && trim($fixture) !== '') {
            $decoded = json_decode($fixture, true);
            if (is_array($decoded)) {
                return ['ok' => true, 'data' => $decoded];
            }
        }

        return $this->request('GET', '/admin/workers');
    }

    public function restartAll(): array
    {
        $fixture = getenv('VHTTPD_ADMIN_RESTART_ALL_FIXTURE_JSON');
        if (is_string($fixture) && trim($fixture) !== '') {
            $decoded = json_decode($fixture, true);
            if (is_array($decoded)) {
                return ['ok' => true, 'data' => $decoded];
            }
        }

        return $this->request('POST', '/admin/workers/restart/all');
    }

    private function request(string $method, string $path): array
    {
        $baseUrl = rtrim((string) getenv('VHTTPD_ADMIN_BASE_URL'), '/');
        if ($baseUrl === '') {
            $baseUrl = 'http://127.0.0.1:19981';
        }

        $headers = [
            'Accept: application/json',
        ];
        $token = trim((string) getenv('VHTTPD_ADMIN_TOKEN'));
        if ($token !== '') {
            $headers[] = 'x-vhttpd-admin-token: ' . $token;
        }

        $context = stream_context_create([
            'http' => [
                'method' => $method,
                'timeout' => 2.0,
                'ignore_errors' => true,
                'header' => implode("\r\n", $headers) . "\r\n",
            ],
        ]);

        $raw = @file_get_contents($baseUrl . $path, false, $context);
        $responseHeaders = function_exists('http_get_last_response_headers')
            ? (http_get_last_response_headers() ?: [])
            : [];
        $status = $this->extractStatusCode($responseHeaders);

        if (!is_string($raw)) {
            return [
                'ok' => false,
                'error' => '无法连接 vhttpd admin 控制面',
                'status' => $status,
            ];
        }

        $decoded = json_decode($raw, true);
        if (!is_array($decoded)) {
            return [
                'ok' => false,
                'error' => 'admin 接口返回了非 JSON 响应',
                'status' => $status,
                'body' => $raw,
            ];
        }

        if ($status >= 400) {
            return [
                'ok' => false,
                'error' => trim((string) ($decoded['error'] ?? ('admin 请求失败，HTTP ' . $status))),
                'status' => $status,
                'data' => $decoded,
            ];
        }

        return [
            'ok' => true,
            'data' => $decoded,
            'status' => $status,
        ];
    }

    private function extractStatusCode(array $responseHeaders): int
    {
        $statusLine = (string) ($responseHeaders[0] ?? '');
        if (preg_match('/\s(\d{3})(?:\s|$)/', $statusLine, $matches)) {
            return (int) $matches[1];
        }

        return 0;
    }
}
