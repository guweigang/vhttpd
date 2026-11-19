<?php
declare(strict_types=1);

namespace VHttpd\Upstream\WebSocket\Feishu\Content;

use VHttpd\Upstream\WebSocket\Feishu\Record;

final class PostContent extends Record
{
    public static function create(string $title): self
    {
        return new self(['zh_cn' => ['title' => $title, 'content' => []]]);
    }

    public function textLine(string $text): self
    {
        $fields = $this->fields;
        $fields['zh_cn']['content'][] = [['tag' => 'text', 'text' => $text]];
        return new self($fields);
    }
}
