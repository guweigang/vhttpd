<?php

declare(strict_types=1);

namespace VHttpd\PhpWorker;

use VHttpd\Wire\JsonClient;

final class Client
{
    private JsonClient $wire;

    public function __construct(
        string $socketPath,
        float $connectTimeoutSeconds = 1.0,
        float $readTimeoutSeconds = 5.0,
    ) {
        $this->wire = new JsonClient($socketPath, 'worker', $connectTimeoutSeconds, $readTimeoutSeconds);
    }

    public function connect(): void
    {
        $this->wire->connect();
    }

    public function close(): void
    {
        $this->wire->close();
    }

    public function request(Request $request): Response
    {
        return Response::fromArray($this->wire->request($request->toArray()));
    }
}
