<?php
declare(strict_types=1);

namespace VHttpd\Attribute;

#[\Attribute(\Attribute::TARGET_CLASS | \Attribute::IS_REPEATABLE)]
final class Dispatchable
{
    public function __construct(public readonly string $kind) {}
}
