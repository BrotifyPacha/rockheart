#!/usr/bin/env python3
"""Превращает vless:// ссылку в клиентский конфиг xray с socks-входом на 127.0.0.1:10808."""
import json
import sys
from urllib.parse import parse_qs, unquote, urlsplit

u = urlsplit(sys.argv[1].strip())
q = {k: v[0] for k, v in parse_qs(u.query).items()}

stream = {
    "network": q["type"],
    "security": "reality",
    "realitySettings": {
        "serverName": q["sni"],
        "fingerprint": q["fp"],
        "publicKey": q["pbk"],
        "shortId": q["sid"],
    },
}
if q["type"] == "xhttp":
    stream["xhttpSettings"] = {"path": unquote(q["path"]), "mode": q.get("mode", "auto")}

user = {"id": u.username, "encryption": "none"}
if q.get("flow"):
    user["flow"] = q["flow"]

print(json.dumps({
    "log": {"loglevel": "warning"},
    "inbounds": [{"listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": True}}],
    "outbounds": [{
        "protocol": "vless",
        "settings": {"vnext": [{"address": u.hostname, "port": u.port, "users": [user]}]},
        "streamSettings": stream,
    }],
}, indent=2))
