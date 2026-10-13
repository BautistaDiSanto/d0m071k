"""Local bridge so other front-ends (the Godot app) can drive the lights.

Listens on 127.0.0.1 only. Run: python server.py
  GET  /lights   -> [{"name": ..., "id": ...}, ...]
  POST /command  {"target": "all" | <name>, "action": "power"|"brightness"|"colour", "args": [...]}
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from lights import load_bulbs

PORT = 8765
ACTIONS = {"power", "brightness", "colour"}
bulbs = load_bulbs()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/lights":
            self._send(200, [{"name": b.name, "id": b.id} for b in bulbs])
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/command":
            return self._send(404, {"error": "not found"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            action, args, target = req["action"], req.get("args", []), req.get("target", "all")
        except (ValueError, KeyError):
            return self._send(400, {"error": "bad request"})
        if action not in ACTIONS:
            return self._send(400, {"error": f"unknown action {action!r}"})
        targets = bulbs if target == "all" else [b for b in bulbs if b.name == target]
        if not targets:
            return self._send(404, {"error": f"no light named {target!r}"})
        errors = []
        for b in targets:
            try:
                getattr(b, action)(*args)
            except Exception as e:
                errors.append(str(e))
        self._send(200 if not errors else 502, {"ok": not errors, "errors": errors})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"Domotic bridge on http://127.0.0.1:{PORT} ({len(bulbs)} lights)")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
