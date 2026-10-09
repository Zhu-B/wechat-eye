#!/usr/bin/env python3
"""wechat-eye: minimal stdio MCP server, pure stdlib (no pip deps).

Tools:
  screenshot - native-resolution capture (DPI aware), full screen or cropped to a
               process window (default Weixin = WeChat 4.x); returns path + geometry,
               optionally attaches the png inline (gate test for image-in-tool-result).
  ocr        - Windows built-in OCR (zh-Hans) on an image file; returns text lines.

Protocol: newline-delimited JSON-RPC on stdin/stdout. Logs to server.log (stderr too).
"""
import base64
import json
import os
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
BASE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(BASE, "server.log")


def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except Exception:
        pass


def run_ps(script, *args):
    cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
           "-File", os.path.join(BASE, script)] + [str(a) for a in args]
    try:
        # stdin=DEVNULL is critical: our own stdin is the MCP channel,
        # an inheriting child would eat pending JSON-RPC lines from it
        r = subprocess.run(cmd, capture_output=True, timeout=120, stdin=subprocess.DEVNULL)
        out = (r.stdout or b"").decode("utf-8", "replace").strip()
        err = (r.stderr or b"").decode("utf-8", "replace").strip()
        return r.returncode, out, err
    except subprocess.TimeoutExpired:
        return 1, "", "timeout after 120s"


TOOLS = [
    {
        "name": "screenshot",
        "description": "Native-resolution screenshot (DPI aware). mode='window' captures the main window of a process (default pattern Weixin = WeChat 4.x) via PrintWindow, so windows covering it do not pollute the content (automatic fallback to a screen crop); crop='chat' with window mode keeps only the right-hand chat area (left session list dropped). mode='full' captures the whole virtual screen. Returns saved path + geometry as text, and the png itself inline unless attach_image=false.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {"type": "string", "enum": ["window", "full"],
                         "description": "default: window"},
                "process": {"type": "string",
                            "description": "process name regex for window mode; default 'Weixin'; use 'WeChat|Weixin' to match both generations"},
                "crop": {"type": "string", "enum": ["chat"],
                         "description": "crop='chat' keeps only the right-hand chat area of the window (left session list dropped); window mode only"},
                "out": {"type": "string",
                        "description": "output png path; default wechat-eye/out/shot_<ts>.png"},
                "attach_image": {"type": "boolean",
                                 "description": "also return the png as inline image content (default true); set false if the client cannot render tool-result images"},
            },
            "required": [],
        },
    },
    {
        "name": "ocr",
        "description": "Windows built-in OCR (zh-Hans) on an image file. Returns recognized text lines. Call after screenshot to read chat text reliably.",
        "inputSchema": {
            "type": "object",
            "properties": {"image": {"type": "string", "description": "path to the png"}},
            "required": ["image"],
        },
    },
]


def call_screenshot(args):
    mode = args.get("mode", "window")
    process = args.get("process", "Weixin")
    crop = args.get("crop")
    out = args.get("out") or os.path.join(BASE, "out", "shot_%d.png" % int(time.time()))
    params = ["capture.ps1", "-Mode", mode, "-ProcessPattern", process, "-OutFile", out]
    if crop:
        params += ["-CropArea", crop]
    rc, o, e = run_ps(*params)
    log("screenshot mode=%s process=%s crop=%s rc=%d -> %s" % (mode, process, crop, rc, out))
    if rc != 0:
        text = ("CAPTURE FAILED (rc=%d)\n%s\n%s" % (rc, o, e)).strip()
    else:
        text = o
    content = [{"type": "text", "text": text}]
    # Gate test: attach the png inline. Officially supported (MCP image content);
    # if this endpoint renders it, the model sees the screen without Read.
    if rc == 0 and args.get("attach_image", True) and os.path.exists(out):
        try:
            with open(out, "rb") as f:
                content.append({"type": "image",
                                "data": base64.b64encode(f.read()).decode("ascii"),
                                "mimeType": "image/png"})
        except Exception as ex:
            content[0]["text"] += "\n(image attach failed: %s)" % ex
    return content


def call_ocr(args):
    image = args.get("image", "")
    rc, o, e = run_ps("ocr.ps1", "-Image", image)
    log("ocr image=%s rc=%d" % (image, rc))
    text = o if rc == 0 else ("OCR FAILED (rc=%d)\n%s\n%s" % (rc, o, e)).strip()
    return [{"type": "text", "text": text}]


def call_tool(name, arguments):
    if name == "screenshot":
        return call_screenshot(arguments or {})
    if name == "ocr":
        return call_ocr(arguments or {})
    raise ValueError("unknown tool: %s" % name)


def reply(mid, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result},
                                ensure_ascii=False) + "\n")
    sys.stdout.flush()


def reply_err(mid, code, message):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid,
                                 "error": {"code": code, "message": message}}) + "\n")
    sys.stdout.flush()


def main():
    log("server started")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if "id" not in msg:
            continue  # notification, no reply needed
        method = msg.get("method", "")
        mid = msg["id"]
        if method == "initialize":
            pv = (msg.get("params") or {}).get("protocolVersion", "2025-06-18")
            reply(mid, {"protocolVersion": pv,
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "wechat-eye", "version": "0.1.0"}})
        elif method == "tools/list":
            reply(mid, {"tools": TOOLS})
        elif method == "tools/call":
            p = msg.get("params") or {}
            try:
                content = call_tool(p.get("name", ""), p.get("arguments") or {})
                reply(mid, {"content": content, "isError": False})
            except Exception as ex:
                reply(mid, {"content": [{"type": "text", "text": "error: %s" % ex}],
                            "isError": True})
        elif method == "ping":
            reply(mid, {})
        else:
            reply_err(mid, -32601, "method not found: %s" % method)
    log("server stopped")


if __name__ == "__main__":
    main()
