<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu;

use VHttpd\Upstream\WebSocket\Feishu\Command\SendCommand;
use VHttpd\Upstream\WebSocket\Feishu\Command\UpdateCommand;
use VHttpd\Upstream\WebSocket\Feishu\Content\InteractiveCard;
use VHttpd\Upstream\WebSocket\Feishu\Content\PostContent;

class Command extends Record
{
    public static function fromArray(array $fields): self
    {
        foreach (['event', 'target_type', 'target', 'message_type'] as $key) {
            self::requireField($fields, $key);
        }
        return match ($fields['event']) {
            'send' => new SendCommand($fields),
            'update' => new UpdateCommand($fields),
            default => throw new \InvalidArgumentException('unknown Feishu command event'),
        };
    }

    public static function sendText(string $target, string $text, string $instance = 'main', string $targetType = 'chat_id'): self
    {
        return self::fromArray([
            'event' => 'send', 'provider' => 'feishu', 'instance' => $instance,
            'target_type' => $targetType, 'target' => $target, 'message_type' => 'text',
            'text' => $text, 'content_fields' => ['text' => $text],
        ]);
    }

    public static function replyText(Message $message, string $text, ?string $uuid = null): self
    {
        return self::forEvent($message, 'send', 'text', ['text' => $text, 'content_fields' => ['text' => $text]], $uuid);
    }

    public static function sendImage(Message $message, string $key, ?string $uuid = null): self
    {
        return self::forEvent($message, 'send', 'image', ['content_fields' => ['image_key' => $key]], $uuid);
    }

    public static function sendPost(Message $message, array|PostContent $post, ?string $uuid = null): self
    {
        return self::forEvent($message, 'send', 'post', ['content' => self::encode($post)], $uuid);
    }

    public static function sendInteractive(Message $message, array|InteractiveCard $card, ?string $uuid = null): self
    {
        return self::forEvent($message, 'send', 'interactive', ['content' => self::encode($card)], $uuid);
    }

    public static function updateInteractive(Event $event, array|InteractiveCard $card, ?string $uuid = null): self
    {
        return self::forEvent($event, 'update', 'interactive', ['content' => self::encode($card)], $uuid);
    }

    public static function updateText(Event $event, string $text, ?string $uuid = null): self
    {
        return self::forEvent($event, 'update', 'text', ['text' => $text, 'content_fields' => ['text' => $text]], $uuid);
    }

    private static function forEvent(Event $event, string $operation, string $messageType, array $content, ?string $uuid): self
    {
        $targetType = $event->targetType() ?: 'chat_id';
        $target = $event->target();
        if ($operation === 'update') {
            if ($event->token() !== '') {
                $targetType = 'token';
                $target = $event->token();
            } else {
                $targetType = 'message_id';
                $target = $event->messageId() ?: $event->openMessageId();
            }
        }
        $fields = [
            'event' => $operation,
            'provider' => $event->provider() ?: 'feishu',
            'instance' => $event->instance() ?: 'main',
            'target_type' => $targetType,
            'target' => $target,
            'message_type' => $messageType,
            'metadata' => $event->metadata(),
        ] + $content;
        if ($uuid !== null && $uuid !== '') {
            $fields['uuid'] = $uuid;
        }
        return self::fromArray($fields);
    }

    private static function encode(array|\JsonSerializable $value): string
    {
        return json_encode($value, JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    }

    public function eventName(): string { return $this->textField('event'); }
    public function messageType(): string { return $this->textField('message_type'); }
    public function target(): string { return $this->textField('target'); }
    public function text(): string { return $this->textField('text'); }
    public function uuid(): string { return $this->textField('uuid'); }
    public function metadata(): array { return (array) ($this->fields['metadata'] ?? []); }
    public function asSend(): ?SendCommand { return $this instanceof SendCommand ? $this : null; }
    public function asUpdate(): ?UpdateCommand { return $this instanceof UpdateCommand ? $this : null; }
}
