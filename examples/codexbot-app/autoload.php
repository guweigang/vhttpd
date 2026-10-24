<?php
declare(strict_types=1);

require_once dirname(__DIR__, 2) . '/php/package/autoload.php';

spl_autoload_register(static function (string $class): void {
    $prefix = 'CodexBot\\';
    if (!str_starts_with($class, $prefix)) return;
    $file = __DIR__ . '/lib/' . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
    if (is_file($file)) require_once $file;
});
