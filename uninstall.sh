#!/bin/bash
set -euo pipefail

removed=0
for d in "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin; do
  if [ -L "$d/cachectl" ] || [ -f "$d/cachectl" ]; then
    rm -f "$d/cachectl"
    echo "Removed $d/cachectl"
    removed=1
  fi
done

if [ -d "$HOME/.local/share/cachectl" ]; then
  rm -rf "$HOME/.local/share/cachectl"
  echo "Removed $HOME/.local/share/cachectl"
  removed=1
fi

[ "$removed" -eq 1 ] || echo "cachectl was not installed."
echo "cachectl keeps no config or state, so nothing else to clean up."
