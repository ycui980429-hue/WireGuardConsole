#!/usr/bin/env python3
"""WireGuard GUI — 本地 Web 管理面板
纯 Python 标准库实现，无第三方依赖。
仅监听 127.0.0.1，请勿暴露到公网。
"""
import json
import os
import re
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROFILES_DIR = os.environ.get(
    "WG_PROFILES_DIR",
    os.path.expanduser("~/Library/Application Support/WireGuardConsole/profiles"),
)
STATIC_DIR = os.environ.get("WG_STATIC_DIR", os.path.join(BASE_DIR, "static"))
WG = "/opt/homebrew/bin/wg"
WG_QUICK = "/opt/homebrew/bin/wg-quick"
PORT = int(os.environ.get("WG_PORT", "8799"))

os.makedirs(PROFILES_DIR, exist_ok=True)
SUDO = ["sudo", "-n"]
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except OSError as e:
        return 126, "", str(e)


def sudo_ready():
    rc, _, _ = run(SUDO + ["-l", WG_QUICK])
    return rc == 0


def parse_wg_dump(dump):
    """解析 `wg show dump` 输出。第一行是接口，后续每行是一个 peer。"""
    result = {}
    if not dump.strip():
        return result
    lines = [l.split("\t") for l in dump.strip().splitlines()]
    iface = None
    for f in lines:
        # 接口行 5 列: name private-key public-key listen-port fwmark
        if len(f) == 5:
            iface = f[0]
            result[iface] = {"public_key": f[2], "listen_port": f[3], "peers": []}
            continue
        # peer 行 8 列: public-key preshared-key endpoint allowed-ips
        #               latest-handshake rx tx persistent-keepalive
        if len(f) >= 8 and iface:
            result[iface]["peers"].append({
                "public_key": f[0][:20] + "…" if f[0] else "",
                "endpoint": f[2],
                "allowed_ips": f[3],
                "latest_handshake": int(f[4]) if f[4].isdigit() else 0,
                "rx": int(f[5]) if f[5].isdigit() else 0,
                "tx": int(f[6]) if f[6].isdigit() else 0,
            })
    return result


def list_profiles():
    items = []
    for fn in sorted(os.listdir(PROFILES_DIR)):
        if not fn.endswith(".conf"):
            continue
        path = os.path.join(PROFILES_DIR, fn)
        name = fn[:-5]
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        info = {
            "name": name,
            "file": fn,
            "size": os.path.getsize(path),
            "mtime": int(os.path.getmtime(path)),
            "error": None,
        }
        # 提取常用字段展示（不显示私钥）
        m = re.search(r"^\s*Address\s*=\s*(.+)$", text, re.M)
        info["address"] = m.group(1).strip() if m else ""
        m = re.search(r"^\s*Endpoint\s*=\s*(.+)$", text, re.M)
        info["endpoint"] = m.group(1).strip() if m else ""
        m = re.search(r"^\s*DNS\s*=\s*(.+)$", text, re.M)
        info["dns"] = m.group(1).strip() if m else ""
        m = re.search(r"^\s*PublicKey\s*=\s*(.+)$", text, re.M)
        info["peer_key"] = (m.group(1).strip()[:16] + "…") if m else ""
        items.append(info)
    return items


def validate_conf(text):
    if "[interface]" not in text.lower():
        return "缺少 [interface] 段"
    if not re.search(r"^\s*PrivateKey\s*=", text, re.M):
        return "缺少 PrivateKey"
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 512 * 1024:
            raise ValueError("payload too large")
        raw = self.rfile.read(n) if n else b"{}"
        return json.loads(raw.decode("utf-8", "replace"))

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/status":
            rc, out, err = run(SUDO + [WG, "show", "dump"])
            active = {}
            if rc == 0:
                active = parse_wg_dump(out)
            return self._json({
                "sudo_ready": sudo_ready(),
                "port": PORT,
                "profiles": list_profiles(),
                "active": active,
            })
        if path == "/" or path == "/index.html":
            return self._static("index.html", "text/html; charset=utf-8")
        if re.fullmatch(r"/static/[\w.-]+", path):
            return self._static(path[len("/static/"):])
        self._json({"error": "not found"}, 404)

    def _static(self, fn, ctype=None):
        fp = os.path.join(STATIC_DIR, os.path.basename(fn))
        if not os.path.isfile(fp):
            return self._json({"error": "not found"}, 404)
        if not ctype:
            ctype = {
                ".html": "text/html; charset=utf-8",
                ".js": "application/javascript; charset=utf-8",
                ".css": "text/css; charset=utf-8",
                ".svg": "image/svg+xml",
                ".png": "image/png",
                ".ico": "image/x-icon",
            }.get(os.path.splitext(fn)[1], "application/octet-stream")
        with open(fp, "rb") as fh:
            body = fh.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        try:
            body = self._read_body()
        except (ValueError, json.JSONDecodeError) as e:
            return self._json({"error": "bad request: %s" % e}, 400)

        if path == "/api/import":
            name = (body.get("name") or "").strip()
            text = body.get("config") or ""
            if not SAFE_NAME.match(name):
                return self._json({"error": "名称只能包含字母数字 . _ - ，且以字母数字开头"}, 400)
            err = validate_conf(text)
            if err:
                return self._json({"error": err}, 400)
            fp = os.path.join(PROFILES_DIR, name + ".conf")
            with open(fp, "w", encoding="utf-8") as fh:
                fh.write(text.strip() + "\n")
            os.chmod(fp, 0o600)
            return self._json({"ok": True, "name": name})

        if path == "/api/delete":
            name = body.get("name") or ""
            if not SAFE_NAME.match(name):
                return self._json({"error": "非法名称"}, 400)
            fp = os.path.join(PROFILES_DIR, name + ".conf")
            rc, _, err = run(SUDO + [WG_QUICK, "down", fp])
            if os.path.isfile(fp):
                os.remove(fp)
            return self._json({"ok": True, "note": err.strip() if rc != 0 else None})

        if path == "/api/connect":
            name = body.get("name") or ""
            if not SAFE_NAME.match(name):
                return self._json({"error": "非法名称"}, 400)
            fp = os.path.join(PROFILES_DIR, name + ".conf")
            if not os.path.isfile(fp):
                return self._json({"error": "配置不存在"}, 404)
            rc, out, err = run(SUDO + [WG_QUICK, "up", fp], timeout=60)
            ok = rc == 0
            msg = (out + err).strip()
            return self._json({"ok": ok, "message": msg[-2000:]})

        if path == "/api/disconnect":
            name = body.get("name") or ""
            if not SAFE_NAME.match(name):
                return self._json({"error": "非法名称"}, 400)
            fp = os.path.join(PROFILES_DIR, name + ".conf")
            rc, out, err = run(SUDO + [WG_QUICK, "down", fp], timeout=60)
            ok = rc == 0
            msg = (out + err).strip()
            return self._json({"ok": ok, "message": msg[-2000:]})

        if path == "/api/genkeys":
            rc, priv, _ = run([WG, "genkey"])
            if rc != 0:
                return self._json({"error": "wg genkey 失败"}, 500)
            p = subprocess.run([WG, "pubkey"], input=priv.strip(),
                               capture_output=True, text=True)
            if p.returncode != 0:
                return self._json({"error": "wg pubkey 失败"}, 500)
            rc, psk, _ = run([WG, "genpsk"])
            return self._json({
                "private_key": priv.strip(),
                "public_key": p.stdout.strip(),
                "preshared_key": psk.strip() if rc == 0 and psk.strip() else "",
            })

        self._json({"error": "not found"}, 404)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    import sys
    if not (os.path.isfile(WG) and os.path.isfile(WG_QUICK)):
        print("错误: 未找到 wg / wg-quick，请先 `brew install wireguard-tools`", file=sys.stderr)
        sys.exit(1)
    srv = Server(("127.0.0.1", PORT), Handler)
    print("WireGuard GUI 已启动: http://127.0.0.1:%d  (Ctrl+C 退出)" % PORT)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
