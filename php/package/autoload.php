<?php
declare(strict_types=1);

// Let Composer register its files before the source fallback loads legacy files.
// This also finds the project loader when installed under vendor/vphp/runtime.
$directory = __DIR__;
for ($depth = 0; $depth < 6; $depth++, $directory = dirname($directory)) {
    foreach ([$directory . '/vendor', $directory] as $vendor) {
        if (is_file($vendor . '/composer/autoload_real.php') && is_file($vendor . '/autoload.php')) {
            require_once $vendor . '/autoload.php';
            break 2;
        }
    }
}

// Source-checkout entry point; Composer installations use the same PSR-4 roots.
spl_autoload_register(static function (string $class): void {
    foreach (['VHttpd\\' => 'VHttpd/', 'VSlim\\' => 'VSlim/', 'VPhp\\Provider\\' => 'Provider/'] as $prefix => $directory) {
        if (!str_starts_with($class, $prefix)) continue;
        $file = __DIR__ . '/src/' . $directory . str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
        if (is_file($file)) require_once $file;
        return;
    }
});
require_once __DIR__ . '/src/legacy_aliases.php';
