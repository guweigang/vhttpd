<?php

declare(strict_types=1);

namespace VSlim\App\Feishu;

use VHttpd\Upstream\WebSocket\Feishu\Command;
use VHttpd\Upstream\WebSocket\Feishu\Event\CardActionEvent;
use VHttpd\Upstream\WebSocket\Feishu\Message\AudioMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\FileMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\ImageMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\MediaMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\PostMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\StickerMessage;
use VHttpd\Upstream\WebSocket\Feishu\Message\TextMessage;

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
