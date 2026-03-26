<?php

declare(strict_types=1);

namespace VPhp\VSlim\Stream;

final class SseEncoder
{
    /**
     * @param iterable<array<string,mixed>> $rows
     * @return \Generator<int,array<string,mixed>>
     */
    public static function fromOllama(iterable $rows, string $model): \Generator
    {
        $index = 0;
        foreach ($rows as $row) {
            $piece = (string) ($row['message']['content'] ?? ($row['response'] ?? ''));
            if ($piece !== '') {
                $index++;
                yield [
                    'id' => 'tok-' . $index,
                    'event' => 'token',
                    'retry' => 1000,
                    'data' => json_encode([
                        'index' => $index,
                        'token' => $piece,
                        'model' => $model,
                    ], JSON_UNESCAPED_UNICODE),
                ];
            }
            if (!empty($row['done'])) {
                yield [
                    'event' => 'done',
                    'data' => json_encode([
                        'done' => true,
                        'model' => $model,
                    ], JSON_UNESCAPED_UNICODE),
                ];
                break;
            }
        }
    }
}
