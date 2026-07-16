# Feishu Streaming Card Plan

This note captures a minimal design for Feishu "streaming output" without
assuming native token-by-token text streaming from Feishu message APIs.

## Goal

Provide a streaming-like user experience in Feishu by:

1. sending an initial interactive card
2. progressively updating that card while content is generated
3. finalizing the card when generation completes or fails

## Why card updates

Current `vhttpd` and PHP worker capabilities already support:

- sending interactive cards
- updating interactive cards
- callback token updates
- active outbound gateway calls from PHP via `VPhp\VHttpd\VHttpd::gateway('feishu')`

This matches the OpenClaw Feishu "streaming" experience more closely than
assuming a native streaming text message protocol.

## Existing building blocks

### Transport and gateway

- Feishu send:
  - `/gateway/feishu/messages`
- Feishu update:
  - existing websocket upstream `update` command execution
- PHP host calls:
  - `VPhp\VHttpd\VHttpd::gateway('feishu')`

### PHP semantic layer

- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Command::sendInteractive(...)`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Command::updateInteractive(...)`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\InteractiveCard`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\CardHeader`
- `VPhp\VHttpd\Upstream\WebSocket\Feishu\Content\CardMarkdown`

## Proposed model

### Stream session

Introduce a lightweight session object at the PHP layer:

- `provider`
- `instance`
- `chat_id`
- `message_id`
- `started_at`
- `last_flush_at`
- `finalized`

### Lifecycle

1. `start`
   - send an initial placeholder card
   - store returned `message_id`
2. `append`
   - accumulate generated content chunks
   - periodically rebuild the card body
3. `flush`
   - call interactive card update on the same `message_id`
4. `finalize`
   - write final content
   - optionally mark completion state in the card
5. `fail`
   - update card with failure state

## Update policy

Do not update on every token.

Recommended first policy:

- coalesce updates
- flush every `300ms` to `1000ms`
- always flush on completion

This avoids excessive card update calls and keeps the user experience stable.

## First implementation scope

If implemented later, keep it intentionally narrow:

- only interactive cards
- only one stream session per output
- message target uses `message_id`
- no persistence across worker restarts
- no background queue in `vhttpd`

## Suggested PHP API shape

Possible future PHP-only helper:

```php
$stream = FeishuStreamingCard::start(
    instance: 'main',
    chatId: 'oc_xxx',
    title: 'Thinking...'
);

$stream->appendMarkdown("first chunk");
$stream->appendMarkdown("second chunk");
$stream->flush();
$stream->finalize();
```

Internally this would use:

- `VHttpd::gateway('feishu')->send(...)`
- `VHttpd::gateway('feishu')->send/update ...`

## MCP implications

This should not be the first MCP Feishu tool.

Recommended MCP order:

1. `feishu.list_chats`
2. `feishu.send_text`
3. `feishu.send_image`
4. `feishu.send_card`
5. `feishu.update_card`
6. only then consider a higher-level streaming card tool

Reason:

- streaming needs session state
- update cadence
- failure handling
- prompt/tool interaction design

These are better designed after the static card tools have stabilized.
