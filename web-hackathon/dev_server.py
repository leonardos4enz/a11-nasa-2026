"""Local preview of the calendar without Node (for this PC, which has only Python).

- Serves web-hackathon/public.
- Proxies GET /api/harmonized/index, /api/harmonized/areas/<id> and POST /api/harmonized/polygon to the deployed
  site (real data), so the page shows what production shows.
- MOCKS POST /api/harmonized/raw and POST /api/hotspots with invented numbers, only to exercise the page before
  those endpoints are deployed. The real implementations are in server.js.

    py web-hackathon/dev_server.py [port] [upstream]      (default 8771, https://emberatlas.ink)
"""
import json
import os
import random
import sys
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("PORT") or (sys.argv[1] if len(sys.argv) > 1 else 8771))
UPSTREAM = sys.argv[2] if len(sys.argv) > 2 else "https://emberatlas.ink"
PUBLIC = Path(__file__).resolve().parent / "public"


def upstream(method, path, body=None):
    req = urllib.request.Request(UPSTREAM + path, data=body, method=method,
                                 headers={"Content-Type": "application/json", "User-Agent": "a11-dev-preview"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=str(PUBLIC), **k)

    def send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/harmonized/"):
            try:
                return self.send(200, upstream("GET", self.path))
            except Exception as e:  # noqa: BLE001
                return self.send(200, json.dumps({"error": str(e)}).encode())
        return super().do_GET()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path == "/api/harmonized/polygon":
            return self.send(200, upstream("POST", self.path, body))
        req = json.loads(body or b"{}")
        # Real endpoints first once they are deployed; the mocks below are the fallback.
        if self.path == "/api/harmonized/raw" or (self.path == "/api/hotspots" and req.get("format") == "json"):
            try:
                out = upstream("POST", self.path, body)
                if b'"error"' not in out[:200]:
                    return self.send(200, out)
            except Exception:  # noqa: BLE001
                pass
        if self.path == "/api/harmonized/raw":
            return self.send(200, json.dumps({"months": self.mock_raw(req)}).encode())
        if self.path == "/api/hotspots":
            return self.mock_hotspots(req)
        if self.path == "/api/chat":
            out = self.mock_chat(req)
            if req.get("stream") and out.get("done"):  # stream like server.js: progress events, then the final answer
                import time
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                def ev(o, wait=0.0):
                    self.wfile.write((json.dumps(o) + "\n").encode()); self.wfile.flush(); time.sleep(wait)
                ev({"type": "start"})
                ev({"type": "thinking", "step": 1}, 1.2)
                for d in out["done"]:
                    ev({"type": "step", **d, "state": "run", "found": []}, 2.0)
                    ev({"type": "step", **d, "state": "ok" if d.get("ok", True) else "fail"})
                ev({"type": "thinking", "step": 2}, 1.2)
                ev({"type": "checking"}, 0.6)
                ev({"type": "final", **out})
                return
            return self.send(200, json.dumps(out).encode())
        self.send(404, b'{"error":"not found"}')

    # MOCK of the Ember agent (the real one is chat-agent.js): turns "busca X", "pon <month> <year>", "dark mode",
    # "season tab" or "demo" into page actions so the agent cursor (public/agent.js) can be tested without a model.
    MONTHS = {m: i + 1 for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
    MONTHS.update({"ene": 1, "abr": 4, "ago": 8, "dic": 12})

    def mock_chat(self, req):
        import re
        if req.get("toolResults"):
            if req.get("final"):
                return {"reply": "(mock) Final answer: out of steps, answering with what I have."}
            ids = [str(r.get("id", "")) for r in req["toolResults"]]
            if any(i.startswith("loop_") for i in ids):  # "loop": an agent that never stops acting
                n = random.randint(1, 11)
                return {"reply": "", "actions": [{"id": f"loop_{random.random()}", "name": "set_month", "args": {"year": 2020, "month": n}}]}
            res = [r.get("result") or {} for r in req["toolResults"]]
            view = next((r["view"] for r in reversed(res) if isinstance(r, dict) and r.get("view")), None)
            errs = [r.get("error") for r in res if isinstance(r, dict) and r.get("ok") is False]
            if errs:
                return {"reply": "(mock) I could not do it: " + "; ".join(errs)}
            if view:
                return {"reply": f"(mock) Done. **{view['area']} · {view['period']}**: {view['count']} hotspots, "
                                 f"*{view['category']}* (typical {view['typical']})."}
            return {"reply": "(mock) Done."}
        q = str(req.get("message", "")).split("\n\n[App context")[0].strip()
        low = q.lower()
        actions = []
        m = re.search(r"(?:busca|search|find|show|go to)\s+(.+?)(?:\s+(?:y|and)\s+|$)", q, re.I)
        if m:
            actions.append(("select_area", {"query": m.group(1).strip(" .")}))
        m = re.search(r"\b(ene\w*|jan\w*|feb\w*|mar\w*|abr\w*|apr\w*|may\w*|jun\w*|jul\w*|ago\w*|aug\w*|sep\w*|oct\w*|nov\w*|dic\w*|dec\w*)\s+(?:de\s+|del\s+)?(\d{4})", low)
        if m:
            actions.append(("set_month", {"year": int(m.group(2)), "month": self.MONTHS[m.group(1)[:3]]}))
        for word, tab in (("season", "season"), ("tempor", "season"), ("method", "method"), ("report", "data"), ("burn", "burn")):
            if word in low:
                actions.append(("open_tab", {"tab": tab}))
                break
        if "dark" in low or "oscuro" in low:
            actions.append(("set_theme", {"theme": "dark"}))
        if "light" in low or "claro" in low:
            actions.append(("set_theme", {"theme": "light"}))
        if "forecast" in low or "pronóstico" in low:
            actions.append(("set_layer", {"layer": "forecast", "visible": True}))
        if "descarga" in low or "download" in low:
            f = "calendar_png" if ("png" in low or "imagen" in low) else "monthly_csv"
            actions.append(("download_report", {"file": f, "range": "this_year"}))
        if "loop" in low:
            return {"reply": "", "actions": [{"id": "loop_0", "name": "get_month_data", "args": {"year": 2024}}]}
        if "docs" in low or "how does" in low or "nothing" in low:  # the Researcher card (document search)
            if "twice" in low:  # two searches in one turn -> one grouped Researcher line
                return {"reply": "(mock) Two searches, one line.", "actions": [], "done": [
                    {"id": f"mock_a_{random.random()}", "label": "Searching the docs", "ok": True, "agent": "researcher",
                     "query": "MODIS VIIRS resolution difference", "found": [{"document": "Satellites and hotspots", "section": "Why VIIRS counts more"}]},
                    {"id": f"mock_b_{random.random()}", "label": "Searching the docs", "ok": True, "agent": "researcher",
                     "query": "harmonization factors by month", "found": [{"document": "How the counts are harmonized", "section": "The calibration chain"},
                                                                          {"document": "Harmonization details", "section": "Validation"}]}]}
            found = [] if "nothing" in low else [
                {"document": "How the counts are harmonized", "section": "The calibration chain"},
                {"document": "Harmonization details", "section": "Validation"},
                {"document": "Satellites and hotspots", "section": "Why VIIRS counts more"}]
            return {"reply": "(mock) MODIS is scaled to the VIIRS NOAA-20 level by region and month (docs: How the counts are harmonized).",
                    "actions": [], "done": [{"id": f"mock_docs_{random.random()}", "label": "Searching the docs", "ok": True,
                                             "agent": "researcher", "query": q[:120], "found": found}]}
        if "demo" in low:
            actions = [("select_area", {"query": "Santiago"}), ("set_month", {"year": 2024, "month": 4}),
                       ("set_hotspot_filter", {"fire_types": ["vegetation", "industrial"]}), ("open_tab", {"tab": "season"})]
        if not actions:
            return {"reply": "(mock) Try: “busca Santiago y pon abril 2024”, “season tab”, “dark mode” or “demo”."}
        return {"reply": "", "actions": [{"id": f"mock_{i}", "name": n, "args": a} for i, (n, a) in enumerate(actions)]}

    # ---- mocks (invented numbers) ----
    def area_json(self, req):
        if "area" in req:
            return json.loads(upstream("GET", f"/api/harmonized/areas/{req['area']}"))
        return {"polygon": req["polygon"], "months": json.loads(upstream("POST", "/api/harmonized/polygon",
                                                                           json.dumps({"polygon": req["polygon"]}).encode()))["months"]}

    def mock_raw(self, req):
        rnd = random.Random(7)
        out = []
        for m in self.area_json(req)["months"]:
            viirs = m["source"] == "VIIRS"
            modis = round(m["count"] / (4.2 * rnd.uniform(0.8, 1.25)))
            aqua = round(modis * rnd.uniform(0.5, 0.6))
            out.append({"month": m["month"], "modis": modis, "aqua": aqua,
                        "noaa20": m["count"] if viirs else 0, "snpp": 0, "noaa21": 0})
        return out

    def mock_hotspots(self, req):
        poly = req.get("polygon") or self.area_json(req)["polygon"]
        la = [p[0] for p in poly]
        lo = [p[1] for p in poly]
        rnd = random.Random(req.get("from"))
        types = (req.get("types") or [0]) if req.get("format") == "json" else [0]
        pts = [[round(rnd.uniform(min(la), max(la)), 4), round(rnd.uniform(min(lo), max(lo)), 4),
                round(rnd.expovariate(1 / 12), 1), rnd.choice("lnh"), (req.get("satellites") or ["NOAA20"])[0],
                rnd.choice([0] * 8 + [1, 2, 2, 3])]
               for _ in range(rnd.randint(5, 60))]
        pts = [p for p in pts if p[5] in types]
        if req.get("format") == "json":
            by_type = {}
            for p in pts:
                by_type[str(p[5])] = by_type.get(str(p[5]), 0) + 1
            return self.send(200, json.dumps({"total": len(pts), "byType": by_type, "points": pts}).encode())
        lines = ["acq_date,acq_time,latitude,longitude,sensor,satellite,confidence,conf_class,frp"]
        lines += [f"{req['from']},1830,{p[0]},{p[1]},VIIRS,{p[4]},{p[3]},{p[3]},{p[2]}" for p in pts]
        self.send(200, ("\n".join(lines) + "\n").encode(), "text/csv; charset=utf-8",
                  {"X-Rows": str(len(pts)), "X-Truncated": "0"})


if __name__ == "__main__":
    print(f"Preview on http://localhost:{PORT} (API proxied to {UPSTREAM}; raw/hotspots MOCKED)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
