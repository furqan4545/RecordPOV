#!/usr/bin/env python3
"""One-shot reference client for testing the production YouTube phone protocol.

Requires websockets. This opens outbound connections only; it isn't a server or
the app's production transport. Capabilities remain in memory and aren't logged.
"""
import argparse
import concurrent.futures
import ipaddress
import json
import socket
import struct
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect

WINDOW = 262_144
CHUNK = 32_768
BYTE_LIMIT = 750 * 1024 * 1024
SUFFIXES = ("youtube.com", "googlevideo.com", "ytimg.com")


def allowed_host(host):
    if not isinstance(host, str) or len(host) > 253 or host != host.lower():
        return False
    if any(not label or len(label) > 63 or label[0] == "-" or label[-1] == "-"
           or not all(c.isascii() and (c.isalnum() or c == "-") for c in label)
           for label in host.split(".")):
        return False
    return host == "youtubei.googleapis.com" or any(
        host == domain or host.endswith("." + domain) for domain in SUFFIXES)


def public_address(value):
    address = ipaddress.ip_address(value)
    if getattr(address, "ipv4_mapped", None):
        return public_address(str(address.ipv4_mapped))
    if address.version == 6 and address in ipaddress.ip_network("64:ff9b::/96"):
        return public_address(str(ipaddress.IPv4Address(int(address) & 0xffffffff)))
    return address.is_global and not address.is_multicast


class Peer:
    def __init__(self, ws):
        self.ws = ws
        self.streams = {}
        self.seen = set()
        self.lock = threading.RLock()
        self.write_lock = threading.Lock()
        self.total = 0
        self.received = 0
        self.sent = 0
        self.opened = 0
        self.stopped = False

    def send(self, message):
        with self.write_lock:
            if not self.stopped:
                self.ws.send(json.dumps(message) if isinstance(message, dict) else message)

    def count(self, size, outgoing):
        with self.lock:
            self.total += size
            if outgoing:
                self.sent += size
            else:
                self.received += size
            if self.total > BYTE_LIMIT:
                raise ValueError("Session byte limit exceeded")

    def close_stream(self, identifier):
        with self.lock:
            stream = self.streams.pop(identifier, None)
        if stream:
            with stream["condition"]:
                stream["closed"] = True
                stream["condition"].notify_all()
            if stream.get("socket"):
                try:
                    stream["socket"].shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                stream["socket"].close()

    def open_stream(self, identifier, host, port):
        if not allowed_host(host) or port != 443:
            raise ValueError("Destination denied")
        with self.lock:
            if identifier in self.seen or len(self.streams) >= 8 or len(self.seen) >= 4096:
                raise ValueError("Stream limit or duplicate id")
            self.seen.add(identifier)
            stream = {"condition": threading.Condition(), "pending": 0, "closed": False}
            self.streams[identifier] = stream
        threading.Thread(target=self.connect_stream, args=(identifier, host, stream), daemon=True).start()

    def connect_stream(self, identifier, host, stream):
        try:
            answers = socket.getaddrinfo(host, 443, family=socket.AF_INET, type=socket.SOCK_STREAM)
            if not answers or any(not public_address(answer[4][0]) for answer in answers):
                raise ValueError("Non-public DNS answer")
            connection = None
            for family, kind, proto, _, address in answers:
                candidate = socket.socket(family, kind, proto)
                candidate.settimeout(10)
                try:
                    candidate.connect(address)
                    connection = candidate
                    break
                except OSError:
                    candidate.close()
            if connection is None:
                raise OSError("Connection failed")
            with stream["condition"]:
                if stream["closed"] or self.stopped:
                    connection.close()
                    return
                stream["socket"] = connection
            self.opened += 1
            self.send({"type": "opened", "id": identifier})
            connection.settimeout(1)
            while not self.stopped:
                with stream["condition"]:
                    while stream["pending"] >= WINDOW and not stream["closed"] and not self.stopped:
                        stream["condition"].wait(1)
                    if stream["closed"] or self.stopped:
                        return
                    remaining = min(CHUNK, WINDOW - stream["pending"])
                try:
                    data = connection.recv(remaining)
                except socket.timeout:
                    continue
                if not data:
                    self.send({"type": "end", "id": identifier})
                    return
                self.count(len(data), True)
                with stream["condition"]:
                    stream["pending"] += len(data)
                self.send(b"\x01" + struct.pack("!I", identifier) + data)
        except Exception:
            if not self.stopped:
                try:
                    self.send({"type": "error", "id": identifier, "message": "Connection failed"})
                except Exception:
                    pass
            self.close_stream(identifier)

    def handle(self, message):
        if isinstance(message, bytes):
            if not 6 <= len(message) <= CHUNK + 5 or message[0] != 1:
                raise ValueError("Invalid data packet")
            identifier = struct.unpack("!I", message[1:5])[0]
            data = message[5:]
            stream = self.streams.get(identifier)
            if not stream or not stream.get("socket"):
                raise ValueError("Data for unopened stream")
            self.count(len(data), False)
            stream["socket"].sendall(data)
            self.send({"type": "ack", "id": identifier, "bytes": len(data)})
            return
        control = json.loads(message)
        kind, identifier = control.get("type"), control.get("id")
        if type(identifier) is not int or not 0 < identifier < 2**32:
            raise ValueError("Invalid stream id")
        if kind == "open":
            self.open_stream(identifier, control.get("host"), control.get("port"))
            return
        stream = self.streams.get(identifier)
        if stream is None and identifier in self.seen and kind in ("ack", "end", "close"):
            return
        if kind == "close":
            self.close_stream(identifier)
        elif kind == "ack" and stream:
            amount = control.get("bytes")
            with stream["condition"]:
                if type(amount) is not int or not 0 < amount <= stream["pending"]:
                    raise ValueError("Invalid credit acknowledgement")
                stream["pending"] -= amount
                stream["condition"].notify_all()
        elif kind == "end" and stream and stream.get("socket"):
            stream["socket"].shutdown(socket.SHUT_WR)
        else:
            raise ValueError("Unexpected control packet")

    def stop(self):
        self.stopped = True
        for identifier in list(self.streams):
            self.close_stream(identifier)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--origin", default="https://api.recordpov.app")
    parser.add_argument("--url", default="https://www.youtube.com/watch?v=jNQXAC9IVRw")
    parser.add_argument("--resolve-version", type=int, choices=(1, 2), default=1)
    args = parser.parse_args()
    origin = urllib.parse.urlsplit(args.origin)
    if origin.scheme != "https" or origin.username or origin.password or origin.path not in ("", "/") or origin.query or origin.fragment:
        raise ValueError("Pass a public HTTPS service origin")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def post(path, payload, token=None, timeout=20):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["X-YouTube-Session-Token"] = token
        request = urllib.request.Request(args.origin.rstrip("/") + path,
                                         data=json.dumps(payload).encode(), headers=headers, method="POST")
        try:
            with opener.open(request, timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = json.load(error).get("error", {})
            raise RuntimeError(f"HTTP {error.code}: {detail.get('code')}: {detail.get('message')}") from None

    session = post("/v1/media/youtube/sessions", {"url": args.url})
    destination = urllib.parse.urlsplit(session["socketUrl"])
    if destination.scheme != "wss" or destination.netloc != origin.netloc or destination.query or destination.fragment:
        raise ValueError("Service returned a different WebSocket origin")
    started = time.monotonic()
    with connect(session["socketUrl"], additional_headers={"X-YouTube-Session-Token": session["token"]},
                 compression=None, proxy=None, max_size=65536, max_queue=16, open_timeout=10) as ws:
        ready = json.loads(ws.recv(timeout=10))
        if ready != {"type": "ready", "version": 1}:
            raise ValueError("Unexpected relay version")
        peer = Peer(ws)
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(post, f"/v{args.resolve_version}/media/resolve",
                                     {"url": args.url, "youtubeSessionId": session["sessionId"]}, session["token"], 650)
                try:
                    while not future.done():
                        if time.monotonic() - started > 630:
                            raise TimeoutError("Peer lease expired")
                        try:
                            peer.handle(ws.recv(timeout=0.25))
                        except TimeoutError:
                            continue
                        except ConnectionClosed:
                            future.result(timeout=5)
                            break
                    result = future.result()
                finally:
                    peer.stop()
                    ws.close()
            delivery = result.get("delivery") or {}
            print(json.dumps({"result": "OK", "source": args.url, "title": result.get("title"),
                              "id": result.get("id"), "duration": result.get("duration"),
                              "hasAudio": result.get("hasAudio"), "playbackUrl": result.get("playbackUrl"),
                              "referencePeerConnections": peer.opened, "bytesFromYouTube": peer.sent,
                              "bytesToYouTube": peer.received, "seconds": round(time.monotonic()-started, 1)}))
            if args.resolve_version == 2:
                # Signed CDN URLs and request headers are capabilities, not logs.
                print(json.dumps({"deliveryKind": delivery.get("kind"),
                                  "assetRoles": [asset.get("role") for asset in delivery.get("assets", [])],
                                  "expected": delivery.get("expected"), "maxBytes": delivery.get("maxBytes")}))
        finally:
            peer.stop()


if __name__ == "__main__":
    main()
