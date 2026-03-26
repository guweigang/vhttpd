<?php

declare(strict_types=1);

namespace VPhp\VSlim\Stream;

use VPhp\VHttpd\Upstream\Plan;
use VPhp\VHttpd\PhpWorker\StreamApp;

final class Factory
{
    /**
     * @param iterable<mixed>|callable $chunks
     * @param array<string,string> $headers
     */
    public static function text(
        iterable|callable $chunks,
        int $status = 200,
        string $contentType = 'text/plain; charset=utf-8',
        array $headers = [],
    ): Response {
        return Response::textWith($chunks, $status, $contentType, $headers);
    }

    /**
     * @param iterable<mixed>|callable $events
     * @param array<string,string> $headers
     */
    public static function sse(iterable|callable $events, int $status = 200, array $headers = []): Response
    {
        return Response::sseWith($events, $status, $headers);
    }

    /**
     * @param iterable<mixed>|callable $chunks
     * @param array<string,string> $headers
     */
    public static function dispatchText(
        iterable|callable $chunks,
        int $status = 200,
        string $contentType = 'text/plain; charset=utf-8',
        array $headers = [],
        int $batchSize = 1,
        int $delayMs = 0,
    ): StreamApp {
        return StreamApp::fromSequence(
            'text',
            $chunks,
            $status,
            $contentType,
            $headers,
            $batchSize,
            $delayMs,
        );
    }

    /**
     * @param iterable<mixed>|callable $events
     * @param array<string,string> $headers
     */
    public static function dispatchSse(
        iterable|callable $events,
        int $status = 200,
        array $headers = [],
        int $batchSize = 1,
        int $delayMs = 0,
    ): StreamApp {
        return StreamApp::fromSequence(
            'sse',
            $events,
            $status,
            'text/event-stream',
            $headers,
            $batchSize,
            $delayMs,
        );
    }

    public static function dispatchResponse(
        object $response,
        int $batchSize = 1,
        int $delayMs = 0,
    ): StreamApp {
        return StreamApp::fromStreamResponse($response, $batchSize, $delayMs);
    }

    /**
     * @param array<string,mixed> $options
     */
    public static function ollamaUpstreamTextPlan(\VSlim\Request $req, array $options = []): Plan
    {
        return OllamaClient::fromOptions($options)->upstreamTextPlanFromRequest($req);
    }

    /**
     * @param array<string,mixed> $options
     */
    public static function ollamaUpstreamSsePlan(\VSlim\Request $req, array $options = []): Plan
    {
        return OllamaClient::fromOptions($options)->upstreamSsePlanFromRequest($req);
    }

    /**
     * @param array<string,mixed> $options
     */
    public static function ollamaUpstreamPlan(
        \VSlim\Request $req,
        string $outputMode = 'sse',
        array $options = [],
    ): Plan {
        return OllamaClient::fromOptions($options)->upstreamPlanFromRequest($req, $outputMode);
    }

    /**
     * @param array<string,mixed> $options
     */
    public static function ollamaText(\VSlim\Request $req, array $options = []): Response|array
    {
        return OllamaClient::fromOptions($options)->textResponseFromRequest($req);
    }

    /**
     * @param array<string,mixed> $options
     */
    public static function ollamaSse(\VSlim\Request $req, array $options = []): Response|array
    {
        return OllamaClient::fromOptions($options)->sseResponseFromRequest($req);
    }
}
