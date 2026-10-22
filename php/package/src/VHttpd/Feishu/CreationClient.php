<?php
declare(strict_types=1);
namespace VHttpd\Feishu;

final class CreationClient
{
    private readonly \Closure $transport;
    public function __construct(private readonly string $baseUrl, private readonly string $adminToken, ?callable $transport = null)
    {
        $url = parse_url($baseUrl);
        if (!is_array($url) || !in_array($url['scheme'] ?? '', ['http', 'https'], true)
            || empty($url['host']) || isset($url['user']) || isset($url['pass']) || isset($url['query']) || isset($url['fragment'])
            || trim($adminToken) === '' || strpbrk($adminToken, "\r\n") !== false) {
            throw new \InvalidArgumentException('Explicit admin URL and header token are required');
        }
        $this->transport = $transport === null ? $this->http(...) : \Closure::fromCallable($transport);
    }
    public static function fromEnvironment(): self
    {
        return new self((string) getenv('VHTTPD_ADMIN_BASE_URL'), (string) getenv('VHTTPD_ADMIN_TOKEN'));
    }
    public function issue(string $streamId, string $instance = 'main', string $messageId = ''): CreationLease
    {
        if (trim($streamId) === '') throw new \InvalidArgumentException('Stream ID is required');
        $discovery = $this->request('GET', '/admin/runtime/feishu/creation');
        if (!is_string($discovery['epoch'] ?? null) || !preg_match('/^[a-f0-9]{64}$/D', $discovery['epoch']) || !is_int($discovery['issued_at'] ?? null)) {
            throw new \UnexpectedValueException('Invalid creation discovery');
        }
        $request = ['epoch' => $discovery['epoch'], 'issued_at' => $discovery['issued_at'],
            'request_id' => bin2hex(random_bytes(32)), 'stream_id' => $streamId, 'instance' => $instance,
            'kind' => $messageId === '' ? 'send' : 'bind', 'message_id' => $messageId];
        try {
            $reply = $this->request('POST', '/admin/runtime/feishu/creation', $request);
            if (!is_string($reply['generation'] ?? null) || !is_string($reply['token'] ?? null)) {
                throw new \UnexpectedValueException('Invalid creation credentials');
            }
            return new CreationLease($request, $reply['generation'], $reply['token']);
        } catch (\Throwable $error) {
            // The server may have issued a grant even when its response was lost.
            // Revoke the captured intent, including before a delayed issue arrives.
            // Never retry issuance or replace the original failure with cleanup failure.
            try { $this->request('POST', '/admin/runtime/feishu/creation/revoke', $request); }
            catch (\Throwable) { /* Unreachable grants remain bounded by server expiry. */ }
            throw $error;
        }
    }
    public function revoke(CreationLease $lease): void
    {
        $this->request('POST', '/admin/runtime/feishu/creation/revoke', $lease->request);
    }
    private function request(string $method, string $path, ?array $body = null): array
    {
        // No redirect, retry, implicit renewal, or token acquisition at command serialization.
        $response = ($this->transport)($method, rtrim($this->baseUrl, '/') . $path,
            ['Accept: application/json', 'Content-Type: application/json', 'x-vhttpd-admin-token: ' . $this->adminToken],
            $body === null ? null : json_encode($body, JSON_THROW_ON_ERROR));
        if (($response['status'] ?? 0) !== 200) throw new \RuntimeException('Feishu creation request failed, HTTP ' . ($response['status'] ?? 0));
        $decoded = json_decode((string) ($response['body'] ?? ''), true, flags: JSON_THROW_ON_ERROR);
        if (!is_array($decoded)) throw new \UnexpectedValueException('Invalid creation response');
        return $decoded;
    }
    private function http(string $method, string $url, array $headers, ?string $body): array
    {
        $context = stream_context_create(['http' => ['method' => $method, 'header' => implode("\r\n", $headers),
            'content' => $body ?? '', 'timeout' => 5.0, 'ignore_errors' => true, 'follow_location' => 0, 'max_redirects' => 0]]);
        $raw = @file_get_contents($url, false, $context);
        $headers = function_exists('http_get_last_response_headers') ? http_get_last_response_headers() : ($http_response_header ?? []);
        preg_match('/\s(\d{3})(?:\s|$)/', (string) ($headers[0] ?? ''), $match);
        return ['status' => (int) ($match[1] ?? 0), 'body' => is_string($raw) ? $raw : ''];
    }
}
