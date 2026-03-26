<?php

declare(strict_types=1);

namespace VPhp\Provider\Codex;

class Parser
{
    public static function parse(string $json): Message
    {
        $data = json_decode($json, true);
        if ($data === null) {
            throw new \RuntimeException("Failed to decode Codex JSON: " . json_last_error_msg());
        }

        if (isset($data['method'])) {
            if (isset($data['id'])) {
                return new ServerRequest($data);
            }
            return new Notification($data);
        }

        if (isset($data['id'])) {
            return new Response($data);
        }

        throw new \RuntimeException("Unknown Codex message format: " . $json);
    }
}
