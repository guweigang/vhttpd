"""Exercise the Desktop MCP edit and revoke flow through a public WSS endpoint."""

import json
from pathlib import Path
import sys
import time

from websockets.exceptions import ConnectionClosedError
from websockets.sync.client import connect


def open_session(url, token):
    return connect(url, additional_headers={"Authorization": f"Bearer {token}"})


def rpc(ws, method, params, request_id=1):
    message = {"jsonrpc": "2.0", "method": method, "params": params}
    if request_id is not None:
        message["id"] = request_id
    ws.send(json.dumps(message))
    if request_id is None:
        return
    while True:
        response = json.loads(ws.recv(timeout=35))
        if response.get("id") == request_id:
            assert "error" not in response, response
            return response["result"]


def initialize(ws):
    return rpc(ws, "initialize", {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": "vhttpd-wss-smoke", "version": "1"},
    })


def exercise(ws, listener):
    rpc(ws, "notifications/initialized", {}, None)
    tools = {tool["name"] for tool in rpc(ws, "tools/list", {})["tools"]}
    assert {"context_get", "files_read", "changes_apply", "application_request"} <= tools

    def call(name, **arguments):
        result = rpc(ws, "tools/call", {"name": name, "arguments": arguments})
        assert not result.get("isError"), result
        return json.loads(result["content"][0]["text"])

    revision = call("context_get")["binding_revision"]

    def bound(name, **arguments):
        return call(name, binding_revision=revision, **arguments)

    source = bound("files_read", path="main.mjs")
    original = source["content"]
    source["content"] = 'export default ctx => ctx.json({message:"relay-verified"},200)'
    change = bound("changes_prepare", files=[source])["id"]
    assert bound("changes_validate", id=change)["valid"]
    bound("changes_apply", id=change)
    try:
        assert bound("runtime_start")["accepted"]
        deadline = time.monotonic() + 100
        while True:
            status = bound("runtime_status")
            if status["readiness"] == "ready":
                break
            assert status["phase"] in ("starting", "running"), status
            assert time.monotonic() < deadline, status
            time.sleep(0.5)
        response = bound("application_request", listener=listener, path="/api/hello")
        assert int(response["status"]) == 200
        assert json.loads(response["body"])["message"] == "relay-verified"
    finally:
        assert bound("runtime_stop")["stopped"]
        assert bound("changes_restore", id=change)["restored"]
        assert bound("files_read", path="main.mjs")["content"] == original
    print("WSS tools/list, edit, HTTP 200 business response, and source restore passed")


def main(url, token_path, listener, phase):
    token = Path(token_path).read_text()
    if phase == "revoked":
        with open_session(url, token) as ws:
            try:
                initialize(ws)
            except ConnectionClosedError as error:
                assert error.rcvd is not None and error.rcvd.code == 1008, error
                assert error.rcvd.reason == "MCP upstream HTTP 410", error
                print("WSS request with revoked grant was rejected")
                return
        raise AssertionError("Revoked grant accepted")
    for attempt in range(20):
        ws = open_session(url, token)
        try:
            initialize(ws)
        except ConnectionClosedError as error:
            ws.close()
            if attempt == 19 or error.rcvd is None or error.rcvd.reason != "MCP upstream HTTP 503":
                raise
            time.sleep(0.25)
        else:
            with ws:
                exercise(ws, listener)
            return


if __name__ == "__main__":
    main(*sys.argv[1:])
