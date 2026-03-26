<?php

declare(strict_types=1);

namespace VPhp\VSlim\App\Feishu;

use VPhp\VHttpd\Upstream\WebSocket\Feishu\Command;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Event as FeishuEvent;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Event\CardActionEvent;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Event\Factory as EventFactory;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message as FeishuMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\AbstractMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\AudioMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\Factory as MessageFactory;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\FileMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\ImageMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\MediaMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\PostMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\StickerMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\TextMessage;

final class BotApp
{
    public function __construct(
        private readonly BotHandler $handler,
    ) {
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    public function handle(array $frame): array
    {
        return $this->handle_websocket_upstream($frame);
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    public function handle_websocket_upstream(array $frame): array
    {
        $message = BotAdapter::parseMessageObject($frame);
        if ($message !== null) {
            return $this->handleMessage($message);
        }

        $event = BotAdapter::parseEventObject($frame);
        if ($event !== null) {
            return $this->handleEvent($event);
        }

        return self::unhandled();
    }

    /**
     * @param array<string,mixed> $frame
     * @return array<string,mixed>
     */
    public function handleWebSocketUpstream(array $frame): array
    {
        return $this->handle_websocket_upstream($frame);
    }

    private function handleMessage(FeishuMessage $message): array
    {
        $typed = MessageFactory::fromMessage($message);
        if (!$typed instanceof AbstractMessage) {
            return self::unhandled();
        }

        $command = match (true) {
            $typed instanceof TextMessage => $this->handler->onTextMessage($typed),
            $typed instanceof ImageMessage => $this->handler->onImageMessage($typed),
            $typed instanceof PostMessage => $this->handler->onPostMessage($typed),
            $typed instanceof FileMessage => $this->handler->onFileMessage($typed),
            $typed instanceof AudioMessage => $this->handler->onAudioMessage($typed),
            $typed instanceof MediaMessage => $this->handler->onMediaMessage($typed),
            $typed instanceof StickerMessage => $this->handler->onStickerMessage($typed),
            default => null,
        };

        return self::commandResponse($command);
    }

    private function handleEvent(FeishuEvent $event): array
    {
        $typed = EventFactory::fromEvent($event);
        if (!$typed instanceof CardActionEvent) {
            return self::unhandled();
        }

        return self::commandResponse($this->handler->onCardAction($typed));
    }

    /**
     * @return array<string,mixed>
     */
    private static function commandResponse(?Command $command): array
    {
        if (!$command instanceof Command) {
            return self::unhandled();
        }

        return [
            'handled' => true,
            'commands' => [$command->toArray()],
        ];
    }

    /**
     * @return array<string,mixed>
     */
    private static function unhandled(): array
    {
        return [
            'handled' => false,
            'commands' => [],
        ];
    }
}
