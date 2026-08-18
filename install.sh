#!/usr/bin/env bash
# Install the mus.quran audio engine (quranproxyd daemon + quranctl CLI).
#
# The plugin ships prebuilt static binaries (prebuilt/<os>-<arch>/), so the
# default install is a plain copy — no Go toolchain needed. Pass --build to
# compile locally instead.
#
# Usage:
#   install.sh                 copy prebuilt binaries for this machine
#   install.sh --build         build from source (needs Go 1.26+)
#   install.sh --prefix DIR    install into DIR (default: ~/.local/bin)
#   install.sh --arch amd64    force an architecture (amd64|arm64)
#
# Idempotent, never needs sudo (installs into the user's own bin dir).

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
BUILD=0
ARCH=""

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while (($# > 0)); do
  case "$1" in
  --build) BUILD=1 ;;
  --prefix) PREFIX="$2"; shift ;;
  --arch) ARCH="$2"; shift ;;
  -h | --help) usage ;;
  *) echo "install.sh: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$(uname -s)" in
Linux) ;;
*) echo "install.sh: unsupported OS: $(uname -s) (Linux only)" >&2; exit 1 ;;
esac

if [[ -z $ARCH ]]; then
  case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "install.sh: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$PREFIX"

if ((BUILD)); then
  if ! command -v go >/dev/null 2>&1; then
    echo "install.sh: --build needs a Go toolchain (go 1.26+)" >&2
    exit 1
  fi
  GOFLAGS="-trimpath -ldflags=-s" CGO_ENABLED=0 \
    GOOS=linux GOARCH="$ARCH" go build -o "$PREFIX/quranproxyd" ./cmd/quranproxyd
  GOFLAGS="-trimpath -ldflags=-s" CGO_ENABLED=0 \
    GOOS=linux GOARCH="$ARCH" go build -o "$PREFIX/quranctl" ./cmd/quranctl
  echo "install.sh: built quranproxyd + quranctl (linux/$ARCH) into $PREFIX"
else
  if [[ ! -x "$SRC_DIR/prebuilt/linux-$ARCH/quranproxyd" \
        || ! -x "$SRC_DIR/prebuilt/linux-$ARCH/quranctl" ]]; then
    echo "install.sh: no prebuilt binaries for linux/$ARCH (use --build, or check the repo)" >&2
    exit 1
  fi
  install -m 0755 "$SRC_DIR/prebuilt/linux-$ARCH/quranproxyd" "$PREFIX/quranproxyd"
  install -m 0755 "$SRC_DIR/prebuilt/linux-$ARCH/quranctl" "$PREFIX/quranctl"
  echo "install.sh: installed prebuilt quranproxyd + quranctl (linux/$ARCH) into $PREFIX"
fi

echo "install.sh: restart your Omarchy shell (or re-enable the plugin) to load the engine."