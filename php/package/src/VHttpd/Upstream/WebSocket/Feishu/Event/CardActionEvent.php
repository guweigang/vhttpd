<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Event;

use VHttpd\Upstream\WebSocket\Feishu\Event;

final class CardActionEvent extends Event
{
    public function actionTag(): string { return $this->textField('action_tag'); }
    public function actionValue(): mixed { return $this->fields['action_value'] ?? null; }
}
