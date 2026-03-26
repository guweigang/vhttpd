<?php

declare(strict_types=1);

namespace VPhp\VSlim\Mcp;

use RuntimeException;
use VPhp\VHttpd\Attribute\Dispatchable;

#[Dispatchable('mcp')]
final class App
{
    /** @var array<string,callable> */
    private array $methods = [];
    /** @var array<string,array{name:string,description:string,inputSchema:array<string,mixed>,handler:callable}> */
    private array $tools = [];
    /** @var array<string,array{uri:string,name:string,description:string,mimeType:string,handler:callable}> */
    private array $resources = [];
    /** @var array<string,array{name:string,description:string,arguments:array<int,array<string,mixed>>,handler:callable}> */
    private array $prompts = [];
    /** @var array<string,mixed> */
    private array $serverInfo;
    /** @var array<string,mixed> */
    private array $serverCapabilities;

    /**
     * @param array<string,mixed> $serverInfo
     * @param array<string,mixed> $serverCapabilities
     */
    public function __construct(
        array $serverInfo = ['name' => 'vhttpd-mcp', 'version' => '0.1.0'],
        array $serverCapabilities = [],
    ) {
        $this->serverInfo = $serverInfo;
        $this->serverCapabilities = $serverCapabilities;
    }

    public function register(string $method, callable $handler): self
    {
        $this->methods[$method] = $handler;
        return $this;
    }

    /**
     * @param array<string,mixed> $definition
     */
    public function capability(string $name, array $definition = []): self
    {
        $this->serverCapabilities[$name] = $definition;
        return $this;
    }

    /**
     * @param array<string,mixed> $definitions
     */
    public function capabilities(array $definitions): self
    {
        foreach ($definitions as $name => $definition) {
            if (!is_string($name)) {
                continue;
            }
            $this->serverCapabilities[$name] = is_array($definition) ? $definition : [];
        }
        return $this;
    }

    /**
     * @param array<string,mixed> $params
     */
    public static function notification(string $method, array $params = []): string
    {
        $body = json_encode([
            'jsonrpc' => '2.0',
            'method' => $method,
            'params' => $params,
        ], JSON_UNESCAPED_UNICODE);
        if (!is_string($body)) {
            throw new RuntimeException('Failed to encode MCP notification');
        }
        return $body;
    }

    /**
     * @param array<string,mixed> $params
     */
    public static function request(mixed $id, string $method, array $params = []): string
    {
        $body = json_encode([
            'jsonrpc' => '2.0',
            'id' => $id,
            'method' => $method,
            'params' => $params,
        ], JSON_UNESCAPED_UNICODE);
        if (!is_string($body)) {
            throw new RuntimeException('Failed to encode MCP request');
        }
        return $body;
    }

    /**
     * @param list<array<string,mixed>> $messages
     * @param array<string,mixed> $modelPreferences
     * @param list<array<string,mixed>> $tools
     */
    public static function samplingRequest(
        mixed $id,
        array $messages,
        array $modelPreferences = [],
        string $systemPrompt = '',
        int $maxTokens = 0,
        ?float $temperature = null,
        array $tools = [],
        mixed $toolChoice = null,
    ): string {
        $params = [
            'messages' => array_values($messages),
        ];
        if ($modelPreferences !== []) {
            $params['modelPreferences'] = $modelPreferences;
        }
        if ($systemPrompt !== '') {
            $params['systemPrompt'] = $systemPrompt;
        }
        if ($maxTokens > 0) {
            $params['maxTokens'] = $maxTokens;
        }
        if ($temperature !== null) {
            $params['temperature'] = $temperature;
        }
        if ($tools !== []) {
            $params['tools'] = array_values($tools);
        }
        if ($toolChoice !== null) {
            $params['toolChoice'] = $toolChoice;
        }
        return self::request($id, 'sampling/createMessage', $params);
    }

    /**
     * @param mixed $id
     * @param mixed $result
     * @param list<string> $notifications
     * @return array<string,mixed>
     */
    public static function queuedResult(
        mixed $id,
        mixed $result,
        array $notifications = [],
        int $status = 200,
        string $protocolVersion = '',
        string $sessionId = '',
        array $headers = ['content-type' => 'application/json; charset=utf-8'],
    ): array {
        $body = json_encode([
            'jsonrpc' => '2.0',
            'id' => $id,
            'result' => $result,
        ], JSON_UNESCAPED_UNICODE);
        if (!is_string($body)) {
            throw new RuntimeException('Failed to encode queued MCP result');
        }
        return [
            'handled' => true,
            'status' => $status,
            'headers' => $headers,
            'body' => $body,
            'protocol_version' => $protocolVersion,
            'session_id' => $sessionId,
            'messages' => array_values(array_map('strval', $notifications)),
        ];
    }

    /**
     * @param list<string> $messages
     * @return array<string,mixed>
     */
    public static function queueMessages(
        mixed $id,
        mixed $result,
        array $messages,
        int $status = 200,
        string $protocolVersion = '',
        string $sessionId = '',
        array $headers = ['content-type' => 'application/json; charset=utf-8'],
    ): array {
        return self::queuedResult(
            $id,
            $result,
            $messages,
            $status,
            $protocolVersion,
            $sessionId,
            $headers,
        );
    }

    /**
     * @param array<string,mixed> $params
     * @return array<string,mixed>
     */
    public static function notify(
        mixed $id,
        string $method,
        array $params = [],
        string $sessionId = '',
        string $protocolVersion = '',
        mixed $result = ['queued' => true],
        int $status = 200,
        array $headers = ['content-type' => 'application/json; charset=utf-8'],
    ): array {
        return self::queuedResult(
            $id,
            $result,
            [self::notification($method, $params)],
            $status,
            $protocolVersion,
            $sessionId,
            $headers,
        );
    }

    /**
     * @param array<string,mixed> $params
     * @return array<string,mixed>
     */
    public static function queueNotification(
        mixed $id,
        string $method,
        array $params = [],
        string $sessionId = '',
        string $protocolVersion = '',
        mixed $result = ['queued' => true],
        int $status = 200,
        array $headers = ['content-type' => 'application/json; charset=utf-8'],
    ): array {
        return self::notify(
            $id,
            $method,
            $params,
            $sessionId,
            $protocolVersion,
            $result,
            $status,
            $headers,
        );
    }

    /**
     * @param array<string,mixed> $params
     * @return array<string,mixed>
     */
    public static function queueRequest(
        mixed $responseId,
        mixed $requestId,
        string $method,
        array $params = [],
        string $sessionId = '',
        string $protocolVersion = '',
        mixed $result = ['queued' => true],
        int $status = 200,
        array $headers = ['content-type' => 'application/json; charset=utf-8'],
    ): array {
        return self::queuedResult(
            $responseId,
            $result,
            [self::request($requestId, $method, $params)],
            $status,
            $protocolVersion,
            $sessionId,
            $headers,
        );
    }

    /**
     * @return array<string,mixed>
     */
    public static function queueProgress(
        mixed $id,
        string|int $progressToken,
        float|int $progress,
        ?float $total = null,
        string $message = '',
        string $sessionId = '',
        string $protocolVersion = '',
        mixed $result = ['queued' => true],
        int $status = 200,
        array $headers = ['content-type' => 'application/json; charset=utf-8'],
    ): array {
        $params = [
            'progressToken' => $progressToken,
            'progress' => $progress,
        ];
        if ($total !== null) {
            $params['total'] = $total;
        }
        if ($message !== '') {
            $params['message'] = $message;
        }
        return self::queueNotification(
            $id,
            'notifications/progress',
            $params,
            $sessionId,
            $protocolVersion,
            $result,
            $status,
            $headers,
        );
    }

    /**
     * @param array<string,mixed> $data
     * @return array<string,mixed>
     */
    public static function queueLog(
        mixed $id,
        string $level,
        string $message,
        array $data = [],
        string $logger = '',
        string $sessionId = '',
        string $protocolVersion = '',
        mixed $result = ['queued' => true],
        int $status = 200,
        array $headers = ['content-type' => 'application/json; charset=utf-8'],
    ): array {
        $params = [
            'level' => $level,
            'data' => $data !== [] ? $data : ['message' => $message],
        ];
        if ($logger !== '') {
            $params['logger'] = $logger;
        }
        if ($message !== '' && $data !== []) {
            $params['message'] = $message;
        }
        return self::queueNotification(
            $id,
            'notifications/message',
            $params,
            $sessionId,
            $protocolVersion,
            $result,
            $status,
            $headers,
        );
    }

    /**
     * @param list<array<string,mixed>> $messages
     * @param array<string,mixed> $modelPreferences
     * @param list<array<string,mixed>> $tools
     * @return array<string,mixed>
     */
    public static function queueSampling(
        mixed $responseId,
        mixed $samplingId,
        array $messages,
        string $sessionId = '',
        string $protocolVersion = '',
        array $modelPreferences = [],
        string $systemPrompt = '',
        int $maxTokens = 0,
        ?float $temperature = null,
        array $tools = [],
        mixed $toolChoice = null,
        mixed $result = ['queued' => true],
        int $status = 200,
        array $headers = ['content-type' => 'application/json; charset=utf-8'],
    ): array {
        return self::queuedResult(
            $responseId,
            $result,
            [
                self::samplingRequest(
                    $samplingId,
                    $messages,
                    $modelPreferences,
                    $systemPrompt,
                    $maxTokens,
                    $temperature,
                    $tools,
                    $toolChoice,
                ),
            ],
            $status,
            $protocolVersion,
            $sessionId,
            $headers,
        );
    }

    /**
     * @param array<string,mixed> $inputSchema
     */
    public function tool(string $name, string $description, array $inputSchema, callable $handler): self
    {
        $this->tools[$name] = [
            'name' => $name,
            'description' => $description,
            'inputSchema' => $inputSchema,
            'handler' => $handler,
        ];
        return $this;
    }

    public function resource(string $uri, string $name, string $description, string $mimeType, callable $handler): self
    {
        $this->resources[$uri] = [
            'uri' => $uri,
            'name' => $name,
            'description' => $description,
            'mimeType' => $mimeType,
            'handler' => $handler,
        ];
        return $this;
    }

    /**
     * @param array<int,array<string,mixed>> $arguments
     */
    public function prompt(string $name, string $description, array $arguments, callable $handler): self
    {
        $this->prompts[$name] = [
            'name' => $name,
            'description' => $description,
            'arguments' => $arguments,
            'handler' => $handler,
        ];
        return $this;
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    public function handle(array $frame): array
    {
        return $this->handle_mcp($frame);
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    public function handle_mcp(array $frame): array
    {
        $protocolVersion = (string) ($frame['protocol_version'] ?? '');
        $raw = (string) ($frame['jsonrpc_raw'] ?? '');
        if ($raw === '') {
            return $this->errorResponse(null, -32700, 'Missing JSON-RPC body', 400, $protocolVersion);
        }

        $message = json_decode($raw, true);
        if (!is_array($message)) {
            return $this->errorResponse(null, -32700, 'Invalid JSON', 400, $protocolVersion);
        }

        $jsonrpc = (string) ($message['jsonrpc'] ?? '');
        if ($jsonrpc !== '2.0') {
            return $this->errorResponse($message['id'] ?? null, -32600, 'Invalid JSON-RPC version', 400, $protocolVersion);
        }

        $method = (string) ($message['method'] ?? '');
        if ($method === '') {
            return $this->errorResponse($message['id'] ?? null, -32600, 'Missing method', 400, $protocolVersion);
        }

        if ($method === 'initialize') {
            $params = is_array($message['params'] ?? null) ? $message['params'] : [];
            $clientVersion = (string) ($params['protocolVersion'] ?? $protocolVersion);
            return $this->resultResponse(
                $message['id'] ?? null,
                [
                    'protocolVersion' => $clientVersion !== '' ? $clientVersion : '2025-11-05',
                    'capabilities' => $this->effectiveCapabilities(),
                    'serverInfo' => $this->serverInfo,
                ],
                200,
                $clientVersion !== '' ? $clientVersion : $protocolVersion,
            );
        }

        if ($method === 'ping') {
            return $this->resultResponse($message['id'] ?? null, [], 200, $protocolVersion);
        }

        if ($method === 'tools/list' && !isset($this->methods[$method])) {
            return $this->resultResponse(
                $message['id'] ?? null,
                ['tools' => $this->toolDefinitions()],
                200,
                $protocolVersion,
            );
        }

        if ($method === 'tools/call' && !isset($this->methods[$method])) {
            return $this->handleBuiltinToolCall($message, $frame, $protocolVersion);
        }

        if ($method === 'resources/list' && !isset($this->methods[$method])) {
            return $this->resultResponse(
                $message['id'] ?? null,
                ['resources' => $this->resourceDefinitions()],
                200,
                $protocolVersion,
            );
        }

        if ($method === 'resources/read' && !isset($this->methods[$method])) {
            return $this->handleBuiltinResourceRead($message, $frame, $protocolVersion);
        }

        if ($method === 'prompts/list' && !isset($this->methods[$method])) {
            return $this->resultResponse(
                $message['id'] ?? null,
                ['prompts' => $this->promptDefinitions()],
                200,
                $protocolVersion,
            );
        }

        if ($method === 'prompts/get' && !isset($this->methods[$method])) {
            return $this->handleBuiltinPromptGet($message, $frame, $protocolVersion);
        }

        $handler = $this->methods[$method] ?? null;
        if ($handler === null) {
            return $this->errorResponse($message['id'] ?? null, -32601, 'Method not found', 200, $protocolVersion);
        }

        $result = $handler($message, $frame);
        if (is_array($result) && array_key_exists('body', $result)) {
            $headers = isset($result['headers']) && is_array($result['headers']) ? $result['headers'] : [];
            return [
                'handled' => true,
                'status' => (int) ($result['status'] ?? 200),
                'headers' => $headers,
                'body' => (string) ($result['body'] ?? ''),
                'protocol_version' => (string) ($result['protocol_version'] ?? $protocolVersion),
                'session_id' => (string) ($result['session_id'] ?? ''),
                'messages' => isset($result['messages']) && is_array($result['messages']) ? array_values(array_map('strval', $result['messages'])) : [],
            ];
        }

        return $this->resultResponse($message['id'] ?? null, $result, 200, $protocolVersion);
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    public function handleMcp(array $frame): array
    {
        return $this->handle_mcp($frame);
    }

    /**
     * @return array<string,mixed>
     */
    private function effectiveCapabilities(): array
    {
        $capabilities = $this->serverCapabilities;
        if ($this->tools !== [] && !isset($capabilities['tools'])) {
            $capabilities['tools'] = ['listChanged' => false];
        }
        if ($this->resources !== [] && !isset($capabilities['resources'])) {
            $capabilities['resources'] = ['listChanged' => false];
        }
        if ($this->prompts !== [] && !isset($capabilities['prompts'])) {
            $capabilities['prompts'] = ['listChanged' => false];
        }
        return $capabilities;
    }

    /**
     * @return list<array{name:string,description:string,inputSchema:array<string,mixed>}>
     */
    private function toolDefinitions(): array
    {
        $tools = [];
        foreach ($this->tools as $tool) {
            $tools[] = [
                'name' => $tool['name'],
                'description' => $tool['description'],
                'inputSchema' => $tool['inputSchema'],
            ];
        }
        return array_values($tools);
    }

    /**
     * @return list<array{uri:string,name:string,description:string,mimeType:string}>
     */
    private function resourceDefinitions(): array
    {
        $resources = [];
        foreach ($this->resources as $resource) {
            $resources[] = [
                'uri' => $resource['uri'],
                'name' => $resource['name'],
                'description' => $resource['description'],
                'mimeType' => $resource['mimeType'],
            ];
        }
        return array_values($resources);
    }

    /**
     * @return list<array{name:string,description:string,arguments:array<int,array<string,mixed>>}>
     */
    private function promptDefinitions(): array
    {
        $prompts = [];
        foreach ($this->prompts as $prompt) {
            $prompts[] = [
                'name' => $prompt['name'],
                'description' => $prompt['description'],
                'arguments' => $prompt['arguments'],
            ];
        }
        return array_values($prompts);
    }

    /**
     * @param array<string,mixed> $message
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    private function handleBuiltinToolCall(array $message, array $frame, string $protocolVersion): array
    {
        $params = is_array($message['params'] ?? null) ? $message['params'] : [];
        $name = (string) ($params['name'] ?? '');
        $arguments = is_array($params['arguments'] ?? null) ? $params['arguments'] : [];
        if ($name === '' || !isset($this->tools[$name])) {
            return $this->resultResponse(
                $message['id'] ?? null,
                [
                    'content' => [
                        ['type' => 'text', 'text' => 'unknown tool'],
                    ],
                    'isError' => true,
                ],
                200,
                $protocolVersion,
            );
        }
        $handler = $this->tools[$name]['handler'];
        $result = $handler($arguments, $message, $frame);
        $commands = [];
        if (is_array($result) && array_key_exists('commands', $result)) {
            $commands = is_array($result['commands']) ? array_values($result['commands']) : [];
            if (array_key_exists('result', $result)) {
                $result = $result['result'];
            } else {
                unset($result['commands']);
            }
        }
        return $this->resultResponse($message['id'] ?? null, $result, 200, $protocolVersion, $commands);
    }

    /**
     * @param array<string,mixed> $message
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    private function handleBuiltinResourceRead(array $message, array $frame, string $protocolVersion): array
    {
        $params = is_array($message['params'] ?? null) ? $message['params'] : [];
        $uri = (string) ($params['uri'] ?? '');
        if ($uri === '' || !isset($this->resources[$uri])) {
            return $this->errorResponse($message['id'] ?? null, -32002, 'Resource not found', 200, $protocolVersion);
        }
        $resource = $this->resources[$uri];
        $handler = $resource['handler'];
        $result = $handler($params, $message, $frame);
        if (is_string($result)) {
            $result = [
                'contents' => [[
                    'uri' => $resource['uri'],
                    'mimeType' => $resource['mimeType'],
                    'text' => $result,
                ]],
            ];
        }
        return $this->resultResponse($message['id'] ?? null, $result, 200, $protocolVersion);
    }

    /**
     * @param array<string,mixed> $message
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    private function handleBuiltinPromptGet(array $message, array $frame, string $protocolVersion): array
    {
        $params = is_array($message['params'] ?? null) ? $message['params'] : [];
        $name = (string) ($params['name'] ?? '');
        $arguments = is_array($params['arguments'] ?? null) ? $params['arguments'] : [];
        if ($name === '' || !isset($this->prompts[$name])) {
            return $this->errorResponse($message['id'] ?? null, -32003, 'Prompt not found', 200, $protocolVersion);
        }
        $prompt = $this->prompts[$name];
        $handler = $prompt['handler'];
        $result = $handler($arguments, $message, $frame);
        return $this->resultResponse($message['id'] ?? null, $result, 200, $protocolVersion);
    }

    /**
     * @param mixed $id
     * @param mixed $result
     * @return array<string,mixed>
     */
    private function resultResponse(
        mixed $id,
        mixed $result,
        int $status,
        string $protocolVersion,
        array $commands = [],
    ): array
    {
        $body = json_encode([
            'jsonrpc' => '2.0',
            'id' => $id,
            'result' => $result,
        ], JSON_UNESCAPED_UNICODE);
        if (!is_string($body)) {
            throw new RuntimeException('Failed to encode JSON-RPC result');
        }
        return [
            'handled' => true,
            'status' => $status,
            'headers' => [
                'content-type' => 'application/json; charset=utf-8',
            ],
            'body' => $body,
            'protocol_version' => $protocolVersion,
            'session_id' => '',
            'messages' => [],
            'commands' => array_values($commands),
        ];
    }

    /**
     * @param mixed $id
     * @return array<string,mixed>
     */
    private function errorResponse(mixed $id, int $code, string $message, int $status, string $protocolVersion): array
    {
        $body = json_encode([
            'jsonrpc' => '2.0',
            'id' => $id,
            'error' => [
                'code' => $code,
                'message' => $message,
            ],
        ], JSON_UNESCAPED_UNICODE);
        if (!is_string($body)) {
            throw new RuntimeException('Failed to encode JSON-RPC error');
        }
        return [
            'handled' => true,
            'status' => $status,
            'headers' => [
                'content-type' => 'application/json; charset=utf-8',
            ],
            'body' => $body,
            'protocol_version' => $protocolVersion,
            'session_id' => '',
            'messages' => [],
        ];
    }
}
