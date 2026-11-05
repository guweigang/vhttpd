"""Browser selected by xdg-open in the isolated Xvfb desktop."""
import json
import os
from pathlib import Path
import sys

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import GLib, Gtk, WebKit2

out = Path(os.environ["VHTTPD_UPDATE_BROWSER_EVIDENCE"])
for key in ("HTTPS_PROXY", "https_proxy", "CURL_CA_BUNDLE"):
    os.environ.pop(key, None)
requested, = sys.argv[1:]
(out / "browser-request.txt").write_text(requested)
window = Gtk.Window(title="Workbench update verification browser")
window.set_default_size(900, 700)
web = WebKit2.WebView()
window.add(web)


def changed(view, event):
    if event == WebKit2.LoadEvent.COMMITTED:
        temp = out / "browser.tmp"
        temp.write_text(json.dumps({"requested": requested, "committed": view.get_uri()}))
        temp.replace(out / "browser.json")
        GLib.timeout_add_seconds(2, Gtk.main_quit)


web.connect("load-changed", changed)
web.connect("load-failed", lambda view, event, url, error: print(f"Browser load failed: {url}: {error}", flush=True) or False)
window.connect("destroy", Gtk.main_quit)
window.show_all()
web.load_uri(requested)
GLib.timeout_add_seconds(50, Gtk.main_quit)
Gtk.main()
