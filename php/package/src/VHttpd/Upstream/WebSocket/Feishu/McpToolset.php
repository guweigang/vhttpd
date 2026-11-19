<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu;

use VHttpd\AdminClient;
use VSlim\Mcp\App;

final class McpToolset
{
    public static function register(App $app): App
    {
        $app->tool('feishu.list_chats', 'List chats seen by the Feishu runtime', [
            'type' => 'object',
            'properties' => [
                'instance' => ['type' => 'string'],
                'chat_type' => ['type' => 'string'],
                'chat_id' => ['type' => 'string'],
                'limit' => ['type' => 'integer'],
                'offset' => ['type' => 'integer'],
            ],
        ], static function (array $arguments): array {
            $query = [];
            foreach (['instance', 'chat_type', 'chat_id', 'limit', 'offset'] as $key) {
                if (isset($arguments[$key]) && is_scalar($arguments[$key])) {
                    $query[$key] = (string) $arguments[$key];
                }
            }
            $body = AdminClient::fromEnvironment()->get('/runtime/feishu/chats', $query);
            $chats = is_array($body['chats'] ?? null) ? $body['chats'] : [];
            $count = count($chats);
            return [
                'content' => [['type' => 'text', 'text' => "found {$count} feishu chat(s)"]],
                'chats' => $chats,
                'count' => $count,
            ];
        });

        return $app->tool('feishu.send_text', 'Queue a text message to a Feishu chat', [
            'type' => 'object',
            'properties' => [
                'chat_id' => ['type' => 'string'],
                'text' => ['type' => 'string'],
                'instance' => ['type' => 'string'],
            ],
            'required' => ['chat_id', 'text'],
        ], static function (array $arguments): array {
            $chat = trim((string) ($arguments['chat_id'] ?? ''));
            $text = (string) ($arguments['text'] ?? '');
            if ($chat === '' || trim($text) === '') {
                return ['isError' => true, 'content' => [['type' => 'text', 'text' => 'chat_id and text are required']]];
            }
            return [
                'content' => [['type' => 'text', 'text' => 'queued feishu text message']],
                'commands' => [Command::sendText($chat, $text, (string) ($arguments['instance'] ?? 'main'))->toArray()],
            ];
        });
    }
}
