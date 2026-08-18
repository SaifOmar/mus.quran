```bash
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
#   ./uninstall.sh

set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"

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
```
