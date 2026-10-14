#!/usr/bin/env python3
"""Inkwell for Claude: a tiny local MCP server (standard library only, no API key).

Inkwell on your iPad keeps page images and an index in your iCloud Drive
(Settings > Share with Claude on my Mac). This server reads them from the Mac's copy of that folder and
hands them to Claude, so you can ask "what am I working on?" without taking a screenshot.
"""
import base64
import glob
import json
import os
import subprocess
import sys
import time

PROTOCOL = "2024-11-05"
CANDIDATES = [
    os.path.expanduser("~/Library/Mobile Documents/iCloud~com~ilyas~inkwell/Documents/Inkwell/ForClaude"),
    os.path.expanduser("~/Library/Mobile Documents/iCloud~com~ilyas~inkwell/Documents/Inkwell/ForClaude"),
]


def folder():
    override = os.environ.get("INKWELL_FOLDER")
    if override:
        return override
    for c in CANDIDATES:
        if os.path.isdir(c):
            return c
    return CANDIDATES[0]


def ensure_local(path):
    """iCloud may keep a file as a placeholder until asked; ask, then wait briefly."""
    if os.path.exists(path):
        return True
    try:
        subprocess.run(["brctl", "download", path], timeout=5, capture_output=True)
    except Exception:
        pass
    for _ in range(20):
        if os.path.exists(path):
            return True
        time.sleep(0.5)
    return False


def load_index():
    path = os.path.join(folder(), "index.json")
    if not ensure_local(path):
        raise RuntimeError(
            "No Inkwell pages found yet. On the iPad open Inkwell > Settings, turn on iCloud sync and "
            "'Share with Claude on my Mac', then write something and wait a few seconds. Expected folder: " + folder()
        )
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def find_notebook(index, query):
    books = index.get("notebooks", [])
    q = (query or "").strip().lower()
    if not q:
        last = index.get("lastEditedNotebook")
        for b in books:
            if b["id"] == last:
                return b
        # Nothing edited since Inkwell started: use the newest notebook that has writing in it.
        return next((b for b in books if any(p["hasInk"] for p in b["pages"])), books[0] if books else None)
    for b in books:
        if b["id"].lower() == q or b["name"].lower() == q:
            return b
    matches = [b for b in books if q in b["name"].lower()]
    return matches[0] if matches else None


def page_image(page_id):
    path = os.path.join(folder(), "pages", page_id + ".png")
    if not ensure_local(path):
        return None
    with open(path, "rb") as f:
        return {"type": "image", "data": base64.b64encode(f.read()).decode("ascii"), "mimeType": "image/png"}


def describe(book, index):
    mark = " (you edited this last)" if book["id"] == index.get("lastEditedNotebook") else ""
    where = book["folder"] + "/" if book["folder"] else ""
    return f'{where}{book["name"]}{mark}: {len(book["pages"])} page(s), modified {book["modified"]}'


# ---------- tools ----------

def tool_list(_args):
    index = load_index()
    books = index.get("notebooks", [])
    if not books:
        return [{"type": "text", "text": "No notebooks in the index yet."}]
    lines = [describe(b, index) for b in books]
    return [{"type": "text", "text": "Notebooks in Inkwell (newest first):\n" + "\n".join(lines)}]


def tool_current(_args):
    index = load_index()
    book = find_notebook(index, None)
    page_id = index.get("lastEditedPage")
    if not book:
        return [{"type": "text", "text": "No notebooks yet."}]
    page = next((p for p in book["pages"] if p["id"] == page_id), None) or next((p for p in book["pages"] if p["hasInk"]), None)
    if not page:
        return [{"type": "text", "text": f'"{book["name"]}" has no written pages yet.'}]
    img = page_image(page["id"])
    head = f'{book["name"]}, page {page["number"]} (last updated {index["updated"]}).'
    return [{"type": "text", "text": head}] + ([img] if img else [{"type": "text", "text": "The image has not synced from iCloud yet. Try again in a moment."}])


def tool_page(args):
    index = load_index()
    book = find_notebook(index, args.get("notebook"))
    if not book:
        return [{"type": "text", "text": "No notebook matches that name. Use inkwell_list_notebooks."}]
    number = int(args.get("page", 1))
    page = next((p for p in book["pages"] if p["number"] == number), None)
    if not page:
        return [{"type": "text", "text": f'"{book["name"]}" has {len(book["pages"])} page(s); there is no page {number}.'}]
    img = page_image(page["id"])
    if not img:
        return [{"type": "text", "text": f'Page {number} of "{book["name"]}" has no image (it is blank, or has not synced yet).'}]
    return [{"type": "text", "text": f'{book["name"]}, page {number}:'}, img]


def tool_notebook(args):
    index = load_index()
    book = find_notebook(index, args.get("notebook"))
    if not book:
        return [{"type": "text", "text": "No notebook matches that name. Use inkwell_list_notebooks."}]
    limit = max(1, min(int(args.get("max_pages", 6)), 12))
    out = [{"type": "text", "text": f'{book["name"]}: {len(book["pages"])} page(s). Showing pages with writing, up to {limit}.'}]
    shown = 0
    for p in book["pages"]:
        if shown >= limit:
            break
        if not p["hasInk"]:
            continue
        img = page_image(p["id"])
        if img:
            out += [{"type": "text", "text": f'Page {p["number"]}:'}, img]
            shown += 1
    if shown == 0:
        out.append({"type": "text", "text": "Nothing written in this notebook has synced yet."})
    return out


TOOLS = {
    "inkwell_current_page": (
        "The page I was just writing on in Inkwell on my iPad (the most recently edited page), as an image. Use this whenever I say 'look at what I'm doing' or 'check my notes'.",
        {"type": "object", "properties": {}},
        tool_current,
    ),
    "inkwell_list_notebooks": (
        "List my Inkwell notebooks with their folders, page counts and last-modified times.",
        {"type": "object", "properties": {}},
        tool_list,
    ),
    "inkwell_read_page": (
        "Show one page of an Inkwell notebook as an image.",
        {"type": "object", "properties": {
            "notebook": {"type": "string", "description": "Notebook name (or part of it)."},
            "page": {"type": "integer", "description": "Page number, starting at 1.", "default": 1}},
         "required": ["notebook"]},
        tool_page,
    ),
    "inkwell_read_notebook": (
        "Show the written pages of an Inkwell notebook as images (up to max_pages).",
        {"type": "object", "properties": {
            "notebook": {"type": "string", "description": "Notebook name (or part of it)."},
            "max_pages": {"type": "integer", "default": 6}},
         "required": ["notebook"]},
        tool_notebook,
    ),
}


# ---------- JSON-RPC over stdio ----------

def reply(msg_id, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        body["error"] = error
    else:
        body["result"] = result
    sys.stdout.write(json.dumps(body) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    msg_id = msg.get("id")
    if method == "initialize":
        version = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL
        reply(msg_id, {
            "protocolVersion": version,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "inkwell", "version": "0.1.0"},
        })
    elif method == "ping":
        reply(msg_id, {})
    elif method == "tools/list":
        reply(msg_id, {"tools": [
            {"name": n, "description": d, "inputSchema": s} for n, (d, s, _f) in TOOLS.items()
        ]})
    elif method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        if name not in TOOLS:
            reply(msg_id, error={"code": -32602, "message": f"Unknown tool {name}"})
            return
        try:
            content = TOOLS[name][2](params.get("arguments") or {})
            reply(msg_id, {"content": content})
        except Exception as e:  # report to the model, don't crash the server
            reply(msg_id, {"content": [{"type": "text", "text": str(e)}], "isError": True})
    elif msg_id is not None:
        reply(msg_id, error={"code": -32601, "message": f"Method not found: {method}"})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            handle(json.loads(line))
        except json.JSONDecodeError:
            continue


if __name__ == "__main__":
    main()
