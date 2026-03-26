<?php

declare(strict_types=1);

namespace VPhp\VSlim\Stream;

use VPhp\VHttpd\Upstream\Plan;

final class OllamaClient
{
    public function __construct(
        private readonly string $chatUrl = '',
        private readonly string $defaultModel = '',
        private readonly string $apiKey = '',
        private readonly string $fixturePath = '',
    ) {
    }

    public static function fromEnv(): self
    {
        return new self(
            (string) (getenv('OLLAMA_CHAT_URL') ?: 'http://127.0.0.1:11434/api/chat'),
            (string) (getenv('OLLAMA_MODEL') ?: 'qwen2.5:7b-instruct'),
            trim((string) (getenv('OLLAMA_API_KEY') ?: '')),
            trim((string) (getenv('OLLAMA_STREAM_FIXTURE') ?: '')),
        );
    }

    /**
     * @param array<string,mixed> $overrides
     */
    public static function fromOptions(array $overrides = []): self
    {
        $base = self::fromEnv();
        return new self(
            (string) ($overrides['chat_url'] ?? $base->chatUrl()),
            (string) ($overrides['model'] ?? $base->defaultModel()),
            trim((string) ($overrides['api_key'] ?? $base->apiKey())),
            trim((string) ($overrides['fixture'] ?? $base->fixturePath())),
        );
    }

    public function chatUrl(): string
    {
        return $this->chatUrl !== '' ? $this->chatUrl : 'http://127.0.0.1:11434/api/chat';
    }

    public function defaultModel(): string
    {
        return $this->defaultModel !== '' ? $this->defaultModel : 'qwen2.5:7b-instruct';
    }

    public function apiKey(): string
    {
        return $this->apiKey;
    }

    public function fixturePath(): string
    {
        return $this->fixturePath;
    }

    /**
     * @return array{
     *   prompt:string,
     *   model:string,
     *   messages:array<int,array<string,string>>
     * }
     */
    public function payloadFromRequest(\VSlim\Request $req): array
    {
        return $this->payload([
            'query' => $req->query_params(),
            'body' => $req->body,
        ]);
    }

    /**
     * @param array<string,mixed> $req
     * @return array{
     *   prompt:string,
     *   model:string,
     *   messages:array<int,array<string,string>>
     * }
     */
    public function payload(array $req): array
    {
        $jsonBody = json_decode((string) ($req['body'] ?? ''), true);
        if (!is_array($jsonBody)) {
            $jsonBody = [];
        }

        $query = is_array($req['query'] ?? null) ? $req['query'] : [];
        $prompt = trim((string) ($query['prompt'] ?? ($jsonBody['prompt'] ?? 'Explain VSlim streaming in one paragraph.')));
        $model = trim((string) ($query['model'] ?? ($jsonBody['model'] ?? $this->defaultModel())));
        $messages = $jsonBody['messages'] ?? null;

        if (!is_array($messages) || $messages === []) {
            $messages = [];
            $system = trim((string) ($jsonBody['system'] ?? ''));
            if ($system !== '') {
                $messages[] = [
                    'role' => 'system',
                    'content' => $system,
                ];
            }
            $messages[] = [
                'role' => 'user',
                'content' => $prompt,
            ];
        }

        $normalized = [];
        foreach ($messages as $message) {
            if (!is_array($message)) {
                continue;
            }
            $role = trim((string) ($message['role'] ?? 'user'));
            $content = (string) ($message['content'] ?? '');
            if ($content === '') {
                continue;
            }
            $normalized[] = [
                'role' => $role === '' ? 'user' : $role,
                'content' => $content,
            ];
        }

        if ($normalized === []) {
            $normalized[] = [
                'role' => 'user',
                'content' => $prompt,
            ];
        }

        return [
            'prompt' => $prompt,
            'model' => $model !== '' ? $model : $this->defaultModel(),
            'messages' => $normalized,
        ];
    }

    /**
     * @param array{
     *   prompt:string,
     *   model:string,
     *   messages:array<int,array<string,string>>
     * } $payload
     * @return array{
     *   ok:bool,
     *   stream:resource|null,
     *   error:string,
     *   status:int,
     *   url:string
     * }
     */
    public function openStream(array $payload): array
    {
        if ($this->fixturePath() !== '') {
            $fp = @fopen($this->fixturePath(), 'r');
            if (is_resource($fp)) {
                return [
                    'ok' => true,
                    'stream' => $fp,
                    'error' => '',
                    'status' => 200,
                    'url' => 'fixture://' . $this->fixturePath(),
                ];
            }
            return [
                'ok' => false,
                'stream' => null,
                'error' => 'failed to open stream fixture: ' . $this->fixturePath(),
                'status' => 500,
                'url' => 'fixture://' . $this->fixturePath(),
            ];
        }

        $requestBody = json_encode([
            'model' => $payload['model'],
            'stream' => true,
            'messages' => $payload['messages'],
        ], JSON_UNESCAPED_UNICODE);

        if (!is_string($requestBody)) {
            return [
                'ok' => false,
                'stream' => null,
                'error' => 'failed to encode request payload',
                'status' => 500,
                'url' => $this->chatUrl(),
            ];
        }

        $headers = [
            'Content-Type: application/json',
            'Accept: application/x-ndjson',
        ];
        if ($this->apiKey() !== '') {
            $headers[] = 'Authorization: Bearer ' . $this->apiKey();
        }

        $ctx = stream_context_create([
            'http' => [
                'method' => 'POST',
                'header' => implode("\r\n", $headers) . "\r\n",
                'content' => $requestBody,
                'timeout' => 300,
                'ignore_errors' => true,
            ],
        ]);

        $fp = @fopen($this->chatUrl(), 'r', false, $ctx);
        if (!is_resource($fp)) {
            return [
                'ok' => false,
                'stream' => null,
                'error' => 'failed to open upstream stream: ' . $this->chatUrl(),
                'status' => 502,
                'url' => $this->chatUrl(),
            ];
        }

        $respHeaders = function_exists('http_get_last_response_headers')
            ? (http_get_last_response_headers() ?: [])
            : [];
        $status = 200;
        if (isset($respHeaders[0]) && preg_match('/\s(\d{3})\s/', (string) $respHeaders[0], $m) === 1) {
            $status = (int) $m[1];
        }

        if ($status < 200 || $status >= 300) {
            $error = trim((string) stream_get_contents($fp));
            fclose($fp);
            return [
                'ok' => false,
                'stream' => null,
                'error' => $error !== '' ? $error : ('upstream status ' . $status),
                'status' => $status,
                'url' => $this->chatUrl(),
            ];
        }

        return [
            'ok' => true,
            'stream' => $fp,
            'error' => '',
            'status' => $status,
            'url' => $this->chatUrl(),
        ];
    }

    public function textResponseFromRequest(\VSlim\Request $req): \VPhp\VSlim\Stream\Response|array
    {
        return $this->responseFromRequest('text', $req);
    }

    public function sseResponseFromRequest(\VSlim\Request $req): \VPhp\VSlim\Stream\Response|array
    {
        return $this->responseFromRequest('sse', $req);
    }

    public function upstreamTextPlanFromRequest(\VSlim\Request $req): Plan
    {
        return $this->upstreamPlanFromRequest($req, 'text');
    }

    public function upstreamSsePlanFromRequest(\VSlim\Request $req): Plan
    {
        return $this->upstreamPlanFromRequest($req, 'sse');
    }

    public function upstreamPlanFromRequest(\VSlim\Request $req, string $outputMode = 'sse'): Plan
    {
        return $this->upstreamPlan($this->payloadFromRequest($req), $outputMode);
    }

    /**
     * @param array{
     *   prompt:string,
     *   model:string,
     *   messages:array<int,array<string,string>>
     * } $payload
     */
    public function upstreamPlan(array $payload, string $outputMode = 'sse'): Plan
    {
        $mode = strtolower(trim($outputMode)) === 'text' ? 'text' : 'sse';
        $requestBody = json_encode([
            'model' => $payload['model'],
            'stream' => true,
            'messages' => $payload['messages'],
        ], JSON_UNESCAPED_UNICODE);
        if (!is_string($requestBody)) {
            $requestBody = '';
        }

        $requestHeaders = [
            'content-type' => 'application/json',
            'accept' => 'application/x-ndjson',
        ];
        if ($this->apiKey() !== '') {
            $requestHeaders['authorization'] = 'Bearer ' . $this->apiKey();
        }

        return Plan::http(
            url: $this->chatUrl(),
            method: 'POST',
            requestHeaders: $requestHeaders,
            body: $requestBody,
            codec: 'ndjson',
            mapper: $mode === 'text' ? 'ndjson_text_field' : 'ndjson_sse_field',
            outputStreamType: $mode,
            outputContentType: $mode === 'text' ? 'text/plain; charset=utf-8' : 'text/event-stream',
            responseHeaders: [
                'x-ollama-model' => $payload['model'],
                'x-ollama-url' => $this->chatUrl(),
            ],
            fixturePath: $this->fixturePath(),
            name: 'ollama_chat',
            meta: [
                'provider' => 'ollama',
                'model' => $payload['model'],
                'prompt' => $payload['prompt'],
                'field_path' => 'message.content',
                'fallback_field_path' => 'response',
                'sse_event' => 'token',
            ],
        );
    }

    public function responseFromRequest(string $mode, \VSlim\Request $req): \VPhp\VSlim\Stream\Response|array
    {
        $payload = $this->payloadFromRequest($req);
        $opened = $this->openStream($payload);
        if (!$opened['ok'] || !is_resource($opened['stream'])) {
            return [
                'status' => $opened['status'],
                'content_type' => 'application/json; charset=utf-8',
                'body' => json_encode([
                    'error' => 'ollama_upstream_failed',
                    'message' => $opened['error'],
                    'url' => $opened['url'],
                ], JSON_UNESCAPED_UNICODE),
            ];
        }

        $headers = [
            'x-ollama-model' => $payload['model'],
            'x-ollama-url' => $opened['url'],
        ];
        if (strtolower($mode) === 'text') {
            return Response::textWith(
                $this->textChunks($opened['stream']),
                200,
                'text/plain; charset=utf-8',
                $headers,
            );
        }
        return Response::sseWith(
            SseEncoder::fromOllama(NdjsonDecoder::decode($opened['stream']), $payload['model']),
            200,
            $headers,
        );
    }

    /**
     * @param resource $stream
     * @return \Generator<int,string>
     */
    public function textChunks($stream): \Generator
    {
        foreach (NdjsonDecoder::decode($stream) as $row) {
            $piece = (string) ($row['message']['content'] ?? ($row['response'] ?? ''));
            if ($piece !== '') {
                yield $piece;
            }
        }
    }
}
