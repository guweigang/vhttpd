<?php

declare(strict_types=1);

namespace VPhp\VSlim\App\Feishu;

use VPhp\VHttpd\Upstream\WebSocket\Feishu\Event;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Event\CardActionEvent;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\AudioMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\FileMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\ImageMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\MediaMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\PostMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\StickerMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\TextMessage;

final class BotAdapter
{
    /**
     * @param array<string,mixed> $frame
     */
    public static function parseEventObject(array $frame): ?Event
    {
        $event = self::parseEvent($frame);
        if ($event === null) {
            return null;
        }

        return Event::fromArray($event);
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>|null
     */
    public static function parseEvent(array $frame): ?array
    {
        if (!in_array((string) ($frame['event'] ?? ''), ['message', 'action', 'event'], true)) {
            return null;
        }

        $payload = is_string($frame['payload'] ?? null) ? $frame['payload'] : '';
        if ($payload === '') {
            return null;
        }

        $decoded = json_decode($payload, true);
        if (!is_array($decoded)) {
            return null;
        }

        $eventType = (string) ($frame['event_type'] ?? ($decoded['header']['event_type'] ?? ''));
        if ($eventType === '') {
            return null;
        }

        $message = is_array($decoded['event']['message'] ?? null) ? $decoded['event']['message'] : [];
        $action = is_array($decoded['event']['action'] ?? null) ? $decoded['event']['action'] : [];
        $messageType = (string) ($message['message_type'] ?? '');
        $contentRaw = is_string($message['content'] ?? null) ? $message['content'] : '';
        $content = $messageType !== '' ? self::decodeMessageContent($messageType, $contentRaw) : null;

        $metadata = is_array($frame['metadata'] ?? null) ? $frame['metadata'] : [];
        $chatType = (string) ($metadata['chat_type'] ?? ($message['chat_type'] ?? ''));
        $rootId = (string) ($metadata['root_id'] ?? ($message['root_id'] ?? ''));
        $parentId = (string) ($metadata['parent_id'] ?? ($message['parent_id'] ?? ''));
        $createTime = (string) ($metadata['create_time'] ?? ($message['create_time'] ?? ''));
        $senderId = (string) ($metadata['sender_id'] ?? '');
        $senderIdType = (string) ($metadata['sender_id_type'] ?? '');
        $senderTenantKey = (string) ($metadata['sender_tenant_key'] ?? '');
        $openMessageId = (string) ($metadata['open_message_id'] ?? ($decoded['event']['open_message_id'] ?? ($action['open_message_id'] ?? '')));
        $actionTag = (string) ($metadata['action_tag'] ?? ($action['tag'] ?? ''));
        $actionValue = $metadata['action_value'] ?? ($action['value'] ?? '');
        $token = (string) ($metadata['token'] ?? ($decoded['token'] ?? ''));
        $eventId = (string) ($metadata['event_id'] ?? ($decoded['header']['event_id'] ?? ''));
        $eventKind = (string) ($metadata['event_kind'] ?? ($frame['event'] ?? 'event'));
        $targetType = (string) ($frame['target_type'] ?? '');
        $target = (string) ($frame['target'] ?? '');
        if ($target === '' && isset($message['chat_id'])) {
            $targetType = $targetType !== '' ? $targetType : 'chat_id';
            $target = (string) $message['chat_id'];
        }
        if ($target === '' && $openMessageId !== '') {
            $targetType = $targetType !== '' ? $targetType : 'open_message_id';
            $target = $openMessageId;
        }

        return [
            'provider' => (string) ($frame['provider'] ?? 'feishu'),
            'instance' => (string) ($frame['instance'] ?? 'main'),
            'target_type' => $targetType,
            'target' => $target,
            'event_kind' => $eventKind,
            'event_type' => $eventType,
            'event_id' => $eventId,
            'message_id' => (string) ($frame['message_id'] ?? ($message['message_id'] ?? '')),
            'message_type' => $messageType,
            'chat_type' => $chatType,
            'open_message_id' => $openMessageId,
            'root_id' => $rootId,
            'parent_id' => $parentId,
            'create_time' => $createTime,
            'sender_id' => $senderId,
            'sender_id_type' => $senderIdType,
            'sender_tenant_key' => $senderTenantKey,
            'action_tag' => $actionTag,
            'action_value' => $actionValue,
            'token' => $token,
            'content' => $content,
            'payload' => $decoded,
            'metadata' => $metadata,
        ];
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>|null
     */
    public static function parseMessage(array $frame): ?array
    {
        $event = self::parseEvent($frame);
        if ($event === null) {
            return null;
        }

        if (($event['event_type'] ?? '') !== 'im.message.receive_v1') {
            return null;
        }

        if (($event['message_type'] ?? '') === '' || !is_array($event['content'] ?? null)) {
            return null;
        }

        return $event;
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseMessageObject(array $frame): ?Message
    {
        $message = self::parseMessage($frame);
        if ($message === null) {
            return null;
        }

        return Message::fromArray($message);
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>|null
     */
    public static function parseTextMessage(array $frame): ?array
    {
        $message = self::parseMessage($frame);
        if ($message === null) {
            return null;
        }

        if (($message['message_type'] ?? '') !== 'text') {
            return null;
        }

        $content = is_array($message['content'] ?? null) ? $message['content'] : [];
        $text = trim((string) ($content['text'] ?? ''));
        if ($text === '') {
            return null;
        }

        $message['text'] = $text;
        return $message;
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseTextMessageObject(array $frame): ?Message
    {
        $message = self::parseTextMessage($frame);
        if ($message === null) {
            return null;
        }

        return Message::fromArray($message);
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseTypedTextMessageObject(array $frame): ?TextMessage
    {
        $message = self::parseTextMessageObject($frame);
        return $message?->asText();
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseImageMessageObject(array $frame): ?ImageMessage
    {
        $message = self::parseMessageObject($frame);
        return $message?->asImage();
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parsePostMessageObject(array $frame): ?PostMessage
    {
        $message = self::parseMessageObject($frame);
        return $message?->asPost();
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseFileMessageObject(array $frame): ?FileMessage
    {
        $message = self::parseMessageObject($frame);
        return $message?->asFile();
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseAudioMessageObject(array $frame): ?AudioMessage
    {
        $message = self::parseMessageObject($frame);
        return $message?->asAudio();
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseMediaMessageObject(array $frame): ?MediaMessage
    {
        $message = self::parseMessageObject($frame);
        return $message?->asMedia();
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseStickerMessageObject(array $frame): ?StickerMessage
    {
        $message = self::parseMessageObject($frame);
        return $message?->asSticker();
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>|null
     */
    public static function parseCardAction(array $frame): ?array
    {
        $event = self::parseEvent($frame);
        if ($event === null) {
            return null;
        }

        if (($event['event_kind'] ?? '') !== 'action') {
            return null;
        }

        if ((string) ($event['open_message_id'] ?? '') === '') {
            return null;
        }

        return $event;
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseCardActionObject(array $frame): ?Event
    {
        $event = self::parseCardAction($frame);
        if ($event === null) {
            return null;
        }

        return Event::fromArray($event);
    }

    /**
     * @param array<string,mixed> $frame
     */
    public static function parseCardActionEventObject(array $frame): ?CardActionEvent
    {
        $event = self::parseCardActionObject($frame);
        return $event?->asCardAction();
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>|null
     */
    public static function replyTextCommand(array $frame, string $text): ?array
    {
        return self::buildSendCommand($frame, 'text', [
            'text' => $text,
        ]);
    }

    /**
     * @param array<string,mixed> $frame
     * @param array<string,string> $contentFields
     * @return array<string,mixed>|null
     */
    public static function buildSendCommand(
        array $frame,
        string $messageType,
        array $contentFields = [],
        ?string $rawContent = null,
        ?string $uuid = null,
    ): ?array {
        $event = self::parseEvent($frame);
        if ($event === null) {
            return null;
        }

        $target = (string) ($event['target'] ?? '');
        if ($target === '') {
            return null;
        }

        $command = [
            'event' => 'send',
            'provider' => (string) ($event['provider'] ?? 'feishu'),
            'instance' => (string) ($event['instance'] ?? 'main'),
            'target_type' => (string) ($event['target_type'] ?? 'chat_id'),
            'target' => $target,
            'message_type' => $messageType,
            'metadata' => is_array($event['metadata'] ?? null) ? $event['metadata'] : [],
        ];
        if ($contentFields !== []) {
            $command['content_fields'] = $contentFields;
        }
        if ($rawContent !== null && $rawContent !== '') {
            $command['content'] = $rawContent;
        }
        if ($uuid !== null && $uuid !== '') {
            $command['uuid'] = $uuid;
        }
        if ($messageType === 'text' && isset($contentFields['text'])) {
            $command['text'] = $contentFields['text'];
        }
        return $command;
    }

    /**
     * @param array<string,mixed> $frame
     * @param array<string,mixed> $postContent
     * @return array<string,mixed>|null
     */
    public static function buildPostCommand(array $frame, array $postContent, ?string $uuid = null): ?array
    {
        $rawContent = json_encode($postContent, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if (!is_string($rawContent) || $rawContent === '') {
            return null;
        }

        return self::buildSendCommand($frame, 'post', [], $rawContent, $uuid);
    }

    /**
     * @param array<string,mixed> $frame
     * @param array<string,mixed> $cardContent
     * @return array<string,mixed>|null
     */
    public static function buildInteractiveCommand(array $frame, array $cardContent, ?string $uuid = null): ?array
    {
        $rawContent = json_encode($cardContent, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if (!is_string($rawContent) || $rawContent === '') {
            return null;
        }

        return self::buildSendCommand($frame, 'interactive', [], $rawContent, $uuid);
    }

    /**
     * @param array<string,mixed> $frame
     * @param array<string,string> $contentFields
     * @return array<string,mixed>|null
     */
    public static function buildUpdateCommand(
        array $frame,
        string $messageType,
        array $contentFields = [],
        ?string $rawContent = null,
        ?string $uuid = null,
        ?string $targetType = null,
        ?string $target = null,
    ): ?array {
        $event = self::parseEvent($frame);
        if ($event === null) {
            return null;
        }

        $resolvedTargetType = $targetType ?? 'message_id';
        $resolvedTarget = $target ?? (string) ($event['message_id'] ?? '');
        if ($resolvedTarget === '') {
            return null;
        }

        $command = self::buildSendCommand($frame, $messageType, $contentFields, $rawContent, $uuid);
        if ($command === null) {
            return null;
        }

        $command['event'] = 'update';
        $command['target_type'] = $resolvedTargetType;
        $command['target'] = $resolvedTarget;
        return $command;
    }

    /**
     * @param array<string,mixed> $frame
     * @param array<string,mixed> $cardContent
     * @return array<string,mixed>|null
     */
    public static function buildUpdateInteractiveCommand(
        array $frame,
        array $cardContent,
        ?string $uuid = null,
        ?string $targetType = null,
        ?string $target = null,
    ): ?array {
        $rawContent = json_encode($cardContent, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        if (!is_string($rawContent) || $rawContent === '') {
            return null;
        }

        $event = self::parseEvent($frame);
        if ($event === null) {
            return null;
        }

        $resolvedTargetType = $targetType;
        $resolvedTarget = $target;
        if ($resolvedTargetType === null && $resolvedTarget === null) {
            $token = (string) ($event['token'] ?? '');
            if ($token !== '') {
                $resolvedTargetType = 'token';
                $resolvedTarget = $token;
            }
        }

        return self::buildUpdateCommand(
            $frame,
            'interactive',
            [],
            $rawContent,
            $uuid,
            $resolvedTargetType,
            $resolvedTarget,
        );
    }

    /**
     * @return array<string,mixed>|null
     */
    private static function decodeMessageContent(string $messageType, string $contentRaw): ?array
    {
        $decoded = json_decode($contentRaw, true);
        if (!is_array($decoded)) {
            return null;
        }

        return match ($messageType) {
            'text' => [
                'text' => (string) ($decoded['text'] ?? ''),
            ],
            'image' => [
                'image_key' => (string) ($decoded['image_key'] ?? ''),
            ],
            'file' => [
                'file_key' => (string) ($decoded['file_key'] ?? ''),
                'file_name' => (string) ($decoded['file_name'] ?? ''),
            ],
            'audio' => [
                'file_key' => (string) ($decoded['file_key'] ?? ''),
                'duration' => (string) ($decoded['duration'] ?? ''),
            ],
            'media' => [
                'file_key' => (string) ($decoded['file_key'] ?? ''),
                'image_key' => (string) ($decoded['image_key'] ?? ''),
                'file_name' => (string) ($decoded['file_name'] ?? ''),
                'duration' => (string) ($decoded['duration'] ?? ''),
            ],
            'sticker' => [
                'file_key' => (string) ($decoded['file_key'] ?? ''),
            ],
            'post' => [
                'post' => $decoded,
            ],
            default => [
                'raw' => $decoded,
            ],
        };
    }
}
