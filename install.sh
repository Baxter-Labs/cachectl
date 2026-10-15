#!/bin/bash
#
# cachectl installer for macOS and Linux. (Windows: install.ps1)
#
# Works two ways:
#   1. Cloned repo:  ./install.sh        (symlinks the local script)
#   2. One-liner:    curl -fsSL https://raw.githubusercontent.com/eshwarpk/cachectl/main/install.sh | bash
#                    (downloads the script into ~/.local/share/cachectl)
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/eshwarpk/cachectl/main"

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*)
    die "on Windows, install from PowerShell instead: irm $REPO_RAW/install.ps1 | iex" ;;
  *) die "cachectl supports macOS and Linux (and Windows via install.ps1), not $OS." ;;
esac

# Locate the script: next to this installer if cloned, otherwise download it.
SRC=""
HERE=""
[ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Require both files present, so a stray ./cachectl can't hijack the curl path.
if [ -n "$HERE" ] && [ -f "$HERE/cachectl" ] && [ -f "$HERE/install.sh" ]; then
  SRC="$HERE/cachectl"
  say "Using local cachectl at $SRC"
else
  SHARE="$HOME/.local/share/cachectl"
  mkdir -p "$SHARE"
  say "Downloading cachectl..."
  curl -fsSL "$REPO_RAW/cachectl" -o "$SHARE/cachectl" || die "download failed"
  SRC="$SHARE/cachectl"
fi

chmod +x "$SRC"

# Prefer a dir already on PATH; fall back to ~/.local/bin.
DEST=""
for d in "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin; do
  case ":$PATH:" in *":$d:"*) [ -d "$d" ] && [ -w "$d" ] && { DEST="$d"; break; } ;; esac
done
if [ -z "$DEST" ]; then
  for d in "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin; do
    [ -d "$d" ] && [ -w "$d" ] && { DEST="$d"; break; }
  done
fi
[ -n "$DEST" ] || { DEST="$HOME/.local/bin"; mkdir -p "$DEST"; }

ln -sf "$SRC" "$DEST/cachectl"
say "Installed: $DEST/cachectl"

case ":$PATH:" in
  *":$DEST:"*) ;;
  *)
    say ""
    case "${SHELL##*/}" in
      zsh)  RC="$HOME/.zshrc" ;;
      bash) if [ "$OS" = Darwin ]; then RC="$HOME/.bash_profile"; else RC="$HOME/.bashrc"; fi ;;
      *)    RC="your shell's startup file" ;;
    esac
    say "$DEST is not on your PATH yet. Add this line to $RC:"
    say "  export PATH=\"$DEST:\$PATH\""
    say "then open a new terminal."
    ;;
esac

say ""
say "Done. Start with:"
say "  cachectl report"
say ""
say "Nothing is ever deleted without an explicit --apply flag."
