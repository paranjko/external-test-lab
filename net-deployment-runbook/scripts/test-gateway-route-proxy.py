#!/usr/bin/env python3
"""Route metrics and error MIME contract for the A/B edge proxy."""
import http.client, json, os, socket, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROXY = ROOT / "04-ops/edge-node/gateway-route-proxy.py"

def port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); value = s.getsockname()[1]; s.close(); return value

class Upstream(BaseHTTPRequestHandler):
    body = b'{"error":{"code":"bad_key"}}'; content_type = "text/plain; charset=utf-8"
    def log_message(self, *_args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send_response(401); self.send_header("Content-Type", self.content_type)
        self.send_header("Content-Length", str(len(self.body))); self.end_headers(); self.wfile.write(self.body)

upstream_port, proxy_port = port(), port()
server = ThreadingHTTPServer(("127.0.0.1", upstream_port), Upstream)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = os.environ | {"GDC_GATEWAY_ROUTE_ID":"A", "GDC_GATEWAY_ROUTE_UPSTREAM":"http://127.0.0.1:%s" % upstream_port, "GDC_GATEWAY_ROUTE_PROXY_PORT":str(proxy_port)}
process = subprocess.Popen([sys.executable, str(PROXY)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(50):
        try: socket.create_connection(("127.0.0.1", proxy_port), .05).close(); break
        except OSError: time.sleep(.02)
    else: raise RuntimeError("route proxy did not start")
    def request():
        c = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=3)
        c.request("POST", "/v1/chat/completions", b'{}', {"Content-Type":"application/json"})
        r = c.getresponse(); answer = (r.status, r.getheader("Content-Type"), r.read()); c.close(); return answer
    assert request() == (401, "application/json", Upstream.body)
    Upstream.body = b'not json'; Upstream.content_type = "text/plain; charset=utf-8"
    assert request() == (401, "text/plain; charset=utf-8", b"not json")
    c = http.client.HTTPConnection("127.0.0.1", proxy_port); c.request("GET", "/metrics")
    r = c.getresponse(); metric = r.read().decode(); c.close()
    assert 'gdc_gateway_route_requests_total{route="A",outcome="4xx"} 2' in metric
    print("PASS A/B route proxy counts routes and corrects only JSON error MIME")
finally:
    process.terminate(); process.wait(2); server.shutdown(); server.server_close()
