#!/usr/bin/env python3
"""Build template/resources/Driver Icons.sketch from Control4's OS 3 icon template.

Runs each script in steps/ in order through Sketch's MCP server, against a copy of
Control4's file. Sketch must be running with its MCP server started.
"""

import argparse
import hashlib
import json
import pathlib
import shutil
import sys
import urllib.request
import zipfile

MCP_URL = "http://localhost:31126/mcp"
HERE = pathlib.Path(__file__).resolve().parent
STEPS = HERE / "steps"
LOGO = HERE / "finite-labs-logo.svg"
OUTPUT = HERE.parent / "template" / "resources" / "Driver Icons.sketch"

# Control4's file, pinned to the commit it was last changed in.
SOURCE_URL = (
    "https://raw.githubusercontent.com/snap-one/docs-driverworks/"
    "4299862977730edbe006f52e0fc283bfc798e8a1/icon_templates/OS3/templates/"
    "Device%20%26%20Service%20Icon%20Template%203.0.sketch"
)
SOURCE_SHA256 = "43a7578997817ea399ac8d009c767ba6e46420dfa13c0bdcdb61fe6a12c25a65"

# Control4's two icon artboards. Sketch 2026 turns on "trim transparent pixels"
# for them when it opens the old file, which crops every icon export.
ICON_ARTBOARDS = {
    "6F1BF787-D38E-4F93-A465-ACE3C57FFE75",
    "0362998B-27D8-4F37-89B8-5831E90F6779",
}


class Sketch:
    def __init__(self, url):
        self.url = url
        self.session = None
        self.next_id = 1
        self.request(
            "initialize",
            {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {"name": "icon-template-build", "version": "1"},
            },
        )
        self.request("notifications/initialized", None, notify=True)

    def request(self, method, params, notify=False):
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        if not notify:
            body["id"] = self.next_id
            self.next_id += 1
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(
            self.url, json.dumps(body).encode(), headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=600) as resp:
            self.session = resp.headers.get("Mcp-Session-Id") or self.session
            raw = resp.read().decode()
            if notify:
                return None
            if resp.headers.get("Content-Type", "").startswith("text/event-stream"):
                raw = "\n".join(
                    line[5:].strip()
                    for line in raw.splitlines()
                    if line.startswith("data:")
                )
        msg = json.loads(raw)
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error']}")
        return msg["result"]

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            texts = [c.get("text", "") for c in result.get("content", [])]
            raise RuntimeError(f"{name} failed: {' '.join(texts)}")
        return result.get("content", [])

    def run(self, title, script):
        content = self.tool("run_code", {"title": title, "script": script})
        text = "\n".join(c.get("text", "") for c in content if c["type"] == "text")
        report = None
        for line in text.splitlines():
            line = line.strip().strip("'")
            if line.startswith("{"):
                report = json.loads(line)
        if not report or not report.get("ok"):
            raise RuntimeError(f"{title}: {text.strip() or 'no report'}")
        return report


def close(sketch, path):
    sketch.run(
        "Close document",
        "const sketch = require('sketch');\n"
        "var docs = sketch.getDocuments().filter(function (d) {\n"
        f"  return decodeURIComponent(d.path) === {json.dumps(str(path))};\n"
        "});\n"
        "docs.forEach(function (d) { d.close(); });\n"
        "console.log(JSON.stringify({ ok: true, closed: docs.length }));",
    )


def untrim_icon_artboards(path):
    tmp = path.with_name(path.name + ".tmp")
    found = set()
    with zipfile.ZipFile(path) as src, zipfile.ZipFile(tmp, "w") as dst:
        for item in src.infolist():
            data = src.read(item)
            if item.filename.startswith("pages/"):
                page = json.loads(data)
                for layer in page["layers"]:
                    if layer["do_objectID"] in ICON_ARTBOARDS:
                        layer["exportOptions"]["shouldTrim"] = False
                        found.add(layer["do_objectID"])
                data = json.dumps(page, ensure_ascii=False).encode()
            dst.writestr(item, data)
    if found != ICON_ARTBOARDS:
        tmp.unlink()
        raise RuntimeError(f"icon artboards not found: {ICON_ARTBOARDS - found}")
    tmp.replace(path)


def download(path):
    with urllib.request.urlopen(SOURCE_URL, timeout=60) as resp:
        data = resp.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SOURCE_SHA256:
        raise RuntimeError(f"Control4's file changed: sha256 {digest}")
    path.write_bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--source",
        type=pathlib.Path,
        help="Control4's .sketch file (default: download it)",
    )
    parser.add_argument("--output", type=pathlib.Path, default=OUTPUT)
    args = parser.parse_args()

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    sketch = Sketch(MCP_URL)
    close(sketch, output)
    if args.source:
        shutil.copyfile(args.source, output)
    else:
        download(output)

    context = {
        "__DOCUMENT__": json.dumps(str(output)),
        "__FINITE_LABS_LOGO_SVG__": json.dumps(LOGO.read_text()),
    }
    for step in sorted(STEPS.glob("*.js")):
        script = step.read_text()
        for token, value in context.items():
            script = script.replace(token, value)
        title = step.stem.split("-", 1)[1].replace("-", " ").capitalize()
        report = sketch.run(title, script)
        print(f"{step.name}: {json.dumps(report)}")

    close(sketch, output)
    untrim_icon_artboards(output)
    print(f"wrote {output}")


if __name__ == "__main__":
    sys.exit(main())
