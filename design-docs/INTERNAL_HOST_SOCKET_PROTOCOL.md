# Internal Host Socket Protocol

`vhttpd` injects `VHTTPD_INTERNAL_ADMIN_SOCKET` into managed PHP workers.

PHP-side helpers:

- `VPhp\VHttpd\VHttpd::admin()`
- `VPhp\VHttpd\VHttpd::gateway('feishu')`

both talk to that same unix socket.

## Framing

Every frame is:

1. a 4-byte big-endian length prefix
2. followed by exactly that many payload bytes

For most calls, a request is a single JSON frame and the response is a single JSON frame.

## Modes

The first request frame is always a JSON object with:

- `mode`
- `method`
- `path`
- optional `query`
- optional `body`

Supported modes:

- `vhttpd_admin`
  - read-only host/runtime queries
- `vhttpd_gateway`
  - active gateway operations such as Feishu send/upload

## Admin Calls

Example request envelope:

```json
{
  "mode": "vhttpd_admin",
  "method": "GET",
  "path": "/runtime/feishu/chats",
  "query": {
    "instance": "main"
  }
}
```

## Gateway Calls

Example text send envelope:

```json
{
  "mode": "vhttpd_gateway",
  "method": "POST",
  "path": "/feishu/messages",
  "body": "{\"app\":\"main\",\"target_type\":\"chat_id\",\"target\":\"oc_xxx\",\"message_type\":\"text\",\"text\":\"hello\"}"
}
```

## Binary Image Upload

`/feishu/images` supports a two-frame request so PHP workers do not need to base64-encode image bytes.

Frame 1: JSON header

```json
{
  "mode": "vhttpd_gateway",
  "method": "POST",
  "path": "/feishu/images",
  "body": "{\"app\":\"main\",\"image_type\":\"message\",\"filename\":\"alma.png\",\"content_type\":\"image/png\",\"content_length\":12345}"
}
```

Frame 2: raw image bytes

Notes:

- `content_length` must match the second frame size exactly
- `vhttpd` still accepts the older base64 JSON body for compatibility
- current image upload limit is 10 MB on both PHP and `vhttpd` sides

## Responses

Responses are always a single JSON frame shaped like:

```json
{
  "status": 200,
  "headers": {
    "content-type": "application/json; charset=utf-8"
  },
  "body": "...",
  "error": ""
}
```

`body` may itself be JSON-encoded application data depending on the route.
