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

interface BotHandler
{
    public function onTextMessage(TextMessage $message): ?Command;

    public function onImageMessage(ImageMessage $message): ?Command;

    public function onPostMessage(PostMessage $message): ?Command;

    public function onFileMessage(FileMessage $message): ?Command;

    public function onAudioMessage(AudioMessage $message): ?Command;

    public function onMediaMessage(MediaMessage $message): ?Command;

    public function onStickerMessage(StickerMessage $message): ?Command;

    public function onCardAction(CardActionEvent $event): ?Command;
}
