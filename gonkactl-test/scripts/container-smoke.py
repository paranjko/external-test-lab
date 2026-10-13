#!/usr/bin/env python3
"""Exercise the real installer and Linux archive through a trusted local TLS fixture."""
import functools
import http.server
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading

with tempfile.TemporaryDirectory(prefix="gonkactl-test-smoke-") as temporary:
    root = Path(temporary)
    served = root / "served"
    shutil.copytree(sys.argv[1], served)
    shutil.copyfile(sys.argv[2], served / "install.sh")
    cert, key = root / "cert.pem", root / "key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", str(key), "-out", str(cert), "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(served))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        home = root / "home"
        home.mkdir()
        origin = f"https://localhost:{server.server_port}"
        env = {"HOME": str(home), "PATH": "/usr/local/bin:/usr/bin:/bin", "CURL_CA_BUNDLE": str(cert), "GONKACTL_TEST_RELEASE_BASE_URL": origin, "NO_COLOR": "1"}
        # Exercise streamed shell installation; a failing curl must also fail
        # this harness, regardless of the shell pipeline's last exit status.
        curl = subprocess.Popen(["curl", "-LsSf", origin + "/install.sh"], env=env, stdout=subprocess.PIPE)
        result = subprocess.run(["sh"], stdin=curl.stdout, env=env, timeout=120)
        curl.stdout.close()
        if curl.wait(timeout=10) != 0 or result.returncode != 0:
            raise SystemExit("streamed installation failed")
        binary = home / ".local/bin/gonkactl-test"
        version = subprocess.check_output([str(binary), "--version"], env=env, text=True).strip()
        if version != "1.0.0-alpha.1":
            raise SystemExit(f"unexpected installed version: {version}")
        subprocess.run([str(binary), "--help"], env=env, check=True, stdout=subprocess.DEVNULL)
        print(f"PASS: clean-home HTTPS installation and --version={version}")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
