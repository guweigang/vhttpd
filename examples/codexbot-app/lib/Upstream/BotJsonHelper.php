<?php

declare(strict_types=1);

namespace CodexBot\Upstream;

final class BotJsonHelper
{
    public function decode(string $raw, string $label = 'json'): array
    {
        if ($raw === '') {
            return [];
        }

        $candidate = $raw;
        for ($i = 0; $i < 3; $i++) {
            try {
                $decoded = json_decode($candidate, true, 4096, JSON_INVALID_UTF8_SUBSTITUTE);
                if (is_array($decoded)) {
                    return $decoded;
                }

                if (is_string($decoded)) {
                    $trimmed = trim($decoded);
                    file_put_contents(
                        'php://stderr',
                        "[PHP] decode step {$i} for {$label}: got string len=" . strlen($decoded) .
                        " head=" . substr($trimmed, 0, 120) .
                        " tail=" . substr($trimmed, -120) . "\n"
                    );
                    if ($trimmed !== '' && ($trimmed[0] ?? '') !== '') {
                        $candidate = $trimmed;
                        continue;
                    }
                }

                $jsonErr = json_last_error();
                $jsonErrMsg = json_last_error_msg();
                file_put_contents(
                    'php://stderr',
                    "[PHP] decode warning for {$label}: decoded " . gettype($decoded) .
                    " json_error={$jsonErr} json_error_msg={$jsonErrMsg}" .
                    " raw_len=" . strlen($candidate) .
                    " raw_head=" . substr($candidate, 0, 120) .
                    " raw_tail=" . substr($candidate, -120) . "\n"
                );
                return [];
            } catch (\JsonException $e) {
                file_put_contents(
                    'php://stderr',
                    "[PHP] decode failed for {$label}: " . $e->getMessage() .
                    " raw_len=" . strlen($candidate) .
                    " raw_head=" . substr($candidate, 0, 120) .
                    " raw_tail=" . substr($candidate, -120) . "\n"
                );
                return [];
            } catch (\Throwable $e) {
                file_put_contents(
                    'php://stderr',
                    "[PHP] decode failed for {$label}: " . $e->getMessage() .
                    " raw_len=" . strlen($candidate) .
                    " raw_head=" . substr($candidate, 0, 120) .
                    " raw_tail=" . substr($candidate, -120) . "\n"
                );
                return [];
            }
        }

        file_put_contents('php://stderr', "[PHP] decode warning for {$label}: exceeded nested decode attempts\n");
        return [];
    }
}
