<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Content;

use VHttpd\Upstream\WebSocket\Feishu\Record;

final class InteractiveCard extends Record
{
    public static function create(string $title): self
    {
        return new self([
            'header' => CardHeader::create(PlainText::create($title))->toArray(),
            'elements' => [],
        ]);
    }

    public function wideScreen(bool $enabled = true): self
    {
        $fields = $this->fields;
        $fields['config']['wide_screen_mode'] = $enabled;
        return new self($fields);
    }

    public function header(CardHeader $header): self
    {
        return new self(['header' => $header->toArray()] + $this->fields);
    }

    public function element(CardMarkdown|CardActionBlock|array $element): self
    {
        $fields = $this->fields;
        $fields['elements'][] = is_array($element) ? $element : $element->toArray();
        return new self($fields);
    }

    public function markdown(string $text): self
    {
        return $this->element(CardMarkdown::create($text));
    }

    public function action(CardButton ...$buttons): self
    {
        return $this->element(CardActionBlock::create(...$buttons));
    }
}
