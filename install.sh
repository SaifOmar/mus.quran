#!/usr/bin/env bash
# Install the mus.quran audio engine (quranproxyd daemon + quranctl CLI).
#
# Downloads attested prebuilt binaries from GitHub Releases by default.
# Pass --build to compile locally instead.
#
# Usage:
#   install.sh                 download + install prebuilt binaries
#   install.sh --build         build from source (needs Go 1.22+)
#   install.sh --prefix DIR    install into DIR (default: ~/.local/bin)
#   install.sh --arch amd64    force an architecture (amd64|arm64)
#
# Idempotent, never needs sudo (installs into the user's own bin dir).

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
BUILD=0
ARCH=""
REPO="saifomar/mus.quran"

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
    echo "install.sh: --build needs a Go toolchain (go 1.22+)" >&2
    exit 1
  fi
  CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" go build -trimpath -ldflags="-s -w" -o "$PREFIX/quranproxyd" ./cmd/quranproxyd
  CGO_ENABLED=0 GOOS=linux GOARCH="$ARCH" go build -trimpath -ldflags="-s -w" -o "$PREFIX/quranctl" ./cmd/quranctl
  echo "install.sh: built quranproxyd + quranctl (linux/$ARCH) into $PREFIX"
else
  # Try local prebuilts first (in case they exist from a previous install)
  if [[ -x "$SRC_DIR/prebuilt/linux-$ARCH/quranproxyd" \
        && -x "$SRC_DIR/prebuilt/linux-$ARCH/quranctl" ]]; then
    install -m 0755 "$SRC_DIR/prebuilt/linux-$ARCH/quranproxyd" "$PREFIX/quranproxyd"
    install -m 0755 "$SRC_DIR/prebuilt/linux-$ARCH/quranctl" "$PREFIX/quranctl"
    echo "install.sh: installed prebuilt quranproxyd + quranctl (linux/$ARCH) into $PREFIX"
  else
    # Download from GitHub Releases
    if ! command -v curl >/dev/null 2>&1; then
      echo "install.sh: curl is required for downloading (or use --build)" >&2
      exit 1
    fi

    TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
    if [[ -z "$TAG" ]]; then
      echo "install.sh: could not determine latest release tag" >&2
      exit 1
    fi

    echo "install.sh: downloading $TAG for linux/$ARCH..."
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    curl -fsSL "https://github.com/$REPO/releases/download/$TAG/linux-$ARCH.tar.gz" -o "$TMPDIR/linux-$ARCH.tar.gz"
    tar -xzf "$TMPDIR/linux-$ARCH.tar.gz" -C "$TMPDIR"

    # Verify checksums
    if [[ -f "$TMPDIR/linux-$ARCH/SHA256SUMS" ]]; then
      (cd "$TMPDIR/linux-$ARCH" && sha256sum -c SHA256SUMS)
    fi

    install -m 0755 "$TMPDIR/linux-$ARCH/quranproxyd" "$PREFIX/quranproxyd"
    install -m 0755 "$TMPDIR/linux-$ARCH/quranctl" "$PREFIX/quranctl"
    echo "install.sh: installed quranproxyd + quranctl ($TAG, linux/$ARCH) into $PREFIX"
  fi
fi

echo "install.sh: restart your Omarchy shell (or re-enable the plugin) to load the engine."
