<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Command;

use VHttpd\Upstream\WebSocket\Feishu\Command;

final class UpdateCommand extends Command
{
    public function isMessageIdTarget(): bool { return $this->textField('target_type') === 'message_id'; }
}
