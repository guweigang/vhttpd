<?php

declare(strict_types=1);

namespace VPhp\VSlim\Stream;

final class NdjsonDecoder
{
    /**
     * @param resource $stream
     * @return \Generator<int,array<string,mixed>>
     */
    public static function decode($stream): \Generator
    {
        try {
            while (is_resource($stream) && !feof($stream)) {
                $line = fgets($stream);
                if ($line === false) {
                    break;
                }
                $line = trim($line);
                if ($line === '') {
                    continue;
                }
                $row = json_decode($line, true);
                if (!is_array($row)) {
                    continue;
                }
                yield $row;
                if (!empty($row['done'])) {
                    break;
                }
            }
        } finally {
            if (is_resource($stream)) {
                fclose($stream);
            }
        }
    }
}
