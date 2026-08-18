#!/usr/bin/env bash
# Uninstall the mus.quran audio engine and all local mus.quran data.
#
# Removes:
#   - quranproxyd + quranctl binaries installed by install.sh
#   - downloaded audio
#   - cache
#   - settings
#
# Idempotent, never needs sudo (only touches the user's own dirs).
#
# Usage:
#   uninstall.sh
#   uninstall.sh --prefix DIR
#
# Examples:
#   ./uninstall.sh
#   ./uninstall.sh --prefix "$HOME/.local/share/bin"

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while (($# > 0)); do
  case "$1" in
  --prefix)
    if (($# < 2)); then
      echo "uninstall.sh: --prefix requires a directory" >&2
      exit 2
    fi
    PREFIX="$2"
    shift
    ;;
  -h | --help)
    usage
    ;;
  *)
    echo "uninstall.sh: unknown option: $1" >&2
    exit 2
    ;;
  esac
  shift
done

removed=0

for bin in quranproxyd quranctl; do
  path="$PREFIX/$bin"

  if [[ -e "$path" || -L "$path" ]]; then
    rm -f -- "$path"
    echo "uninstall.sh: removed $path"
    removed=1
  fi
done

if (( ! removed )); then
  echo "uninstall.sh: no quranproxyd/quranctl binaries found in $PREFIX"
fi

data_paths=(
  "$HOME/.local/state/omarchy/quran"
  "$HOME/.cache/omarchy/quran"
  "$HOME/.local/state/omarchy/settings/quran.json"
)

for path in "${data_paths[@]}"; do
  if [[ -e "$path" || -L "$path" ]]; then
    rm -rf -- "$path"
    echo "uninstall.sh: removed $path"
  fi
done

echo "uninstall.sh: mus.quran has been uninstalled."
echo "uninstall.sh: restart your Omarchy shell (or disable/remove the plugin) to unload the engine."
