<?php

declare(strict_types=1);

namespace VHttpd\Wire;

use RuntimeException;

final class FrameCodec
{
    /**
     * @param resource $conn
     */
    public static function read($conn, int $maxBytes = 16_777_216): string
    {
        $header = self::readExact($conn, 4);
        $unpacked = unpack('Nsize', $header);
        $size = (int) ($unpacked['size'] ?? 0);
        if ($size <= 0 || $size > $maxBytes) {
            throw new RuntimeException('invalid frame size: ' . $size);
        }

        return self::readExact($conn, $size);
    }

    /**
     * @param resource $conn
     */
    public static function write($conn, string $payload): void
    {
        $data = pack('N', strlen($payload)) . $payload;
        $written = 0;
        $size = strlen($data);
        while ($written < $size) {
            $n = fwrite($conn, substr($data, $written));
            if ($n === false || $n === 0) {
                throw new RuntimeException('failed to write frame');
            }
            $written += $n;
        }
    }

    /**
     * @param resource $conn
     */
    private static function readExact($conn, int $size): string
    {
        $buf = '';
        while (strlen($buf) < $size) {
            $chunk = fread($conn, $size - strlen($buf));
            if ($chunk === false || $chunk === '') {
                throw new RuntimeException('unexpected EOF while reading frame');
            }
            $buf .= $chunk;
        }

        return $buf;
    }
}
