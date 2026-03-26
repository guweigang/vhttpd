<?php

declare(strict_types=1);

namespace VPhp\VSlim\App\Feishu;

use VPhp\VHttpd\Upstream\WebSocket\Feishu\Command;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Event\CardActionEvent;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\AudioMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\FileMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\ImageMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\MediaMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\PostMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\StickerMessage;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\TextMessage;

abstract class AbstractBotHandler implements BotHandler
{
    public function onTextMessage(TextMessage $message): ?Command
    {
        return null;
    }

    public function onImageMessage(ImageMessage $message): ?Command
    {
        return null;
    }

    public function onPostMessage(PostMessage $message): ?Command
    {
        return null;
    }

    public function onFileMessage(FileMessage $message): ?Command
    {
        return null;
    }

    public function onAudioMessage(AudioMessage $message): ?Command
    {
        return null;
    }

    public function onMediaMessage(MediaMessage $message): ?Command
    {
        return null;
    }

    public function onStickerMessage(StickerMessage $message): ?Command
    {
        return null;
    }

    public function onCardAction(CardActionEvent $event): ?Command
    {
        return null;
    }
}
