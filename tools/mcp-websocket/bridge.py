"""Translate an MCP WebSocket connection to a fixed vhttpd HTTP Relay route."""

import argparse
import asyncio
import http.client
from http import HTTPStatus
import json

from websockets.asyncio.server import serve

MAX_MESSAGE = 1024 * 1024


def check_handshake(connection, request):
    if request.path != "/mcp":
        return connection.respond(HTTPStatus.NOT_FOUND, "Unknown endpoint\n")
    authorization = request.headers.get_all("Authorization")
    if len(authorization) != 1 or not authorization[0].startswith("Bearer "):
        return connection.respond(HTTPStatus.UNAUTHORIZED, "Bearer required\n")
    return None


class RelaySession:
    def __init__(self, port, path, authorization):
        self.port = port
        self.path = path
        self.headers = {
            "Authorization": authorization,
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        }

    def request(self, method, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=35)
        try:
            connection.request(method, self.path, body, self.headers)
            with connection.getresponse() as response:
                data = response.read(MAX_MESSAGE + 1)
                if len(data) > MAX_MESSAGE:
                    raise ValueError("MCP response exceeds limit")
                if 200 <= response.status < 300:
                    session_id = response.getheader("MCP-Session-Id")
                    if session_id:
                        self.headers["MCP-Session-Id"] = session_id
                return response.status, response.getheader("Content-Type", ""), data
        finally:
            connection.close()

    async def serve(self, connection):
        try:
            async for message in connection:
                if not isinstance(message, str):
                    await connection.close(1003, "MCP requires JSON text")
                    return
                try:
                    request = json.loads(message)
                    if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                        raise ValueError("Expected a JSON-RPC message")
                    status, content_type, body = await asyncio.to_thread(
                        self.request, "POST", message.encode()
                    )
                    if not 200 <= status < 300:
                        await connection.close(
                            1008 if status in (401, 403, 410) else 1011,
                            f"MCP upstream HTTP {status}",
                        )
                        return
                    if content_type.startswith("text/event-stream"):
                        for event in body.decode().replace("\r\n", "\n").split("\n\n"):
                            lines = [line[5:].removeprefix(" ") for line in event.splitlines()
                                     if line.startswith("data:")]
                            if lines:
                                await connection.send("\n".join(lines))
                    elif body:
                        decoded = body.decode()
                        response = json.loads(decoded)
                        if request.get("method") == "initialize" and isinstance(response.get("result"), dict):
                            version = response["result"].get("protocolVersion")
                            if isinstance(version, str):
                                self.headers["MCP-Protocol-Version"] = version
                        await connection.send(decoded)
                except (OSError, ValueError, http.client.HTTPException):
                    await connection.close(1011, "MCP upstream exchange failed")
                    return
        finally:
            if "MCP-Session-Id" in self.headers:
                try:
                    await asyncio.to_thread(self.request, "DELETE")
                except (OSError, ValueError, http.client.HTTPException):
                    pass


async def run(port, upstream_port, upstream_path):
    async def handle(connection):
        session = RelaySession(upstream_port, upstream_path,
                               connection.request.headers["Authorization"])
        await session.serve(connection)

    async with serve(handle, "127.0.0.1", port, process_request=check_handshake,
                     max_size=MAX_MESSAGE, compression=None):
        await asyncio.Future()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", type=int)
    parser.add_argument("upstream_port", type=int)
    parser.add_argument("upstream_path")
    args = parser.parse_args()
    if not args.upstream_path.startswith("/") or args.upstream_path.startswith("//"):
        parser.error("upstream_path must be an absolute HTTP path")
    asyncio.run(run(args.port, args.upstream_port, args.upstream_path))
