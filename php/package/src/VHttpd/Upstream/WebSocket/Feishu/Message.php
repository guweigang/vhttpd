<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu;

use VHttpd\Upstream\WebSocket\Feishu\Message\AudioMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\FileMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\ImageMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\MediaMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\PostMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\StickerMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\TextMessage;

class Message extends Event
{
    public static function fromArray(array $fields): self
    {
        self::requireField($fields, 'message_type');
        return match ($fields['message_type']) {
            'audio' => new AudioMessage($fields),
            'file' => new FileMessage($fields),
            'image' => new ImageMessage($fields),
            'media' => new MediaMessage($fields),
            'post' => new PostMessage($fields),
            'sticker' => new StickerMessage($fields),
            'text' => new TextMessage($fields),
            default => new self($fields),
        };
    }

    public function messageType(): string { return $this->textField('message_type'); }
    public function chatType(): string { return $this->textField('chat_type'); }
    public function senderId(): string { return $this->textField('sender_id'); }
    public function content(): array { return (array) ($this->fields['content'] ?? []); }
    public function text(): string { return (string) ($this->fields['text'] ?? $this->content()['text'] ?? ''); }
    public function imageKey(): string { return (string) ($this->content()['image_key'] ?? ''); }
    public function postContent(): array { return (array) ($this->content()['post'] ?? []); }
    public function fileKey(): string { return (string) ($this->content()['file_key'] ?? ''); }
    public function fileName(): string { return (string) ($this->content()['file_name'] ?? ''); }
    public function duration(): int { return (int) ($this->content()['duration'] ?? 0); }
    public function asAudio(): ?AudioMessage { return $this instanceof AudioMessage ? $this : null; }
    public function asFile(): ?FileMessage { return $this instanceof FileMessage ? $this : null; }
    public function asImage(): ?ImageMessage { return $this instanceof ImageMessage ? $this : null; }
    public function asMedia(): ?MediaMessage { return $this instanceof MediaMessage ? $this : null; }
    public function asPost(): ?PostMessage { return $this instanceof PostMessage ? $this : null; }
    public function asSticker(): ?StickerMessage { return $this instanceof StickerMessage ? $this : null; }
    public function asText(): ?TextMessage { return $this instanceof TextMessage ? $this : null; }
}
