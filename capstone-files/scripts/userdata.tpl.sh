#!/bin/bash
set -euxo pipefail
mkdir -p /opt/app
cat > /etc/app.env <<EOF
APP_VERSION=__VERSION__
APP_COLOR=__COLOR__
EOF

cat > /opt/app/app.py <<'PYEOF'
import os, json, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = os.getenv("APP_VERSION", "unknown")
COLOR = os.getenv("APP_COLOR", "unknown")

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-App-Version", VERSION)
        self.send_header("X-App-Color", COLOR)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, json.dumps({"status": "ok", "version": VERSION, "color": COLOR}))
        elif self.path == "/":
            self._send(200, f"<h1>Telco Portal</h1><p>Version: {VERSION}</p>"
                            f"<p>Environment: {COLOR}</p><p>Host: {socket.gethostname()}</p>",
                       "text/html")
        elif self.path == "/api/data":
            self._send(200, json.dumps({"plans": ["Daily 20MB", "Weekly 1GB"], "version": VERSION}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, fmt, *args):
        print(f"{self.client_address[0]} {self.command} {self.path} {args[1] if len(args)>1 else ''}", flush=True)

ThreadingHTTPServer(("0.0.0.0", 80), Handler).serve_forever()
PYEOF

cat > /etc/systemd/system/app.service <<'EOF'
[Unit]
Description=Telco demo app
After=network.target
[Service]
EnvironmentFile=/etc/app.env
ExecStart=/usr/bin/python3 /opt/app/app.py
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now app.service
