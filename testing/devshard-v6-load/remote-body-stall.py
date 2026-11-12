#!/usr/bin/env python3
"""One chat request whose body stalls, then normal requests: does the stalled one fail alone?

Opens one connection to a live gateway, sends the headers and half of the body of a chat request and stops
for --stall seconds; if the gateway has not answered by then, the rest of the body follows. Then normal
requests go out on the same connection and on new ones, and every status is printed.
Usage: remote-body-stall.py --env ENV [--stall 40] [--same 3] [--fresh 20] [--model M] [--timeout 120]
ENV holds GONKA_BASE and GONKA_API_KEY. Exit 0 when every normal request got 200.
"""
import argparse, http.client, io, json, pathlib, socket, ssl, sys, time, urllib.parse


def env_file(path):
    env = {}
    for line in pathlib.Path(path).expanduser().read_text().splitlines():
        line = line.strip().removeprefix("export ")
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip("'\"")
    return env


def connect(url, timeout):
    sock = socket.create_connection((url.hostname, url.port or (443 if url.scheme == "https" else 80)), timeout)
    if url.scheme == "https":
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=url.hostname)
    return sock


def request(url, key, model, rid):
    body = json.dumps({"model": model, "stream": False, "max_tokens": 8,
                       "messages": [{"role": "user", "content": f"Reply with the word OK. [{rid}]"}]}).encode()
    head = (f"POST {url.path.rstrip('/')}/v1/chat/completions HTTP/1.1\r\nHost: {url.netloc}\r\n"
            f"Authorization: Bearer {key}\r\nContent-Type: application/json\r\nX-Request-Id: {rid}\r\n"
            f"Content-Length: {len(body)}\r\n\r\n").encode()
    return head, body


class Stream(io.RawIOBase):
    """The bytes already read from the socket, then the socket."""

    def __init__(self, sock, first):
        self.sock, self.first = sock, first

    def readable(self):
        return True

    def readinto(self, b):
        if self.first:
            n = min(len(b), len(self.first))
            b[:n], self.first = self.first[:n], self.first[n:]
            return n
        return self.sock.recv_into(b)

    def makefile(self, *_):
        return io.BufferedReader(self)


def answer(sock, first=b""):
    """Status, whether the server keeps the connection, and the start of the body."""
    resp = http.client.HTTPResponse(Stream(sock, first))
    resp.begin()
    text = resp.read().decode("utf-8", "replace")
    return resp.status, not resp.will_close, " ".join(text.split())[:120]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--env", required=True)
    ap.add_argument("--stall", type=float, default=40)
    ap.add_argument("--same", type=int, default=3)
    ap.add_argument("--fresh", type=int, default=20)
    ap.add_argument("--model", default="Qwen/Qwen2.5-7B-Instruct")
    ap.add_argument("--timeout", type=float, default=120)
    a = ap.parse_args()
    env = env_file(a.env)
    url, key = urllib.parse.urlsplit(env["GONKA_BASE"]), env["GONKA_API_KEY"]
    run = time.strftime("body-stall-%Y%m%dT%H%M%SZ", time.gmtime())
    print(f"{time.strftime('%FT%TZ', time.gmtime())} {env['GONKA_BASE']} {a.model} run {run}", flush=True)

    sock = connect(url, a.timeout)
    head, body = request(url, key, a.model, f"{run}-stalled")
    t0 = time.time()
    sock.sendall(head + body[:len(body) // 2])
    sock.settimeout(a.stall)
    try:
        first, early = sock.recv(65536), True
    except TimeoutError:
        first, early = b"", False
    sock.settimeout(a.timeout)
    how = f"answered while the body stalled, after {time.time() - t0:.1f} s"
    try:
        if not early:
            sock.sendall(body[len(body) // 2:])
            how = f"no answer in {a.stall:g} s, answered after the rest of the body"
        status, keep, text = answer(sock, first)
        print(f"conn A, request 1, body stalls: {status}, {how}, connection {'kept' if keep else 'closed'}: {text}", flush=True)
    except (OSError, http.client.HTTPException) as e:
        status, keep = 0, False
        print(f"conn A, request 1, body stalls: no answer, {type(e).__name__}: {e}", flush=True)

    bad = []
    for i in range(2, a.same + 2):
        if not keep:
            print(f"conn A, request {i}, normal: not sent, the server closed the connection")
            break
        head, body = request(url, key, a.model, f"{run}-same-{i}")
        try:
            sock.sendall(head + body)
            status, keep, text = answer(sock)
        except (OSError, http.client.HTTPException) as e:
            status, keep, text = 0, False, f"{type(e).__name__}: {e}"
        print(f"conn A, request {i}, normal: {status} {text}", flush=True)
        if status != 200:
            bad.append(f"conn A request {i}: {status}")
    sock.close()

    for i in range(1, a.fresh + 1):
        head, body = request(url, key, a.model, f"{run}-fresh-{i}")
        t0 = time.time()
        try:
            with connect(url, a.timeout) as s:
                s.sendall(head + body)
                status, _, text = answer(s)
        except (OSError, http.client.HTTPException) as e:
            status, text = 0, f"{type(e).__name__}: {e}"
        print(f"new connection {i}, normal: {status} in {time.time() - t0:.1f} s{'' if status == 200 else ' ' + text}", flush=True)
        if status != 200:
            bad.append(f"new connection {i}: {status}")

    if bad:
        print(f"FAIL {len(bad)} normal requests did not get 200: {', '.join(bad[:10])}")
        sys.exit(1)
    print("PASS every normal request after the stalled one got 200")


if __name__ == "__main__":
    main()
