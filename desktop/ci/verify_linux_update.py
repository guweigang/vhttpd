"""Run the normal Workbench package on Xvfb using an isolated Releases fixture."""
import csv
import ctypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

EXPECTED = "https://github.com/guweigang/vhttpd/releases/tag/desktop-v0.2.0"
ROOT = Path(__file__).resolve().parent
EXE = Path(sys.argv[1]).resolve()
OUT = Path(sys.argv[2]).resolve()
OUT.mkdir(parents=True, exist_ok=True)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def wait(label, callback, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = callback()
        if value:
            return value
        time.sleep(0.35)
    raise AssertionError(label)


def assert_no_tray():
    x11 = ctypes.CDLL("libX11.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.XInternAtom.restype = ctypes.c_ulong
    x11.XGetSelectionOwner.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    x11.XGetSelectionOwner.restype = ctypes.c_ulong
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    display = x11.XOpenDisplay(None)
    assert display
    try:
        atom = x11.XInternAtom(display, b"_NET_SYSTEM_TRAY_S0", 0)
        assert x11.XGetSelectionOwner(display, atom) == 0, "A tray manager is running"
    finally:
        x11.XCloseDisplay(display)


def capture(window, name):
    dest = OUT / f"{name}.png"
    run("import", "-window", window, str(dest))
    return dest


def locate(image, word, box, language="chi_sim+eng"):
    left, top, width, height = box
    image_data = subprocess.check_output((
        "convert", str(image), "-crop", f"{width}x{height}+{left}+{top}",
        "+repage", "-resize", "300%", "png:-",
    ))
    tsv = subprocess.check_output((
        "tesseract", "stdin", "stdout", "-l", language, "--psm", "11", "tsv",
    ), input=image_data, stderr=subprocess.DEVNULL).decode()
    lines = {}
    for row in csv.DictReader(io.StringIO(tsv), delimiter="\t"):
        token = row["text"].strip()
        if token:
            key = tuple(row[k] for k in ("block_num", "par_num", "line_num"))
            lines.setdefault(key, []).append((token, row))
    needle = re.sub(r"\s+", "", word).lower()
    for tokens in lines.values():
        text = ""
        spans = []
        for token, row in tokens:
            start = len(text)
            text += re.sub(r"\s+", "", token).lower()
            spans.append((start, len(text), row))
        at = text.find(needle)
        if at < 0:
            continue
        boxes = [row for start, end, row in spans if start < at + len(needle) and end > at]
        x = min(int(row["left"]) for row in boxes)
        y = min(int(row["top"]) for row in boxes)
        right = max(int(row["left"]) + int(row["width"]) for row in boxes)
        bottom = max(int(row["top"]) + int(row["height"]) for row in boxes)
        return left + (x + right) // 6, top + (y + bottom) // 6
    return None


def click(window, position):
    run("xdotool", "mousemove", "--window", window, *map(str, position), "click", "1")


def write_fixture():
    config = OUT / "cert.cnf"
    config.write_text("""[req]
prompt=no
distinguished_name=dn
x509_extensions=v3
[dn]
CN=api.github.com
[v3]
subjectAltName=DNS:api.github.com
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
""")
    cert, key = OUT / "cert.pem", OUT / "key.pem"
    run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
        "-config", str(config), "-keyout", str(key), "-out", str(cert),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    payload = (ROOT / "linux-update-fixture.json").read_bytes()
    requests = []

    class Proxy(BaseHTTPRequestHandler):
        def do_CONNECT(self):
            if self.path != "api.github.com:443":
                self.send_error(403)
                return
            self.send_response(200)
            self.end_headers()
            with context.wrap_socket(self.connection, server_side=True) as conn:
                stream = conn.makefile("rb")
                request = stream.readline(8192).decode("ascii").split()
                while stream.readline(8192) not in (b"", b"\r\n"):
                    pass
                assert request[:2] == ["GET", "/repos/guweigang/vhttpd/releases?per_page=50&page=1"]
                requests.append(request[1])
                conn.sendall(f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode() + payload)
            self.close_connection = True

    server = ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, cert, requests


def main():
    assert_no_tray()
    server, cert, requests = write_fixture()
    browser = OUT / "fixture-browser"
    browser.write_text('#!/bin/sh\nexec /usr/bin/python3 "' + str(ROOT / "linux_update_browser.py") + '" "$@"\n')
    browser.chmod(0o700)
    home = OUT / "home"
    home.mkdir(exist_ok=True)
    proxy = f"http://127.0.0.1:{server.server_port}"
    env = {
        "PATH": "/usr/bin:/bin", "DISPLAY": os.environ["DISPLAY"],
        "XAUTHORITY": os.environ["XAUTHORITY"], "HOME": str(home),
        "LANG": "C.UTF-8", "UI2_GL_VENDOR": "mesa_only", "LIBGL_ALWAYS_SOFTWARE": "1",
        "HTTPS_PROXY": proxy, "https_proxy": proxy, "CURL_CA_BUNDLE": str(cert),
        "BROWSER": str(browser), "VHTTPD_UPDATE_BROWSER_EVIDENCE": str(OUT),
        "VHTTPD_DESKTOP_REGISTRY": str(home / "projects.json"),
    }
    with (OUT / "workbench.log").open("w") as log:
        app = subprocess.Popen([str(EXE)], env=env, cwd=home, stdout=log, stderr=log)
        try:
            def window_id():
                assert app.poll() is None, "Workbench exited during startup"
                found = subprocess.run(("xdotool", "search", "--onlyvisible", "--pid", str(app.pid)),
                                       text=True, capture_output=True)
                if found.returncode == 0:
                    return found.stdout.splitlines()[0]
                found = subprocess.run(("xdotool", "search", "--onlyvisible", "--name", "vhttpd.*工作台"),
                                       text=True, capture_output=True)
                return found.stdout.splitlines()[0] if found.returncode == 0 else None

            window = wait("Workbench did not open without a tray", window_id)
            assert_no_tray()
            help_title = wait("Help menu not visible", lambda: locate(
                capture(window, "startup"), "帮助", (0, 0, 700, 27)))
            click(window, help_title)
            update_menu = wait("Check for updates menu not visible", lambda: locate(
                capture(window, "help-menu"), "检查更新", (0, 26, 900, 140)))
            click(window, update_menu)
            wait("Mock GitHub release response was not requested", lambda: requests)
            wait("New version 0.2.0 not displayed", lambda: locate(
                capture(window, "new-version"), "0.2.0", (0, 100, 600, 260), "eng"))
            button = wait("GitHub button not displayed", lambda: locate(
                capture(window, "new-version"), "GitHub", (600, 140, 380, 270), "eng"))
            click(window, button)
            receipt = OUT / "browser.json"
            result = wait("Browser did not commit the GitHub Release URL",
                          lambda: json.loads(receipt.read_text()) if receipt.exists() else None,
                          seconds=45)
            assert result["requested"] == EXPECTED and result["committed"] == EXPECTED, result
            (OUT / "acceptance.json").write_text(json.dumps({
                "architecture": platform.machine(), "no_tray": True, "version": "0.2.0",
                "browser": result, "fixture": True,
            }, indent=2) + "\n")
            print(f"PASS {platform.machine()}: no tray, Desktop 0.2.0, browser {EXPECTED}")
        finally:
            app.terminate()
            try:
                app.wait(timeout=8)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
            server.shutdown()
            cert.unlink(missing_ok=True)
            (OUT / "key.pem").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
