<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu;

use VHttpd\Upstream\WebSocket\Feishu\Event\CardActionEvent;

class Event extends Record
{
    public static function fromArray(array $fields): self
    {
        self::requireField($fields, 'event_type');
        return ($fields['event_kind'] ?? '') === 'action' || $fields['event_type'] === 'card.action.trigger'
            ? new CardActionEvent($fields)
            : new self($fields);
    }

    public function provider(): string { return $this->textField('provider'); }
    public function instance(): string { return $this->textField('instance'); }
    public function eventType(): string { return $this->textField('event_type'); }
    public function targetType(): string { return $this->textField('target_type'); }
    public function target(): string { return $this->textField('target'); }
    public function messageId(): string { return $this->textField('message_id'); }
    public function openMessageId(): string { return $this->textField('open_message_id'); }
    public function token(): string { return $this->textField('token'); }
    public function metadata(): array { return (array) ($this->fields['metadata'] ?? []); }
    public function asCardAction(): ?CardActionEvent { return $this instanceof CardActionEvent ? $this : null; }
}
