#!/bin/bash
#
# Behaviour checks for the parts of cachectl that decide what gets deleted.
# Everything runs against a throwaway $HOME; the real one is never touched.
#
set -u

CACHECTL="$(cd "$(dirname "$0")" && pwd -P)/cachectl"
T="$(cd "$(mktemp -d)" && pwd -P)"   # resolved, because lsof reports real paths
UV="$T/.cache/uv"
P="$T/code"
FAILS=0
PIDS=""

cleanup() {
  local pid
  for pid in $PIDS; do
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
  done
  rm -rf "$T"
}
trap cleanup EXIT

run() { HOME="$T" "$CACHECTL" "$@" </dev/null 2>&1; }
answer() { local a="$1"; shift; printf '%s\n' "$a" | HOME="$T" "$CACHECTL" "$@" 2>&1; }

check() {
  local name="$1"; shift
  if "$@"; then printf 'ok    %s\n' "$name"
  else printf 'FAIL  %s\n' "$name"; FAILS=$(( FAILS + 1 )); fi
}
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
says() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
omits() { ! says "$1"; }
row_numbered() { printf '%s\n' "$OUT" | grep -qE "^ *$1 +[0-9.]+ [KMG]B +[0-9]+d  $2\$"; }

# A directory with a 1 MB file in it (n MB when given).
dir() { mkdir -p "$1"; head -c $(( ${2:-1} * 1048576 )) /dev/zero > "$1/blob"; }
# Backdate a tree so nothing in it looks recent.
old() { find "$@" -exec touch -h -t 202001010000 {} + ; }
background() { PIDS="$PIDS $!"; }

# --------------------------------------------------------------- uv target --

plant_uv() {
  rm -rf "$UV"
  local a="$UV/archive-v0" b="$UV/builds-v0" e="$UV/environments-v2/abc"
  dir "$a/idle"; dir "$a/-dashidle"; dir "$b/.tmpidle"
  dir "$a/by-argv"; dir "$a/by-env"; dir "$a/by-open"; dir "$a/-dashlive"; dir "$b/.tmplive"
  mkdir -p "$UV/wheels-v6" "$e"; touch "$UV/wheels-v6/pointer"
  ln -s "$a/idle" "$e/gone"; ln -s "$a/by-argv" "$e/kept"
  old "$UV"
  dir "$a/fresh"
}

plant_uv

# Each way a running tool can show it is using an entry: its command line, the
# PATH uvx gives it, a file it holds open. An id may start with a dash.
sh -c 'sleep 300; :' "$UV/archive-v0/by-argv/bin/python" >/dev/null 2>&1 & background
sh -c 'sleep 300; :' "$UV/archive-v0/-dashlive/bin/python" >/dev/null 2>&1 & background
sh -c 'sleep 300; :' "$UV/builds-v0/.tmplive/bin/python" >/dev/null 2>&1 & background
( exec 9<"$UV/archive-v0/by-open/blob"; sleep 300 ) >/dev/null 2>&1 & background
# ps -E hides the environment of Apple's own binaries, so sh and sleep can't stand
# in here. It needs an ordinary binary, like the Python uvx really runs.
printf '#include <unistd.h>\nint main(void){sleep(300);return 0;}\n' | cc -x c - -o "$T/nap" 2>/dev/null
if [ -x "$T/nap" ]; then
  PATH="$UV/archive-v0/by-env/bin:$PATH" "$T/nap" >/dev/null 2>&1 & background
else
  echo "skip  uv: entry on a process PATH kept (no cc to build a test process)"
  rm -rf "$UV/archive-v0/by-env"
fi
sleep 1

OUT="$(run clean --only uv)"
check "uv dry run counts only what can really go (3 idle entries, 3 MB)" says "3.0 MB"
check "uv dry run deletes nothing" test -e "$UV/archive-v0/idle/blob"

OUT="$(run clean --only uv --apply --yes)"
check "uv: idle archive entry removed"            absent "$UV/archive-v0/idle"
check "uv: idle entry with a leading dash removed" absent "$UV/archive-v0/-dashidle"
check "uv: idle build entry removed"              absent "$UV/builds-v0/.tmpidle"
check "uv: entry named on a command line kept"    test -e "$UV/archive-v0/by-argv/blob"
check "uv: entry with a leading dash kept"        test -e "$UV/archive-v0/-dashlive/blob"
check "uv: build entry in use kept"               test -e "$UV/builds-v0/.tmplive/blob"
[ ! -x "$T/nap" ] || check "uv: entry on a process PATH kept" test -e "$UV/archive-v0/by-env/blob"
check "uv: entry with a file held open kept"      test -e "$UV/archive-v0/by-open/blob"
check "uv: entry younger than a day kept"         test -e "$UV/archive-v0/fresh/blob"
check "uv: unrelated cache buckets kept"          test -e "$UV/wheels-v6/pointer"
check "uv: link to a removed entry dropped"       absent "$UV/environments-v2/abc/gone"
check "uv: link to a kept entry kept"             test -L "$UV/environments-v2/abc/kept"
check "uv: freed space is what really went"       says "Freed: 3.0 MB"

# If running processes can't be listed, nothing can be called idle.
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 1\n' > "$T/bin/lsof"; chmod +x "$T/bin/lsof"
dir "$UV/archive-v0/idle-2"; old "$UV/archive-v0/idle-2"
OUT="$(PATH="$T/bin:$PATH" run clean --only uv --apply --yes)"
check "uv: nothing deleted when processes can't be listed" test -e "$UV/archive-v0/idle-2/blob"
OUT="$(PATH="$T/bin:$PATH" run projects --root "$T" --min-size 0)"
check "projects: refuses when processes can't be listed" says "could not list running processes"
rm -rf "${T:?}/bin"

# ---------------------------------------------------------------- projects --

plant_projects() {
  rm -rf "$P"; mkdir -p "$P"

  # Stale: sorted by size these are rows 1, 2, 3.
  dir "$P/idle/node_modules" 3; dir "$P/idle/src"

  dir "$P/repo/build" 2; printf 'build/\n' > "$P/repo/.gitignore"
  git -C "$P/repo" init -q

  dir "$P/month/node_modules" 1; dir "$P/month/src"

  # Not stale, or not safely build output.
  dir "$P/active/node_modules"; dir "$P/active/src"
  dir "$P/running/node_modules"; dir "$P/running/src"
  dir "$P/plain/build"; touch "$P/plain/README"
  dir "$P/tracked/build"; git -C "$P/tracked" init -q; git -C "$P/tracked" add build
  dir "$P/vendored/node_modules"; git -C "$P/vendored" init -q; git -C "$P/vendored" add node_modules
  dir "$P/untracked/dist"; git -C "$P/untracked" init -q

  old "$P"

  touch "$P/active/src/app.js"
  touch -t "$(date -v-40d +%Y%m%d%H%M)" "$P/month/src/app.js"
}

plant_projects
( cd "$P/running" && exec sleep 300 ) >/dev/null 2>&1 & background
sleep 1

OUT="$(run projects --root "$P" --min-size 0)"
check "projects: idle project listed"                       says "$P/idle/node_modules"
check "projects: recent source edit means not stale"        omits "$P/active/node_modules"
check "projects: process inside the project means not stale" omits "$P/running/node_modules"
check "projects: AGE is the project's last change, not the dir's" says "40d  $P/month/node_modules"
check "projects: git-ignored build dir listed"              says "$P/repo/build"
check "projects: build dir outside git not listed"          omits "$P/plain/build"
check "projects: tracked build dir not listed"              omits "$P/tracked/build"
check "projects: tracked node_modules not listed"           omits "$P/vendored/node_modules"
check "projects: untracked, unignored dist not listed"      omits "$P/untracked/dist"
check "projects: dry run deletes nothing"                   test -e "$P/idle/node_modules/blob"
check "projects: biggest row is number 1"                   row_numbered 1 "$P/idle/node_modules"
check "projects: next biggest is number 2"                  row_numbered 2 "$P/repo/build"

OUT="$(run projects --root "$P/idle" --min-size 0)"
check "projects: naming a project as --root doesn't make it look busy" says "$P/idle/node_modules"

OUT="$(answer "" projects --root "$P" --min-size 0 --apply)"
check "pick: Enter deletes nothing"          test -e "$P/idle/node_modules/blob"
OUT="$(answer "y" projects --root "$P" --min-size 0 --apply)"
check "pick: y is not a pick, deletes nothing" test -e "$P/idle/node_modules/blob"
OUT="$(answer "2 nope" projects --root "$P" --min-size 0 --apply)"
check "pick: a typo beside a number deletes nothing" test -e "$P/repo/build/blob"
OUT="$(answer "99" projects --root "$P" --min-size 0 --apply)"
check "pick: out of range deletes nothing"   test -e "$P/idle/node_modules/blob"

OUT="$(answer "2" projects --root "$P" --min-size 0 --apply)"
check "pick: chosen row deleted"             absent "$P/repo/build"
check "pick: row before it kept"             test -e "$P/idle/node_modules/blob"
check "pick: row after it kept"              test -e "$P/month/node_modules/blob"
check "pick: only the chosen row counted"    says "Freed: 2.0 MB"

plant_projects
OUT="$(answer "1, 3" projects --root "$P" --min-size 0 --apply)"
check "pick: several rows deleted"           absent "$P/idle/node_modules"
check "pick: third row deleted too"          absent "$P/month/node_modules"
check "pick: row between them kept"          test -e "$P/repo/build/blob"

plant_projects
OUT="$(answer "all" projects --root "$P" --min-size 0 --apply)"
check "pick: all deletes every listed row"   absent "$P/idle/node_modules"
check "pick: all leaves unlisted dirs alone" test -e "$P/plain/build/blob"

plant_projects
OUT="$(run projects --root "$P" --min-size 0 --apply --yes)"
check "--yes deletes every listed row"       absent "$P/idle/node_modules"
check "--yes leaves unlisted dirs alone"     test -e "$P/tracked/build/blob"

# ------------------------------------------------------------------ result --

echo
if [ "$FAILS" -eq 0 ]; then echo "All checks passed."
else echo "$FAILS check(s) failed."; exit 1; fi
