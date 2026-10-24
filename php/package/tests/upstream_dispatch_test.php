<?php
declare(strict_types=1);

if (($argv[1] ?? '') === 'without-vendor') {
    require $argv[2] . '/autoload.php';
    require $argv[3] . '/autoload.php';
    $event = \VHttpd\Upstream\WebSocket\Event::fromDispatchRequest(['provider' => 'feishu']);
    if ($event->provider() !== 'feishu' || !class_exists(\VHttpd\PhpWorker\Server::class)) exit(1);
    echo "PASS: two source SDK copies without Composer\n";
    exit;
}

require_once dirname(__DIR__) . '/autoload.php';

use VHttpd\Upstream\WebSocket\{CommandBus, CommandFactory, Event, EventHandler, EventRouter};

function check(bool $ok, string $message): void {
    if (!$ok) throw new RuntimeException($message);
}

$wire = ['mode' => 'websocket_upstream', 'provider' => 'feishu', 'event_type' => 'im.message.receive_v1',
    'instance' => 'main', 'request_id' => 'request', 'payload' => '{"message_id":"old"}'];
$event = Event::fromDispatchRequest($wire);
$wire['payload'] = '{"message_id":"replacement"}';
check($event->payloadArray()['message_id'] === 'old', 'event must retain captured request');
check($event->request()['instance'] === 'main', 'dispatch identity must survive decoding');
$credentials = ['stream_generation' => 'captured-generation', 'creation_token' => 'captured-token'];
$handler = new class($credentials) implements EventHandler {
    public function __construct(private readonly array $credentials) {}
    public function supports(Event $event): bool { return $event->matches('feishu', 'im.message.receive_v1'); }
    public function handle(Event $event, CommandBus $bus): void {
        $bus->send(CommandFactory::providerMessageSend($event->provider(), ['stream_id' => 'reply',
            'metadata' => $this->credentials, 'target' => $event->payloadArray()['message_id']]));
        $bus->send(['type' => 'session.clear', 'stream_id' => 'reply', 'metadata' => $this->credentials]);
    }
};
$router = (new EventRouter())->addHandler($handler);
$response = $router->dispatch($event)->export();
check($response['handled'] && count($response['commands']) === 2, 'real handler dispatch must append ordered commands');
check($response['commands'][0]['metadata'] === $credentials && $response['commands'][1]['metadata'] === $credentials,
    'serialization must preserve captured credentials through send and cleanup');
check($response['commands'][0]['target'] === 'old', 'dispatch must use the captured event');
check(!$router->dispatch(Event::fromDispatchRequest(['provider' => 'other']))->export()['handled'], 'unmatched events must remain unhandled');
$rpc = CommandFactory::providerRpcCall('codex', 'thread/read', ['threadId' => 'a'], 'rpc')->toArray();
check(json_decode($rpc['params'], true)['threadId'] === 'a', 'RPC params must be encoded for the wire');
try { (new CommandBus())->send(['content' => 'missing type']); throw new RuntimeException('invalid command accepted'); }
catch (InvalidArgumentException) {}
check(Event::fromDispatchRequest(['payload' => 'malformed'])->payloadArray() === [], 'invalid payload cannot become an event object');

// Deployment/source fallbacks must coexist even when each package has its own path.
$temporary = sys_get_temp_dir() . '/vhttpd-sdk-autoload-' . bin2hex(random_bytes(8));
try {
    foreach (['one', 'two'] as $copy) {
        $destination = $temporary . '/' . $copy;
        mkdir($destination, 0700, true);
        copy(dirname(__DIR__) . '/autoload.php', $destination . '/autoload.php');
        $source = dirname(__DIR__) . '/src';
        foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($source, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::SELF_FIRST) as $entry) {
            $target = $destination . '/src/' . substr($entry->getPathname(), strlen($source) + 1);
            if ($entry->isDir()) mkdir($target, 0700, true);
            else {
                if (!is_dir(dirname($target))) mkdir(dirname($target), 0700, true);
                copy($entry->getPathname(), $target);
            }
        }
    }
    $pipes = [];
    $process = proc_open([PHP_BINARY, __FILE__, 'without-vendor', $temporary . '/one', $temporary . '/two'],
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    check(is_resource($process), 'fresh SDK subprocess must start');
    fclose($pipes[0]);
    $output = stream_get_contents($pipes[1]); fclose($pipes[1]);
    $error = stream_get_contents($pipes[2]); fclose($pipes[2]);
    check(proc_close($process) === 0 && str_contains($output, 'PASS:'), 'source SDK fallback failed: ' . $error);
} finally {
    if (is_dir($temporary)) {
        foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($temporary, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST) as $entry) {
            if ($entry->isDir()) rmdir($entry->getPathname()); else unlink($entry->getPathname());
        }
        rmdir($temporary);
    }
}
echo "PASS: source SDK autoload, event dispatch, command ordering and captured credentials\n";
