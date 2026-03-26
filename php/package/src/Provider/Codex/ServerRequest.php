<?php

declare(strict_types=1);

namespace VPhp\Provider\Codex;

class ServerRequest extends Message
{
    /**
     * @return array{decision: string, reason?: string}
     */
    public function reply(string $decision, ?string $reason = null): array
    {
        $res = ['decision' => $decision];
        if ($reason) {
            $res['reason'] = $reason;
        }
        return [
            'id' => $this->getId(),
            'result' => $res
        ];
    }
}
