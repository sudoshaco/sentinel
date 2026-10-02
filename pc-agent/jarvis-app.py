#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Jarvis Desktop-Client: oeffnet das Jarvis-Dashboard als natives Fenster (WebView2),
kein Browser. Startet das Backend (jarvis-console.py) selbst, falls noch nicht laeuft.
"""
import os, socket, threading, importlib.util
import webview

HERE = os.path.dirname(os.path.abspath(__file__))

def port_up(h="127.0.0.1", p=8900):
    s = socket.socket(); s.settimeout(0.6)
    try:
        s.connect((h, p)); return True
    except Exception:
        return False
    finally:
        try: s.close()
        except Exception: pass

if not port_up():
    spec = importlib.util.spec_from_file_location("jconsole", os.path.join(HERE, "jarvis-console.py"))
    jc = importlib.util.module_from_spec(spec); spec.loader.exec_module(jc)
    from http.server import ThreadingHTTPServer
    srv = ThreadingHTTPServer((jc.HOST, jc.PORT), jc.H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

webview.create_window("Jarvis", "http://127.0.0.1:8900",
                      width=1320, height=860, min_size=(900, 640),
                      background_color="#0B0709")
webview.start()
