<?php

declare(strict_types=1);

namespace VHttpd\App;

use VPhp\VHttpd\Upstream\WebSocket\Feishu\Command;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\CardActionValue;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\CardButton;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\CardHeader;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\InteractiveCard;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\PlainText;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Event\CardActionEvent;
use VPhp\VHttpd\Upstream\WebSocket\Feishu\Message\TextMessage;
use VPhp\VSlim\App\Feishu\AbstractBotHandler;

class MyFeishuBot extends AbstractBotHandler
{
    public function onTextMessage(TextMessage $message): ?Command
    {
        $text = $message->text();
        if ($text === '') {
            return null;
        }

        if ($text === 'ping' || $text === '/ping') {
            return Command::replyText($message, 'pong');
        }

        if (str_starts_with($text, '/vhttpd ')) {
            return Command::replyText(
                $message,
                sprintf(
                    'vhttpd websocket upstream demo (%s): %s',
                    $message->instance(),
                    trim(substr($text, strlen('/vhttpd '))),
                ),
            );
        }

        if ($text === '/card') {
            return Command::sendInteractive($message, $this->buildDemoCard($message->instance()));
        }

        return null;
    }

    public function onCardAction(CardActionEvent $event): ?Command
    {
        $actionTag = $event->actionTag();
        if ($actionTag === '') {
            return null;
        }

        $actionValue = $event->actionValue();
        $actionName = '';
        if (is_array($actionValue)) {
            $actionName = trim((string) ($actionValue['action'] ?? $actionValue['value'] ?? ''));
        } elseif (is_string($actionValue)) {
            $actionName = trim($actionValue);
        }
        if ($actionName === '') {
            $actionName = $actionTag;
        }

        return Command::updateInteractive(
            $event,
            InteractiveCard::create('vhttpd card action')
                ->wideScreen()
                ->header(CardHeader::create(PlainText::create('vhttpd card action')))
                ->markdown(sprintf(
                    'vhttpd card action (%s): %s',
                    $event->instance(),
                    $actionName,
                )),
        );
    }

    protected function buildDemoCard(string $instance): InteractiveCard
    {
        return InteractiveCard::create(sprintf('vhttpd demo card (%s)', $instance))
            ->wideScreen()
            ->header(CardHeader::create(PlainText::create(sprintf('vhttpd demo card (%s)', $instance))))
            ->markdown('Click the button to trigger a callback update.')
            ->action(
                CardButton::primary(PlainText::create('Approve'), CardActionValue::action('approve')),
            );
    }
}
