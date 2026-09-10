#!/usr/bin/env python3
"""quranproxyd — local range-caching proxy for mus.quran.

Serves surah audio at http://127.0.0.1:<port>/stream?... over a
DNS-pinned, validated, range-caching pipeline. Writes a handoff
file (quranproxy.json) with port + session token so Service.qml can
target mpv at http://127.0.0.1:<port>/stream?tok=...

Usage:
    quranproxyd --state-file <path> --state-dir <dir> --cache-dir <dir> --token-file <path>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import argparse
import os
import signal
import threading
import time

from proxyhandler import ProxyServer
from rangecache import RangeCache
from session import new_token, write_handoff


def parse_args():
    p = argparse.ArgumentParser(description="quranproxyd — Quran audio proxy")
    p.add_argument("--state-file", required=True, help="Path to quran.json")
    p.add_argument("--state-dir", required=True, help="State directory")
    p.add_argument("--cache-dir", required=True, help="Cache directory")
    p.add_argument("--token-file", required=True, help="Handoff file path")
    p.add_argument("--listen", default="127.0.0.1:0", help="Listen address")
    p.add_argument("--socket-path", default="", help="Unix socket path for control plane")
    p.add_argument("--budget-bytes", type=int, default=0, help="Cache budget in bytes")
    p.add_argument("--max-concurrent", type=int, default=4, help="Max concurrent fetches")
    p.add_argument("--max-surah-bytes", type=int, default=314572800, help="Max surah size")
    return p.parse_args()


def watch_state_file(state_path, cache, budget, logger):
    import json as _json
    last_mod = 0
    last_size = 0

    def _poll():
        nonlocal last_mod, last_size
        while True:
            try:
                fi = os.stat(state_path)
                if fi.st_mtime == last_mod and fi.st_size == last_size:
                    time.sleep(2)
                    continue
                last_mod = fi.st_mtime
                last_size = fi.st_size
                with open(state_path) as f:
                    data = _json.load(f)
                reciters = data.get("reciters", [])
                if budget == 0:
                    b = data.get("cacheLimitMb", 0) * 1024 * 1024
                    if b > 0:
                        cache.set_budget(b)
                logger(f"catalog updated: {len(reciters)} reciters")
            except (OSError, _json.JSONDecodeError):
                pass
            time.sleep(2)

    t = threading.Thread(target=_poll, daemon=True)
    t.start()


def main():
    args = parse_args()
    logger = lambda msg: print(f"quranproxyd: {msg}", file=sys.stderr)

    cache = RangeCache(args.cache_dir, budget_bytes=args.budget_bytes)
    tok = new_token()

    listen_addr, listen_port = args.listen.split(":")
    listen_port = int(listen_port)

    proxy = ProxyServer(
        cache_dir=args.cache_dir,
        state_path=args.state_file,
        token=tok,
        bind=listen_addr,
        port=listen_port,
        max_surah_bytes=args.max_surah_bytes,
        state_dir=args.state_dir,
    )
    server = proxy.start()
    port = server.server_address[1]

    sock_path = args.socket_path or os.path.join(
        os.path.dirname(os.path.abspath(args.token_file)), "quranproxy.sock")
    control = proxy.start_control(sock_path)
    threading.Thread(target=control.serve_forever, daemon=True).start()

    handoff_ok = write_handoff(sock_path, port, tok, args.token_file)
    if not handoff_ok:
        logger(f"failed to write handoff to {args.token_file}")
        proxy.shutdown()
        sys.exit(1)

    watch_state_file(args.state_file, cache, args.budget_bytes, logger)

    stop_event = threading.Event()

    def _shutdown(signum, frame):
        if stop_event.is_set():
            return
        logger("shutting down")
        stop_event.set()
        threading.Thread(target=proxy.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    logger(f"listening on {listen_addr}:{port} (budget={cache.budget_bytes}, max-surah={args.max_surah_bytes})")

    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        proxy.shutdown()
        try:
            os.remove(args.token_file)
        except OSError:
            pass


if __name__ == "__main__":
    main()