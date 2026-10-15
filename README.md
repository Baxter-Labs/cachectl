# cachectl

**Find out where your disk went, and get it back.** macOS, Linux and Windows.

[![CI](https://github.com/eshwarpk/cachectl/actions/workflows/ci.yml/badge.svg)](https://github.com/eshwarpk/cachectl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows-black)
![Dependencies](https://img.shields.io/badge/dependencies-none-blue)

Developer machines leak disk in two places, and neither shows up in your OS's storage settings:

1. **Global tool caches** — `~/.cache/uv`, `~/.npm/_cacache`, Xcode DerivedData, simulator runtimes, Gradle, Cargo, Homebrew. Tens of gigabytes, spread across 50+ directories you've never opened.
2. **Stale build dirs rotting inside old repos** — the `node_modules` in a project you last touched in March. Nothing ever cleans these up.

`cachectl` measures both, tells you which are actually dead based on when they were last touched, and deletes only what you approve.

One bash script for macOS and Linux, one PowerShell script for Windows. No dependencies.
No telemetry. No `sudo`, no admin. Free forever.

```
========================================================================
  SUMMARY
    Tool caches, safe to clear now ....       10.50 GB
    Tool caches, all tiers ...........       24.03 GB
    Stale build dirs (19) .............        8.53 GB
------------------------------------------------------------------------
    RECLAIMABLE WITHOUT THINKING .....       19.03 GB
========================================================================

  What to run, in order:

    1. cachectl clean --apply
       Frees 10.50 GB. Everything here regenerates on its own.

    2. cachectl projects --stale-days 30 --apply
       Frees 8.53 GB across 19 dirs. Reinstall deps to get them back.

  Nothing above has been deleted. Every command dry-runs by default.
```

## Install

### macOS and Linux

```bash
curl -fsSL https://raw.githubusercontent.com/eshwarpk/cachectl/main/install.sh | bash
```

Or clone it, which is easy to audit first — it's one file:

```bash
git clone https://github.com/eshwarpk/cachectl.git
cd cachectl
./install.sh
```

Or don't install at all. `./cachectl report` works straight out of the folder.

Uninstall with `./uninstall.sh`. It leaves no config, no state, nothing behind.

### Windows

In PowerShell (no admin needed):

```powershell
irm https://raw.githubusercontent.com/eshwarpk/cachectl/main/install.ps1 | iex
```

Or from a clone: `powershell -ExecutionPolicy Bypass -File .\install.ps1`. Either way
you get a `cachectl` command on your user PATH that works in PowerShell and cmd.
Open a new terminal afterwards.

Or don't install at all: `powershell -ExecutionPolicy Bypass -File .\cachectl.ps1 report`.

Uninstall with `.\uninstall.ps1` (or `irm .../uninstall.ps1 | iex`). It removes the
folder and the PATH entry, and nothing else.

It runs on the Windows PowerShell 5.1 that every Windows 10 and 11 machine already
has, and on PowerShell 7. Commands, flags, risk tiers and safety rules are the same
as on macOS and Linux; everything below applies to all three.

## Use it

```bash
cachectl report
```

That's the whole getting-started guide. It scans everything, prints one grand
total, and tells you which commands to run in what order. It deletes nothing.

### The commands

| Command | What it does |
|---|---|
| `cachectl report` | **Start here.** Everything, one total, ordered next steps. |
| `cachectl scan` | Measure every known tool cache, sorted by size, with age. |
| `cachectl clean` | Delete caches. **Dry run unless you pass `--apply`.** |
| `cachectl projects` | Find stale `node_modules` / `.next` / `target` / `.venv` in your repos. |
| `cachectl top` | Biggest things in your cache folder (`~/Library/Caches`, `~/.cache`, or `%LOCALAPPDATA%`), including ones it doesn't recognise. Read-only. |
| `cachectl list` | Every target it knows about and its risk tier. |

### scan

```
ID                               SIZE     AGE RISK    GROUP     WHAT IT IS
uv                            5.70 GB      0d safe    python    uv package cache
simulator-caches              3.50 GB      0d safe    apple     CoreSimulator caches
user-logs                     2.49 GB     26d review  system    Application logs
avd                           1.40 GB    480d risky   android   Android emulator images
gradle                      337.1 MB     101d safe    jvm       Gradle build/dependency cache

Reclaimable now (risk=safe): 10.50 GB
```

`AGE` is days since it was last touched — your "is this actually being used"
signal. A 480-day-old Android emulator image is dead weight. A 0-day-old npm
cache is doing its job. Size alone can't tell you that.

```bash
cachectl scan --stale-days 90     # only what you haven't touched in 3 months
cachectl scan --min-size 100      # only things over 100 MB
cachectl scan --category node     # one ecosystem at a time
cachectl scan --by-age            # sort by staleness instead of size
```

### clean

**Dry run is the default.** Nothing is deleted until you type `--apply`.

```bash
cachectl clean                    # show exactly what would go
cachectl clean --apply            # do it (asks for confirmation)
cachectl clean --apply --yes      # skip the prompt
cachectl clean --apply --trash    # move to Trash / Recycle Bin instead — recoverable
cachectl clean --only npm,gradle --apply
cachectl clean --include-review --apply
```

### projects

Usually the one that finds the most space.

```bash
cachectl projects                             # $HOME, untouched 30+ days, 50 MB+
cachectl projects --root ~/code --stale-days 60
cachectl projects --stale-days 90 --apply
```

Matches `node_modules`, `.next`, `.nuxt`, `dist`, `build`, `target`, `.turbo`,
`.parcel-cache`, `.venv`, `venv`, `__pycache__`, `.pytest_cache`, `.mypy_cache`,
`.gradle`, `DerivedData`, `vendor/bundle`, `.terraform`. Never descends into a
match, so no nested `node_modules` noise. Only reports dirs that haven't been
modified recently. On Windows it also skips `AppData`, which is where caches and
your global npm packages live, not projects.

## What it knows about

40 to 50 targets per OS, across every major ecosystem. Each OS has its own paths
(`~/Library/Caches/pip`, `~/.cache/pip`, `%LOCALAPPDATA%\pip\Cache`), and
`cachectl list` shows the ones for the machine you're on.

**Node** npm · Yarn · Yarn Berry · pnpm · Bun · node-gyp · Electron · Puppeteer · Playwright
**Python** pip · uv · Poetry · pyenv · Hugging Face · PyTorch
**Rust** Cargo registry · Cargo git · sccache
**Go** build cache · module cache
**JVM** Gradle · Maven · sbt · Coursier
**Apple** (macOS) Xcode DerivedData · iOS/watchOS DeviceSupport · SwiftUI Previews · CoreSimulator · SPM · CocoaPods · Carthage · Archives
**Android** SDK cache · build cache · AVD images
**Other** .NET/NuGet · Composer · Bundler · RubyGems · Deno · Terraform · Docker
**System** Homebrew · app logs · crash reports (macOS) · Homebrew on Linux · desktop thumbnails (Linux) · Scoop · temp folder · crash dumps (Windows)

Missing one? [Open an issue](../../issues/new?template=new-cache-target.md) — it's a one-line addition and the template walks you through it.

## Risk tiers

Every target is classified. The tier decides whether `clean` will touch it.

| Tier | Meaning | Cleaned by default? |
|---|---|---|
| 🟢 **safe** | Regenerates automatically. Costs you a rebuild or a redownload, nothing else. | Yes |
| 🟡 **review** | Safe to lose but expensive to rebuild — ML weights, browser binaries, Maven local repo. | Only with `--include-review` |
| 🔴 **risky** | Can destroy real artifacts — Xcode Archives, Android emulators, Docker volumes. | Only with `--include-risky --yes` |

## Safety

This tool deletes files, so here is exactly what stops it deleting the wrong ones:

- **Dry run is the default** for every destructive command. `--apply` is the only way to remove anything.
- **Allowlist before every delete.** On macOS and Linux a path must live under `~/Library/Caches`, `~/Library/Developer`, `~/Library/Logs`, `~/go/pkg`, or a dotfile dir in `$HOME` (`~/.cache` included). On Windows it must live under `%LOCALAPPDATA%`, `%APPDATA%`, `~\go\pkg`, or a dot-folder in your profile. Anything else is refused and reported, not deleted.
- **Home and system roots are hard-rejected** regardless of how a target is configured: `$HOME`, `/`, `/Users` and `/home`; on Windows your profile folder, `AppData` itself, drive roots, `C:\Windows` and `C:\Users`. Path traversal (`..`) is rejected.
- **Links are never followed.** Deleting a folder removes the symlinks and junctions inside it as links, never what they point to. pnpm and `npm link` put those in `node_modules`; `rm -rf` already behaves this way, and the Windows port walks the tree itself to guarantee the same.
- **`--trash` is recoverable**: Finder on macOS, `gio trash` or `trash-put` on Linux, the Recycle Bin on Windows (where, as in Explorer, anything too big for the Recycle Bin is deleted outright).
- **Tool-native cleaners where they exist.** `brew cleanup`, `go clean -modcache`, `docker system prune`, `xcrun simctl delete unavailable`, `scoop cache rm` — hand-deleting a store that a package manager indexes separately would corrupt its state.
- **Never runs `sudo` or asks for admin.** Never touches anything outside your home directory. Never makes a network call of its own.
- **CI plants a canary file** on every commit on macOS, Linux and Windows, runs a dry run, and fails the build if the canary disappears. It also checks that deleting a `node_modules` never follows a link out of it.

Two targets deliberately report a size larger than what cleaning them reclaims,
because their cleaner is selective — `simulator-unavailable` and `docker`. Both
say so in capitals in their own description. The summary never inflates what
you'll get back.

## Contributing

New cache targets are the most useful contribution, and they're one line of
code. See [CONTRIBUTING.md](CONTRIBUTING.md).

## FAQ

**Is this safe to run?**
`report`, `scan`, `top`, and `list` never write anything. `clean` and `projects`
dry-run unless you pass `--apply`. Read the script first if you want — it's one
file per platform and the delete logic is short.

**Will it break my dev environment?**
Clearing a `safe` cache means the next build or install is slower because things
get re-downloaded. That's the entire cost. Nothing needs reconfiguring.

**Why not just delete `~/Library/Caches` (or `~/.cache`, or `%LOCALAPPDATA%`)?**
Because some of what's in there is expensive to rebuild and some belongs to apps
that behave badly when it vanishes mid-run. Tiering exists so you can be
aggressive where it's free and careful where it isn't.

**Does it work on Linux?**
Yes, with the same script. It follows `XDG_CACHE_HOME` and `XDG_DATA_HOME` when
you set them. `--trash` needs `gio` (part of GLib, on most desktops already) or
`trash-cli`.

**And Windows?**
Yes, through `cachectl.ps1`, a PowerShell port with the same commands. Under WSL,
the bash script cleans the Linux side; run the PowerShell one for the Windows side.

**Why is the first scan slow?**
Sizes come from `du` (on Windows, an equivalent walk), which visits every file.
A big home directory takes a minute. Use `--no-projects` on `report` for a fast pass.

## License

MIT. Use it, fork it, ship it.
