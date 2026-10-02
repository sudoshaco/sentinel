#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Jarvis Console - Backend fuer den nativen PC-Client (Jarvis.bat / jarvis-launch.ps1)."""
import json, os, ssl, time, base64, subprocess, shutil, threading, urllib.request
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
try:
    import psutil
except Exception:
    psutil = None

HOST, PORT = "127.0.0.1", 8900
OLLAMA = "http://127.0.0.1:11434"
MODEL_FULL = "qwen2.5:7b"
WS = r"C:\Users\USER\jarvis-agent"
VAULT = r"C:\Users\USER\Obsidian\vault\Coach"
CLAUDE = shutil.which("claude") or "claude"
CREATE_NO_WINDOW = 0x08000000
WAZUH_IDX = "https://100.90.173.54:9200"
def _readfile(n):
    try: return open(os.path.join(WS, n), encoding="utf-8").read().strip()
    except Exception: return ""
WAZUH_PASS = _readfile("wazuh_pass")
WAZUH_API = "https://100.90.173.54:55000"
WAZUH_API_PASS = _readfile("wazuh_api_pass")
HTB_TOKEN = _readfile("htb_token")
WELLDIR = os.path.join(WS, "wellness")
SSLCTX = ssl.create_default_context(); SSLCTX.check_hostname = False; SSLCTX.verify_mode = ssl.CERT_NONE
SYSTEM_CHAT = ("Du bist JARVIS, sud1s Assistent (im Stil von Tony Starks J.A.R.V.I.S.): souveraen, trocken, extrem knapp. "
               "Antworte Deutsch in 1-2 kurzen Saetzen. KEINE Einleitung, keine Floskeln, keine Aufzaehlungen (ausser explizit gefragt). "
               "Direkt auf den Punkt. Wenn ein Live-Status gegeben ist, nutze ihn fuer Status-Fragen.")
_cache = {"news": (0, None), "htbrank": (0, None), "apitok": (0, None), "ctx": (0, None)}

def _run(args, timeout=10):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                          encoding="utf-8", errors="replace", creationflags=CREATE_NO_WINDOW)

def interactive_user():
    try:
        out = _run(["quser"], 6)
        return len([l for l in out.stdout.splitlines()[1:] if l.strip()]) > 0
    except Exception:
        return True

def gpu_info():
    try:
        out = _run(["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
                    "--format=csv,noheader,nounits"], 6)
        u, mu, mt, tp = [x.strip() for x in out.stdout.strip().splitlines()[0].split(",")]
        return {"util": int(u), "mem_used": int(mu), "mem_total": int(mt), "temp": int(tp)}
    except Exception:
        return {"util": -1, "mem_used": 0, "mem_total": 0, "temp": -1}

def ask_ollama(prompt):
    body = json.dumps({"model": MODEL_FULL, "system": SYSTEM_CHAT, "prompt": prompt, "stream": False,
                       "options": {"temperature": 0.5, "num_predict": 180}}).encode()
    req = urllib.request.Request(f"{OLLAMA}/api/generate", body, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=180)).get("response", "").strip()

def ask_claude(prompt, plan=False):
    args = [CLAUDE, "-p", prompt] + (["--permission-mode", "plan"]
            if plan else ["--model", "haiku", "--append-system-prompt", SYSTEM_CHAT])
    p = subprocess.run(args, capture_output=True, text=True, cwd=WS, timeout=300,
                       encoding="utf-8", errors="replace", creationflags=CREATE_NO_WINDOW)
    out = (p.stdout or "").strip()
    if not out and p.stderr:
        out = "[Fehler] " + p.stderr.strip()[:800]
    return out or "(keine Antwort)"

def exec_interactive(task):
    tf = os.path.join(WS, "agent-task.txt")
    open(tf, "w", encoding="utf-8").write(task.strip())
    ps = f"$t = Get-Content -Raw -LiteralPath '{tf}'; & claude $t"
    subprocess.Popen(["cmd", "/c", "start", "Jarvis Agent", "powershell", "-NoExit", "-NoProfile", "-Command", ps],
                     cwd=WS, close_fds=True)

def pc_health():
    h = {"cpu": 0, "mem": 0, "disk": 0, "gpu": gpu_info()}
    if psutil:
        try:
            h["cpu"] = round(psutil.cpu_percent(interval=0.25))
            h["mem"] = round(psutil.virtual_memory().percent)
            h["disk"] = round(psutil.disk_usage("C:\\").percent)
            h["memgb"] = round(psutil.virtual_memory().total / 1e9, 1)
        except Exception:
            pass
    return h

def _idx(path, body):
    req = urllib.request.Request(WAZUH_IDX + path, json.dumps(body).encode(),
        {"Content-Type": "application/json",
         "Authorization": "Basic " + base64.b64encode(f"admin:{WAZUH_PASS}".encode()).decode()})
    return json.load(urllib.request.urlopen(req, timeout=12, context=SSLCTX))

def wazuh_recent():
    out = {"ok": False, "total": 0, "important": 0, "critical": 0, "levels": {}, "recent": [], "agents": 0}
    try:
        lv = _idx("/wazuh-alerts-*/_search", {"size": 0, "query": {"range": {"@timestamp": {"gte": "now-24h"}}},
                  "aggs": {"l": {"terms": {"field": "rule.level", "size": 16}},
                           "ag": {"cardinality": {"field": "agent.id"}}}})
        tot = lv["hits"]["total"]; out["total"] = tot["value"] if isinstance(tot, dict) else tot
        out["agents"] = lv.get("aggregations", {}).get("ag", {}).get("value", 0)
        for b in lv.get("aggregations", {}).get("l", {}).get("buckets", []):
            k = int(b["key"]); out["levels"][str(k)] = b["doc_count"]
            if k >= 7: out["important"] += b["doc_count"]
            if k >= 10: out["critical"] += b["doc_count"]
        rc = _idx("/wazuh-alerts-*/_search", {"size": 10, "sort": [{"@timestamp": {"order": "desc"}}],
                  "query": {"bool": {"filter": [{"range": {"@timestamp": {"gte": "now-24h"}}},
                                                {"range": {"rule.level": {"gte": 7}}}]}},
                  "_source": ["@timestamp", "agent.name", "rule.level", "rule.description", "data.srcip"]})
        for hit in rc["hits"]["hits"]:
            s = hit["_source"]
            out["recent"].append({"lvl": s.get("rule", {}).get("level"), "agent": s.get("agent", {}).get("name"),
                                  "desc": s.get("rule", {}).get("description"),
                                  "src": (s.get("data", {}) or {}).get("srcip", ""), "ts": s.get("@timestamp", "")[11:16]})
        out["ok"] = True
    except Exception as e:
        out["err"] = str(e)[:160]
    return out

def _api_token():
    c = _cache.get("apitok")
    if c and c[1] and time.time() - c[0] < 600:
        return c[1]
    req = urllib.request.Request(WAZUH_API + "/security/user/authenticate?raw=true",
        headers={"Authorization": "Basic " + base64.b64encode(f"wazuh:{WAZUH_API_PASS}".encode()).decode()})
    tok = urllib.request.urlopen(req, timeout=10, context=SSLCTX).read().decode().strip()
    _cache["apitok"] = (time.time(), tok)
    return tok

def wazuh_agents():
    out = {"ok": False, "active": 0, "disconnected": 0, "never": 0, "total": 0, "list": []}
    try:
        tok = _api_token()
        req = urllib.request.Request(WAZUH_API + "/agents?select=name,status,ip,version&limit=100&sort=name",
                                     headers={"Authorization": "Bearer " + tok})
        d = json.load(urllib.request.urlopen(req, timeout=12, context=SSLCTX))
        for a in d.get("data", {}).get("affected_items", []):
            st = a.get("status", "")
            out["list"].append({"name": a.get("name"), "status": st, "ip": a.get("ip", ""), "ver": a.get("version", "")})
            if st == "active": out["active"] += 1
            elif st == "disconnected": out["disconnected"] += 1
            elif "never" in st: out["never"] += 1
        out["total"] = len(out["list"]); out["ok"] = True
    except Exception as e:
        out["err"] = str(e)[:160]
    return out

def wazuh_vuln():
    out = {"ok": False, "total": 0, "sev": {}, "cves": [], "agents": []}
    try:
        r = _idx("/wazuh-states-vulnerabilities-*/_search", {"size": 0, "aggs": {
            "sev": {"terms": {"field": "vulnerability.severity", "size": 6}},
            "cve": {"terms": {"field": "vulnerability.id", "size": 8}},
            "ag": {"terms": {"field": "agent.name", "size": 10}}}})
        tot = r["hits"]["total"]; out["total"] = tot["value"] if isinstance(tot, dict) else tot
        for b in r["aggregations"]["sev"]["buckets"]:
            out["sev"][b["key"]] = b["doc_count"]
        out["cves"] = [{"id": b["key"], "n": b["doc_count"]} for b in r["aggregations"]["cve"]["buckets"]]
        out["agents"] = [{"name": b["key"], "n": b["doc_count"]} for b in r["aggregations"]["ag"]["buckets"]]
        out["ok"] = True
    except Exception as e:
        out["err"] = str(e)[:160]
    return out

def _section(text, heads):
    grab = False; res = []
    for ln in text.splitlines():
        if ln.startswith("#"):
            if grab: break
            grab = any(h.lower() in ln.lower() for h in heads); continue
        if grab and ln.strip(): res.append(ln.rstrip())
    return "\n".join(res).strip()

def htb_rank():
    if not HTB_TOKEN:
        return {"configured": False}
    if _cache["htbrank"][1] and time.time() - _cache["htbrank"][0] < 900:
        return _cache["htbrank"][1]
    hdr = {"Authorization": "Bearer " + HTB_TOKEN, "User-Agent": "Jarvis", "Accept": "application/json"}
    r = {"configured": True}
    try:
        info = json.load(urllib.request.urlopen(urllib.request.Request(
            "https://labs.hackthebox.com/api/v4/user/info", headers=hdr), timeout=10))
        uid = info.get("info", {}).get("id")
        prof = json.load(urllib.request.urlopen(urllib.request.Request(
            f"https://labs.hackthebox.com/api/v4/user/profile/basic/{uid}", headers=hdr), timeout=10)).get("profile", {})
        r.update({"name": prof.get("name"), "rank": prof.get("rank"), "next": prof.get("next_rank"),
                  "progress": prof.get("current_rank_progress"),
                  "uown": prof.get("user_owns"), "sown": prof.get("system_owns")})
    except Exception as e:
        r["err"] = str(e)[:120]
    _cache["htbrank"] = (time.time(), r)
    return r

def htb_status():
    r = {"box": "", "luecken": "", "ziele": "", "rank": htb_rank()}
    try:
        r["box"] = _section(open(os.path.join(VAULT, "HTB-Ziele.md"), encoding="utf-8", errors="replace").read(), ["Aktuell dran"])
    except Exception: pass
    try:
        ls = open(os.path.join(VAULT, "Lernstand.md"), encoding="utf-8", errors="replace").read()
        r["luecken"] = _section(ls, ["Luecke", "Lücke"]); r["ziele"] = _section(ls, ["Lernziel"])
    except Exception: pass
    return r

def dashboard_context():
    c = _cache.get("ctx")
    if c and c[1] and time.time() - c[0] < 20:
        return c[1]
    p = []
    try:
        h = pc_health(); g = h.get("gpu", {})
        p.append(f"PC CPU {h.get('cpu')}% RAM {h.get('mem')}% Disk {h.get('disk')}% GPU {g.get('util','?')}%")
    except Exception: pass
    try:
        w = wazuh_recent()
        if w.get("ok"): p.append(f"Wazuh24h {w['total']} Alerts ({w['important']} wichtig, {w['critical']} kritisch)")
    except Exception: pass
    try:
        a = wazuh_agents()
        if a.get("ok"): p.append(f"Agents {a['active']} aktiv/{a['disconnected']} offline")
    except Exception: pass
    try:
        v = wazuh_vuln()
        if v.get("ok"): p.append(f"Vulns {v['sev'].get('Critical',0)} critical/{v['sev'].get('High',0)} high")
    except Exception: pass
    try:
        hs = htb_status(); rk = hs.get("rank", {})
        box = (hs.get("box", "").splitlines() or [""])[0].strip("- ").strip()[:70]
        if rk.get("rank"): p.append(f"HTB Rang {rk['rank']}, naechste Box: {box}")
    except Exception: pass
    txt = " | ".join(p)
    _cache["ctx"] = (time.time(), txt)
    return txt

def _fetch(url, timeout=12):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Jarvis/1.0"}), timeout=timeout).read()

def security_news():
    if _cache["news"][1] and time.time() - _cache["news"][0] < 1800:
        return _cache["news"][1]
    items = []
    for url in ("https://www.heise.de/security/rss/news-atom.xml", "https://www.heise.de/security/rss/news.rdf"):
        if any(i["src"] == "heise" for i in items): break
        try:
            root = ET.fromstring(_fetch(url, 10))
            for el in root.iter():
                if el.tag.lower().endswith(("item", "entry")):
                    title = link = ""
                    for ch in el:
                        tl = ch.tag.lower()
                        if tl.endswith("title"): title = (ch.text or "").strip()
                        elif tl.endswith("link"): link = (ch.attrib.get("href") or ch.text or "").strip()
                    if title: items.append({"src": "heise", "title": title, "link": link})
                if len([i for i in items if i["src"] == "heise"]) >= 6: break
        except Exception: pass
    try:
        kev = json.loads(_fetch("https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json", 15))
        for v in sorted(kev.get("vulnerabilities", []), key=lambda v: v.get("dateAdded", ""), reverse=True)[:6]:
            items.append({"src": "CVE", "title": f"{v.get('cveID')} — {v.get('vendorProject')} {v.get('product')}: {v.get('shortDescription','')[:80]}",
                          "link": f"https://nvd.nist.gov/vuln/detail/{v.get('cveID')}"})
    except Exception: pass
    if not items: items = [{"src": "", "title": "Feeds nicht erreichbar", "link": ""}]
    _cache["news"] = (time.time(), items)
    return items

def _wellfile():
    os.makedirs(WELLDIR, exist_ok=True)
    return os.path.join(WELLDIR, time.strftime("%Y-%m-%d") + ".json")

def wellness_get():
    try: return json.load(open(_wellfile(), encoding="utf-8"))
    except Exception: return {"water": 0, "meditation": False, "sport": False, "water_goal": 8}

def wellness_update(a):
    w = wellness_get(); w.setdefault("water_goal", 8)
    if a == "water+": w["water"] = min(20, w.get("water", 0) + 1)
    elif a == "water-": w["water"] = max(0, w.get("water", 0) - 1)
    elif a == "meditation": w["meditation"] = not w.get("meditation", False)
    elif a == "sport": w["sport"] = not w.get("sport", False)
    json.dump(w, open(_wellfile(), "w", encoding="utf-8"))
    return w

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        b = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p = self.path.split("?")[0]
        if p == "/" or p.startswith("/index"): self._send(200, PAGE, "text/html; charset=utf-8")
        elif p == "/status":
            g = interactive_user(); self._send(200, json.dumps({"gaming": g, "gpu": gpu_info()}))
        elif p == "/health": self._send(200, json.dumps(pc_health()))
        elif p == "/wazuh": self._send(200, json.dumps(wazuh_recent()))
        elif p == "/agents": self._send(200, json.dumps(wazuh_agents()))
        elif p == "/vuln": self._send(200, json.dumps(wazuh_vuln()))
        elif p == "/htb": self._send(200, json.dumps(htb_status()))
        elif p == "/news": self._send(200, json.dumps(security_news()))
        elif p == "/wellness": self._send(200, json.dumps(wellness_get()))
        else: self._send(404, "{}")
    def do_POST(self):
        p = self.path.split("?")[0]
        try:
            n = int(self.headers.get("Content-Length", 0)); data = json.loads(self.rfile.read(n) or b"{}")
        except Exception: data = {}
        if p == "/wellness": self._send(200, json.dumps(wellness_update(data.get("action", "")))); return
        if p in ("/ask", "/exec"):
            text = (data.get("text") or "").strip()
            if not text: self._send(400, json.dumps({"error": "leer"})); return
            if p == "/exec": exec_interactive(text); self._send(200, json.dumps({"ok": True})); return
            agent = bool(data.get("agent")); gaming = interactive_user()
            route = "claude-plan" if agent else ("claude" if gaming else "ollama"); t0 = time.time()
            try:
                if route == "claude-plan":
                    reply = ask_claude(text, plan=True)
                else:
                    q = f"[Live-Status: {dashboard_context()}]\n\nFrage: {text}"
                    reply = ask_ollama(q) if route == "ollama" else ask_claude(q, plan=False)
            except Exception as e:
                reply = "[Fehler] " + str(e)[:300]
            self._send(200, json.dumps({"reply": reply, "route": route, "elapsed": round(time.time() - t0, 1)})); return
        self._send(404, "{}")

PAGE = r"""<!doctype html><html lang=de><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1"><title>Jarvis</title>
<style>
:root{--bg:#0A0608;--sf:#140d11;--sf2:#1d1419;--on:#F1E7E8;--mut:#8f8085;--red:#E11D2E;--redb:#FF3B47;--cy:#34E0E8;--cyb:#8CF8FF;--ok:#3ddc84;--warn:#ffb020}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(1100px 650px at 50% -12%,#180a10,var(--bg)) fixed;color:var(--on);font:13.5px/1.5 system-ui,Segoe UI,Roboto,sans-serif;height:100vh;display:flex;flex-direction:column;overflow:hidden}
header{display:flex;align-items:center;gap:12px;padding:9px 16px;border-bottom:1px solid #ffffff10}
.logo{font-weight:800;letter-spacing:6px}
#chip{margin-left:auto;display:flex;gap:10px;align-items:center;font-size:12px;color:var(--mut)}
.dot{width:9px;height:9px;border-radius:50%;background:var(--mut);box-shadow:0 0 8px currentColor}
.dot.cloud{background:var(--redb);color:var(--redb)}.dot.gpu{background:var(--cy);color:var(--cy)}
#grid{flex:1;display:grid;grid-template-columns:1.2fr 1fr 1fr;grid-template-rows:auto auto auto 1fr;gap:11px;padding:11px;overflow:auto}
.agitem{display:flex;align-items:center;gap:7px;font-size:12px;padding:3px 0}
.ad{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 6px currentColor}.ad.off{background:var(--redb);color:var(--redb)}.ad.ok{color:var(--ok)}
.sevtile .n{font-size:22px}.sev-Critical .n{color:var(--redb)}.sev-High .n{color:var(--warn)}.sev-Medium .n{color:var(--cyb)}.sev-Low .n{color:var(--mut)}
.card{background:linear-gradient(180deg,#160f13,#110b0e);border:1px solid #ffffff10;border-radius:16px;padding:13px;overflow:auto;display:flex;flex-direction:column;min-height:0}
.card h3{margin:0 0 9px;font-size:10.5px;letter-spacing:2px;color:var(--mut);font-weight:800;display:flex;align-items:center;gap:8px}
.card h3 .r{margin-left:auto;cursor:pointer;color:var(--mut);font-weight:400}
.assistant{grid-row:1/5}
.wz{grid-column:2/4}
#orbwrap{display:flex;flex-direction:column;align-items:center}
#orb{width:200px;height:200px;cursor:pointer}#state{font-size:11px;letter-spacing:3px;font-weight:800;color:var(--cyb);margin-top:-6px}
#log{flex:1;overflow:auto;display:flex;flex-direction:column;gap:8px;margin:8px 0}
.b{max-width:90%;padding:8px 12px;border-radius:13px;white-space:pre-wrap;word-wrap:break-word;font-size:13px}
.me{align-self:flex-end;background:var(--sf2)}.ja{align-self:flex-start;background:#0f0a0d;border:1px solid #E11D2E22}
.inrow{display:flex;gap:8px;align-items:center}
#t{flex:1;background:var(--bg);border:1px solid #ffffff1a;border-radius:20px;color:var(--on);padding:9px 13px;font:inherit;resize:none;min-height:40px;max-height:90px}
button{border:0;border-radius:18px;background:var(--sf2);color:var(--on);padding:0 13px;height:40px;font:inherit;cursor:pointer}
#mic{width:44px;height:44px;border-radius:50%;background:radial-gradient(circle at 50% 35%,var(--cyb),var(--cy));color:#07262a;font-size:18px}#mic.rec{background:radial-gradient(circle at 50% 35%,var(--redb),var(--red));color:#fff;box-shadow:0 0 22px #E11D2Ecc}
#send{background:var(--red);color:#fff}
.seg{display:flex;background:var(--bg);border-radius:12px;overflow:hidden;border:1px solid #ffffff14}
.seg button{border-radius:0;height:28px;padding:0 12px;background:transparent;color:var(--mut);font-size:12px}.seg button.on{background:var(--red);color:#fff}
.tiles{display:flex;gap:9px;margin-bottom:10px}
.tile{flex:1;background:#0f0a0d;border:1px solid #ffffff10;border-radius:12px;padding:9px 11px}
.tile .n{font-size:24px;font-weight:800;line-height:1}.tile .k{font-size:10px;letter-spacing:1px;color:var(--mut);margin-top:3px}
.tile.imp .n{color:var(--warn)}.tile.crit .n{color:var(--redb)}.tile.tot .n{color:var(--cyb)}
.lvbar{display:flex;gap:3px;margin-bottom:9px;font-size:10px;color:var(--mut);flex-wrap:wrap}
.lvb{padding:2px 6px;border-radius:6px;background:#0f0a0d;border:1px solid #ffffff10}
.alert{font-size:12px;padding:5px 8px;border-radius:8px;background:#0f0a0d;margin-bottom:4px;border-left:3px solid var(--mut);display:flex;gap:7px;align-items:baseline}
.alert .lv{font-weight:800;min-width:26px}.l7{border-color:var(--warn)}.l10{border-color:var(--redb)}
.alert .ag{color:var(--cyb)}.alert .tm{margin-left:auto;color:var(--mut);font-size:10px}
.meter{height:7px;background:#000;border-radius:5px;overflow:hidden;margin:2px 0 8px}.meter>i{display:block;height:100%;border-radius:5px}
.mrow{display:flex;justify-content:space-between;font-size:12px}
.news{font-size:12px;margin-bottom:6px;line-height:1.35}.news .s{font-size:9px;letter-spacing:1px;color:var(--cy);font-weight:800;margin-right:5px}
a{color:var(--cyb);text-decoration:none}.small{font-size:11px;color:var(--mut)}
.pre{white-space:pre-wrap;font-size:11.5px;color:#cfc4c6;line-height:1.4}
.rank{display:flex;align-items:center;gap:12px;margin-bottom:8px}
.rank .big{font-size:26px;font-weight:800;color:var(--cyb);line-height:1}
.rankpts{font-size:11px;color:var(--mut)}
.box{background:#0f0a0d;border:1px solid #E11D2E22;border-radius:10px;padding:9px;font-size:12px}
.wellrow{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.glass{display:inline-block;width:13px;height:18px;border:2px solid #2a6a70;border-top:0;border-radius:0 0 4px 4px;margin:1px}.glass.on{background:var(--cy);border-color:var(--cy)}
.chip{display:inline-flex;align-items:center;gap:6px;padding:5px 10px;border-radius:20px;background:#0f0a0d;border:1px solid #ffffff14;cursor:pointer;font-size:12px}
.chip.on{background:#0d2a17;border-color:var(--ok);color:#bff5d4}
.mini{height:30px;padding:0 10px;border-radius:14px}
</style></head><body>
<header><span class=logo>J A R V I S</span><span id=chip><span id=dot class=dot></span><span id=rtxt>…</span><span id=gpux></span></span></header>
<div id=grid>
  <div class="card assistant">
    <div id=orbwrap><canvas id=orb width=300 height=300></canvas><div id=state>IDLE</div></div>
    <div id=log></div>
    <div class=inrow style=margin-bottom:8px><div class=seg><button id=mChat class=on>Chat</button><button id=mAgent>Agent</button></div><label class=small style=margin-left:auto><input type=checkbox id=ttsOn checked> 🔊</label><select id=voice class=small style="background:var(--bg);color:var(--on);border:1px solid #ffffff1a;border-radius:10px;height:28px;max-width:160px"></select></div>
    <div class=inrow><button id=mic>🎙</button><textarea id=t placeholder="Sprich oder tippe …"></textarea><button id=send>➤</button></div>
  </div>
  <div class="card wz"><h3>WAZUH · SIEM · 24H <span class=r onclick=loadWazuh()>↻</span></h3><div id=wazuh class=small>lädt…</div></div>
  <div class=card><h3>VULNERABILITIES <span class=r onclick=loadVuln()>↻</span></h3><div id=vuln class=small>lädt…</div></div>
  <div class=card><h3>AGENTS <span class=r onclick=loadAgents()>↻</span></h3><div id=agents class=small>lädt…</div></div>
  <div class=card><h3>HACKTHEBOX <span class=r onclick=loadHtb()>↻</span></h3><div id=htb class=small>lädt…</div></div>
  <div class=card><h3>PC-HEALTH <span class=r onclick=loadHealth()>↻</span></h3><div id=health class=small>lädt…</div></div>
  <div class=card><h3>SECURITY-NEWS & CVEs <span class=r onclick=loadNews()>↻</span></h3><div id=news class=small>lädt…</div></div>
  <div class=card><h3>WELLNESS · HEUTE</h3><div id=well class=small>lädt…</div></div>
</div>
<script>
const log=document.getElementById('log'),t=document.getElementById('t'),stateEl=document.getElementById('state');
let mode='chat',jstate='idle';
function setState(s){jstate=s;const m={idle:'IDLE',listening:'HÖRT ZU',thinking:'DENKT …',speaking:'SPRICHT'};stateEl.textContent=m[s];stateEl.style.color=s==='speaking'?'#FF3B47':'#8CF8FF';}
function add(x,w){const d=document.createElement('div');d.className='b '+(w=='me'?'me':'ja');d.textContent=x;log.appendChild(d);log.scrollTop=log.scrollHeight;return d;}
let VOICES=[];
function pickDefault(vs){const pref=[/Google UK English Male/i,/\bDaniel\b/i,/\bGeorge\b/i,/UK English Male/i,/Microsoft (Stefan|Conrad|Killian|Ryan|Guy)/i,/\bmale\b/i,/^de/i];for(const re of pref){const v=vs.find(x=>re.test(x.name)||re.test(x.lang));if(v)return v.name;}return vs[0]?vs[0].name:'';}
function populateVoices(){VOICES=speechSynthesis.getVoices();if(!VOICES.length)return;const sel=document.getElementById('voice');const saved=localStorage.getItem('jvoice');sel.innerHTML=VOICES.map(v=>`<option value="${v.name}">${v.name} (${v.lang})</option>`).join('');sel.value=(saved&&VOICES.some(v=>v.name===saved))?saved:pickDefault(VOICES);sel.onchange=()=>{localStorage.setItem('jvoice',sel.value);speak('Stimme aktiv.');};}
if(window.speechSynthesis){speechSynthesis.onvoiceschanged=populateVoices;setTimeout(populateVoices,300);}
function speak(s){if(!document.getElementById('ttsOn').checked){setState('idle');return;}try{const u=new SpeechSynthesisUtterance(s);const nm=document.getElementById('voice').value;const v=VOICES.find(x=>x.name===nm);if(v){u.voice=v;u.lang=v.lang;}else{u.lang='de-DE';}u.pitch=0.85;u.rate=0.98;u.onstart=()=>setState('speaking');u.onend=()=>setState('idle');speechSynthesis.cancel();speechSynthesis.speak(u);}catch(e){setState('idle');}}
async function jget(u){return (await fetch(u)).json();}
async function send(text,agent){add(text,'me');t.value='';setState('thinking');const d=add('…','ja');try{const j=await(await fetch('/ask',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text,agent})})).json();d.textContent=j.reply||j.error||'(leer)';const m=document.createElement('div');m.className='small';m.style.marginTop='4px';m.textContent=(j.route||'')+(j.elapsed?' · '+j.elapsed+'s':'');d.appendChild(m);if(agent){const b=document.createElement('button');b.textContent='▶ Auf space ausführen';b.className='mini';b.style.cssText+=';display:block;margin-top:8px;background:var(--red);color:#fff;font-size:12px';b.onclick=async()=>{b.disabled=1;b.textContent='Terminal offen…';await fetch('/exec',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({text})});b.textContent='✓ im Terminal bestätigen';};d.appendChild(b);}speak(j.reply||'');}catch(e){d.textContent='[Netzfehler]';setState('idle');}}
function submit(){const x=t.value.trim();if(x)send(x,mode=='agent');}
document.getElementById('send').onclick=submit;t.addEventListener('keydown',e=>{if(e.key=='Enter'&&!e.shiftKey){e.preventDefault();submit();}});
mChat.onclick=()=>{mode='chat';mChat.classList.add('on');mAgent.classList.remove('on');};mAgent.onclick=()=>{mode='agent';mAgent.classList.add('on');mChat.classList.remove('on');};
let rec=null,recing=false;const mic=document.getElementById('mic');const SR=window.SpeechRecognition||window.webkitSpeechRecognition;
if(SR){rec=new SR();rec.lang='de-DE';rec.interimResults=true;rec.continuous=false;rec.onstart=()=>setState('listening');rec.onresult=e=>{let s='';for(const r of e.results)s+=r[0].transcript;t.value=s;};rec.onend=()=>{recing=false;mic.classList.remove('rec');if(jstate==='listening')setState('idle');};mic.onclick=()=>{if(recing){rec.stop();return;}try{rec.start();recing=true;mic.classList.add('rec');}catch(e){}};}
function bar(l,v,w){const c=v>=90?'var(--redb)':v>=w?'var(--warn)':'var(--cy)';return `<div class=mrow><span>${l}</span><span>${v}%</span></div><div class=meter><i style="width:${Math.max(2,v)}%;background:${c}"></i></div>`;}
async function loadHealth(){try{const h=await jget('/health');let s=bar('CPU',h.cpu,70)+bar('RAM '+(h.memgb||'')+'GB',h.mem,80)+bar('Disk C:',h.disk,85);if(h.gpu&&h.gpu.util>=0)s+=bar('GPU'+(h.gpu.temp>=0?' '+h.gpu.temp+'°C':''),h.gpu.util,80);health.innerHTML=s;}catch(e){health.textContent='Fehler';}}
async function loadWazuh(){try{const w=await jget('/wazuh');if(!w.ok){wazuh.innerHTML='<span class=small>Indexer nicht erreichbar</span>';return;}let s=`<div class=tiles><div class="tile tot"><div class=n>${w.total}</div><div class=k>ALERTS 24H</div></div><div class="tile imp"><div class=n>${w.important}</div><div class=k>WICHTIG ≥L7</div></div><div class="tile crit"><div class=n>${w.critical}</div><div class=k>KRITISCH ≥L10</div></div></div>`;s+='<div class=lvbar>'+Object.entries(w.levels).sort((a,b)=>b[0]-a[0]).map(([k,v])=>`<span class=lvb>L${k}: ${v}</span>`).join('')+`<span class=lvb>· ${w.agents} Agents</span></div>`;for(const a of w.recent){const cls=a.lvl>=10?'l10':a.lvl>=7?'l7':'';s+=`<div class="alert ${cls}"><span class=lv>L${a.lvl}</span><span><span class=ag>${a.agent}</span> · ${a.desc}${a.src?' · '+a.src:''}</span><span class=tm>${a.ts}</span></div>`;}if(!w.recent.length)s+='<div class=small>keine Alerts ≥L7 — ruhig ✓</div>';s+='<div class=small style=margin-top:6px><a href="https://100.90.173.54" target=_blank>→ Wazuh-Dashboard</a></div>';wazuh.innerHTML=s;}catch(e){wazuh.textContent='Fehler';}}
async function loadVuln(){try{const v=await jget('/vuln');if(!v.ok){vuln.innerHTML='<span class=small>Vuln-Index n/a</span>';return;}let s='<div class=tiles>';for(const k of ['Critical','High','Medium','Low'])if(v.sev[k]!=null)s+=`<div class="tile sevtile sev-${k}"><div class=n>${v.sev[k]}</div><div class=k>${k.toUpperCase()}</div></div>`;s+='</div>';s+=`<div class=small style=margin:4px 0 6px>${v.total} Funde · Top-CVEs:</div>`;for(const c of v.cves)s+=`<div class=news><a href="https://nvd.nist.gov/vuln/detail/${c.id}" target=_blank>${c.id}</a> <span class=small>×${c.n}</span></div>`;vuln.innerHTML=s;}catch(e){vuln.textContent='Fehler';}}
async function loadAgents(){try{const a=await jget('/agents');if(!a.ok){agents.innerHTML='<span class=small>Wazuh-API nicht erreichbar</span>';return;}let s=`<div class=small style=margin-bottom:7px><b style=color:var(--ok)>${a.active} aktiv</b> · <b style=color:var(--redb)>${a.disconnected} offline</b>${a.never?' · '+a.never+' neu':''} · ${a.total} gesamt</div>`;for(const g of a.list){const off=g.status!=='active';s+=`<div class=agitem><span class="ad ${off?'off':'ok'}"></span>${g.name}<span class=small style=margin-left:auto>${g.status}</span></div>`;}agents.innerHTML=s;}catch(e){agents.textContent='Fehler';}}
async function loadHtb(){try{const h=await jget('/htb');let s='';const r=h.rank||{};if(r.configured&&r.rank){s+=`<div class=rank><div><div class=big>${r.rank}</div><div class=rankpts>${r.name||''}${r.next?' → '+r.next+' ('+Math.round(r.progress||0)+'%)':''}</div></div></div><div class=small style=margin-bottom:8px>🚩 User-Owns: ${r.uown??'-'} · System-Owns: ${r.sown??'-'}</div>`;}else if(!r.configured){s+='<div class=small style=margin-bottom:8px>HTB-Rang: Token in <code>jarvis-agent/htb_token</code> hinterlegen (HTB → Profil → App-Token).</div>';}else{s+='<div class=small>HTB-API-Fehler (Token prüfen)</div>';}if(h.box)s+='<div class=box><b style=color:var(--redb)>NÄCHSTE BOX</b><div class=pre style=margin-top:4px>'+h.box+'</div></div>';htb.innerHTML=s||'keine Daten';}catch(e){htb.textContent='Fehler';}}
async function loadNews(){try{const n=await jget('/news');news.innerHTML=n.map(i=>`<div class=news><span class=s>${i.src}</span>${i.link?`<a href="${i.link}" target=_blank>${i.title}</a>`:i.title}</div>`).join('')||'keine News';}catch(e){news.textContent='Fehler';}}
async function loadWell(){try{const w=await jget('/wellness');const goal=w.water_goal||8;let g='';for(let i=0;i<goal;i++)g+=`<span class="glass ${i<w.water?'on':''}"></span>`;well.innerHTML=`<div class=wellrow><span>💧 ${w.water}/${goal} <span class=small>(${(w.water*0.3).toFixed(1)}L)</span></span><span>${g}</span><button class=mini onclick="well2('water+')">+</button><button class=mini onclick="well2('water-')">−</button></div><div class=wellrow style=margin-top:9px><span class="chip ${w.meditation?'on':''}" onclick="well2('meditation')">🧘 Meditation ${w.meditation?'✓':''}</span><span class="chip ${w.sport?'on':''}" onclick="well2('sport')">🏋️ Sport ${w.sport?'✓':''}</span></div>`;}catch(e){well.textContent='Fehler';}}
async function well2(a){await fetch('/wellness',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:a})});loadWell();}
async function status(){try{const j=await jget('/status');const d=document.getElementById('dot');d.className='dot '+(j.gaming?'cloud':'gpu');rtxt.textContent=j.gaming?'Cloud':'Lokal';gpux.textContent=j.gpu&&j.gpu.util>=0?('GPU '+j.gpu.util+'%'):'';}catch(e){}}
// ---- Orb (dichter) ----
const orb=document.getElementById('orb'),ox=orb.getContext('2d');const N=170,nodes=[],ga=Math.PI*(3-Math.sqrt(5));
for(let i=0;i<N;i++){const y=1-(i/(N-1))*2,r=Math.sqrt(Math.max(0,1-y*y)),th=ga*i;nodes.push([Math.cos(th)*r,y,Math.sin(th)*r]);}
const edges=[],thr=0.34;for(let i=0;i<N;i++)for(let j=i+1;j<N;j++){const dx=nodes[i][0]-nodes[j][0],dy=nodes[i][1]-nodes[j][1],dz=nodes[i][2]-nodes[j][2];if(dx*dx+dy*dy+dz*dz<thr*thr)edges.push([i,j]);}
const rings=[];for(const lat of[-0.66,-0.33,0,0.33,0.66]){const rr=Math.sqrt(Math.max(0,1-lat*lat)),R2=[];for(let k=0;k<54;k++){const a=k/54*2*Math.PI;R2.push([Math.cos(a)*rr,lat,Math.sin(a)*rr]);}rings.push(R2);}
for(let m=0;m<7;m++){const lo=m/7*Math.PI,R2=[];for(let k=0;k<54;k++){const a=k/54*2*Math.PI;R2.push([Math.cos(a)*Math.cos(lo),Math.sin(a),Math.cos(a)*Math.sin(lo)]);}rings.push(R2);}
function hA(h,a){const n=parseInt(h.slice(1),16);return'rgba('+((n>>16)&255)+','+((n>>8)&255)+','+(n&255)+','+a+')';}
function lH(h1,h2,t){const a=parseInt(h1.slice(1),16),b=parseInt(h2.slice(1),16),r=Math.round((a>>16&255)+((b>>16&255)-(a>>16&255))*t),g=Math.round((a>>8&255)+((b>>8&255)-(a>>8&255))*t),bl=Math.round((a&255)+((b&255)-(a&255))*t);return'rgb('+r+','+g+','+bl+')';}
function look(){if(jstate==='speaking')return{a:'#FF3B47',hi:'#ffffff',deep:'#6E0912',spd:0.33,amp:0.09,pf:1.7};if(jstate==='listening')return{a:'#8CF8FF',hi:'#ffffff',deep:'#0A3A44',spd:0.20,amp:0.06,pf:0.9};if(jstate==='thinking')return{a:'#34E0E8',hi:'#8CF8FF',deep:'#0A3A44',spd:0.65,amp:0.05,pf:1.2};return{a:'#34E0E8',hi:'#8CF8FF',deep:'#0A3A44',spd:0.07,amp:0.035,pf:0.42};}
let ang=0,last=performance.now();
function draw(now){const dt=(now-last)/1000;last=now;const c=look();ang+=dt*c.spd*2*Math.PI;const pulse=1+c.amp*Math.sin(now/1000*c.pf*2*Math.PI);const W=orb.width,Hh=orb.height,cx=W/2,cy=Hh/2,R=W*0.40*pulse,tl=0.5,ct=Math.cos(tl),st=Math.sin(tl),ca=Math.cos(ang),sa=Math.sin(ang);ox.clearRect(0,0,W,Hh);
 function pr(p){let x=p[0]*ca+p[2]*sa,z=-p[0]*sa+p[2]*ca,y=p[1];const y2=y*ct-z*st,z2=y*st+z*ct;y=y2;z=z2;const pe=1/(2.0-z*0.6);return[cx+x*R*2*pe,cy+y*R*2*pe,z];}
 const g=ox.createRadialGradient(cx,cy,0,cx,cy,R*1.6);g.addColorStop(0,hA(c.a,jstate==='speaking'?0.55:0.3));g.addColorStop(1,hA(c.a,0));ox.fillStyle=g;ox.beginPath();ox.arc(cx,cy,R*1.6,0,7);ox.fill();
 ox.lineWidth=0.5;ox.strokeStyle=hA(c.a,0.10);for(const ring of rings){ox.beginPath();for(let k=0;k<=ring.length;k++){const o=pr(ring[k%ring.length]);if(k===0)ox.moveTo(o[0],o[1]);else ox.lineTo(o[0],o[1]);}ox.stroke();}
 const pts=nodes.map(pr);for(const e of edges){const a=pts[e[0]],b=pts[e[1]],f=((a[2]+b[2])/2+1)/2;ox.strokeStyle=hA(c.a,Math.min(1,f*0.38+0.03));ox.lineWidth=(0.35+f)*(jstate==='speaking'?1.25:0.8);ox.beginPath();ox.moveTo(a[0],a[1]);ox.lineTo(b[0],b[1]);ox.stroke();}
 const ord=pts.map((p,i)=>i).sort((i,j)=>pts[i][2]-pts[j][2]);for(const i of ord){const p=pts[i],f=(p[2]+1)/2,tw=0.78+0.22*Math.sin(now/1000*2*Math.PI*(jstate==='speaking'?3:1)+i*0.9),sz=(0.8+f*2.2)*tw;ox.fillStyle=lH(c.deep,c.hi,f);ox.globalAlpha=0.35+0.6*f;ox.beginPath();ox.arc(p[0],p[1],sz,0,7);ox.fill();}ox.globalAlpha=1;
 const cg=ox.createRadialGradient(cx,cy,0,cx,cy,R*0.55);cg.addColorStop(0,hA(c.hi,jstate==='speaking'?0.95:0.5));cg.addColorStop(1,hA(c.a,0));ox.fillStyle=cg;ox.beginPath();ox.arc(cx,cy,R*0.55,0,7);ox.fill();requestAnimationFrame(draw);}
requestAnimationFrame(draw);
orb.onclick=()=>{if(speechSynthesis.speaking){speechSynthesis.cancel();setState('idle');}else if(!recing)mic.click();};
status();loadHealth();loadWazuh();loadVuln();loadAgents();loadHtb();loadNews();loadWell();
setInterval(status,5000);setInterval(loadHealth,6000);setInterval(loadWazuh,60000);setInterval(loadAgents,60000);setInterval(loadVuln,300000);setInterval(loadHtb,300000);
</script></body></html>"""

if __name__ == "__main__":
    print(f"Jarvis Console -> http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
