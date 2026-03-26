<?php
declare(strict_types=1);

$pluginsFile = dirname(__DIR__) . '/vendor/pest-plugins.json';
if (!is_file($pluginsFile)) {
    exit(0);
}

$raw = file_get_contents($pluginsFile);
if (!is_string($raw) || $raw === '') {
    exit(0);
}

$plugins = json_decode($raw, true);
if (!is_array($plugins)) {
    exit(0);
}

$filtered = array_values(array_filter(
    $plugins,
    static fn ($class): bool => (string) $class !== 'Pest\\Mutate\\Plugins\\Mutate'
));

if ($filtered === $plugins) {
    exit(0);
}

file_put_contents(
    $pluginsFile,
    json_encode($filtered, JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT) . PHP_EOL
);

fwrite(STDOUT, "[codex-bot] disabled Pest mutate plugin entry\n");

