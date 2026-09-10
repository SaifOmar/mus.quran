#!/usr/bin/env python3
"""quranctl — CLI companion to quranproxyd.

Replacement for the retired shell scripts (download.sh, cache.sh,
validate_media.sh), compiled against the SAME policy modules the daemon uses
(urlsafety, dialer, fetch, mediavalidate) so there is one implementation of the
fetch/validation policy.

Subcommands:
  quranctl validate <path>                         validate_media.sh
  quranctl download <id> <n> [--server URL]        download.sh, single file
  quranctl download <id> --only a,b,c [--server URL]  download.sh, bulk
  quranctl remove [--state-dir <dir>] <id> <n>     cache.sh remove (corrupt file)

Stdout contract (Service.qml): `progress_bytes P/100` during a transfer,
`progress DONE/TOTAL` after each completed surah, `complete DONE FAILED` at the
end. `failed <n>` goes to stderr. Exit 0 = all surahs present, 1 = at least one
failed, 2 = usage, 130 = interrupted.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import os
import signal
import sys

from catalog import audio_url
from dialer import Dialer
from fetch import ErrComplete, FetchError, fetch
from mediavalidate import validate_media_file
from urlsafety import is_safe_identifier, parse_surah_arg, sanitize_server


def cmd_validate(args):
    if len(args) != 1 or not args[0]:
        print("usage: quranctl validate <file>", file=sys.stderr)
        return 2
    try:
        if not validate_media_file(args[0]):
            print(f"quranctl validate: invalid media: {args[0]}", file=sys.stderr)
            return 1
    except (OSError, ValueError) as e:
        print(f"quranctl validate: {e}", file=sys.stderr)
        return 1
    return 0


def _new_dialer():
    return Dialer()


def build_origin_url(reciter, server):
    """Production origin-URL builder: validated via audio_url (daemon's exact
    function). A caller-supplied --server is convenience only — never trusted."""
    def builder(n):
        obj = {"identifier": reciter, "server": server} if server else None
        u = audio_url(reciter, n, obj)
        if not u:
            raise FetchError(f"quranctl: invalid origin URL for {reciter}:{n}")
        return u
    return builder


def cmd_download(args):
    reciter, surahs, server, err = parse_download_args(args)
    if err:
        return 2

    home = os.environ.get("HOME")
    if not home:
        print("quranctl: HOME is not set", file=sys.stderr)
        return 2
    state_root = os.path.join(home, ".local", "state", "omarchy", "quran")

    dialer = _new_dialer()
    build_url = build_origin_url(reciter, server)

    interrupted = False
    def _on_signal(signum, frame):
        nonlocal interrupted
        interrupted = True
    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)

    done, failed = 0, 0
    total = len(surahs)
    for n in surahs:
        if interrupted:
            return 130
        def on_progress(written, remote):
            pct = 0
            if remote > 0:
                pct = int(written * 100 // remote)
            pct = min(pct, 100)
            print(f"progress_bytes {pct}/100", file=sys.stdout)
        try:
            fetch(dialer, state_root, reciter, n, build_url, on_progress=on_progress)
            if interrupted:
                return 130
        except ErrComplete:
            done += 1
            print(f"progress {done}/{total}", file=sys.stdout)
            continue
        except FetchError as e:
            if interrupted:
                return 130
            failed += 1
            print(f"failed {n}: {e}", file=sys.stderr)
            continue
        done += 1
        print(f"progress {done}/{total}", file=sys.stdout)

    print(f"complete {done} {failed}", file=sys.stdout)
    return 1 if failed > 0 else 0


def parse_download_args(args):
    positionals = []
    only = ""
    server = None
    i = 0
    while i < len(args):
        if args[i] == "--only":
            if i + 1 >= len(args):
                print("usage: quranctl download <reciter> <n>|--only a,b,c [--server URL]", file=sys.stderr)
                return None, None, None, True
            only = args[i + 1]
            i += 2
        elif args[i] == "--server":
            if i + 1 >= len(args):
                print("usage: quranctl download <reciter> <n>|--only a,b,c [--server URL]", file=sys.stderr)
                return None, None, None, True
            server = args[i + 1]
            i += 2
        else:
            positionals.append(args[i])
            i += 1

    if not positionals:
        print("usage: quranctl download <reciter> <n>|--only a,b,c [--server URL]", file=sys.stderr)
        return None, None, None, True
    reciter = positionals[0]
    if not is_safe_identifier(reciter):
        print("quranctl: invalid reciter identifier", file=sys.stderr)
        return None, None, None, True
    if server is not None and sanitize_server(server) == "":
        print("quranctl: invalid --server URL", file=sys.stderr)
        return None, None, None, True

    surahs = []
    if only:
        for raw in only.split(","):
            raw = raw.strip()
            if raw == "":
                continue
            n = parse_surah_arg(raw)
            if n is None:
                print(f"quranctl: invalid surah number: {raw}", file=sys.stderr)
                return None, None, None, True
            surahs.append(n)
        if not surahs:
            print("quranctl: no surahs in --only list", file=sys.stderr)
            return None, None, None, True
    elif len(positionals) >= 2:
        n = parse_surah_arg(positionals[1])
        if n is None:
            print(f"quranctl: invalid surah number: {positionals[1]}", file=sys.stderr)
            return None, None, None, True
        surahs = [n]
    else:
        print("usage: quranctl download <reciter> <n>|--only a,b,c [--server URL]", file=sys.stderr)
        return None, None, None, True
    return reciter, surahs, server, False


def default_state_dir():
    home = os.path.expanduser("~")
    if home:
        return os.path.join(home, ".local", "state", "omarchy", "quran")
    return ""


def cmd_remove(args):
    state_dir = default_state_dir()
    positionals = []
    i = 0
    while i < len(args):
        if args[i] == "--state-dir" and i + 1 < len(args):
            state_dir = args[i + 1]
            i += 2
        else:
            positionals.append(args[i])
            i += 1

    if len(positionals) != 2:
        print("usage: quranctl remove [--state-dir <dir>] <reciter> <surah>", file=sys.stderr)
        return 2
    rec_id = positionals[0]
    n = parse_surah_arg(positionals[1])
    if not is_safe_identifier(rec_id) or n is None:
        print("remove: invalid reciter or surah", file=sys.stderr)
        return 2
    if not state_dir:
        print("remove: no state dir available", file=sys.stderr)
        return 2
    path = os.path.join(state_dir, rec_id, f"{n}.mp3")
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    except OSError as e:
        print(f"remove: {e}", file=sys.stderr)
        return 1
    return 0


def usage():
    print("usage: quranctl {validate|download|remove} ...", file=sys.stderr)


def main():
    if len(sys.argv) < 2:
        usage()
        return 2
    cmd = sys.argv[1]
    try:
        if cmd == "validate":
            return cmd_validate(sys.argv[2:])
        if cmd == "download":
            return cmd_download(sys.argv[2:])
        if cmd == "remove":
            return cmd_remove(sys.argv[2:])
    except KeyboardInterrupt:
        return 130
    except Exception as e:  # noqa: BLE001 - top-level CLI guard
        print(f"quranctl: {e}", file=sys.stderr)
        return 1
    print(f"quranctl: unknown command {cmd!r}", file=sys.stderr)
    usage()
    return 2


if __name__ == "__main__":
    sys.exit(main())