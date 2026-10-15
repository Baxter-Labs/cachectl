# Contributing

The most valuable contribution is **a new cache target**. If a tool you use
leaves gigabytes on disk and `cachectl` doesn't know about it, that's a gap.

## Adding a cache target

Each OS keeps its caches somewhere different, so a target is a line per OS.
They all use the same pipe-delimited layout:

```
id | category | risk | path | cleaner | description
```

Where the line goes:

| OS | File | Where |
|---|---|---|
| macOS and Linux, same path on both | `cachectl` | first block of `targets()` |
| macOS only | `cachectl` | the `Darwin` block of `targets()` |
| Linux only | `cachectl` | the last block of `targets()` |
| Windows | `cachectl.ps1` | `Get-TargetTable` |

A tool that runs everywhere usually needs a line in both files. Reuse the same
`id` on every OS so `--only` means the same thing everywhere. If you only use
one OS, add the line you can test and say so in the PR; someone else can fill
in the others.

| Field | Meaning |
|---|---|
| `id` | Short kebab-case name, used with `--only`. Must be unique. |
| `category` | `node`, `python`, `rust`, `go`, `jvm`, `dotnet`, `php`, `ruby`, `apple` (macOS only), `android`, `system`, `other` |
| `risk` | `safe`, `review`, or `risky` — see below |
| `path` | Absolute path. This is what gets measured. In `cachectl` use `$H` for `$HOME`, `$X` for the XDG cache dir (`~/.cache`) and `$D` for the XDG data dir (`~/.local/share`). In `cachectl.ps1` use `$U` for `%USERPROFILE%`, `$L` for `%LOCALAPPDATA%` and `$R` for `%APPDATA%`. |
| `cleaner` | `-` to empty the dir, or a command to run instead (`sh -c` on macOS/Linux, `cmd /c` on Windows) |
| `description` | One line. Say what the user loses, not what the tool is. |

Use `cleaner` instead of `-` whenever the tool ships its own garbage collector.
Hand-deleting a store that a package manager tracks in a separate index will
corrupt its state — that's why `homebrew`, `go-mod`, `docker`, `scoop` and
`simulator-unavailable` shell out.

### Picking the risk tier

Be conservative. The tier is a promise to the user.

- **safe** — regenerates automatically with no action from the user beyond a
  normal rebuild or reinstall. Costs time and bandwidth, nothing else.
- **review** — safe to lose, but expensive: multi-gigabyte model weights,
  browser binaries, anything with a slow redownload. Not cleaned unless the user
  passes `--include-review`.
- **risky** — could destroy something the user cannot regenerate: signed
  archives, emulator images, Docker volumes with data in them. Requires both
  `--include-risky` and `--yes`.

If you're unsure between two tiers, pick the more cautious one. A tool that
deletes something surprising once will never be trusted again.

### If your size number lies

Some cleaners are selective — they reclaim less than the measured path. That's
allowed, but say so in the description in capitals, the way
`simulator-unavailable` and `docker` do. Never let the summary imply a user will
get back more space than they actually will.

## Adding a project build directory

Stale build dirs are matched by name: the `names` list in `scan_projects()` in
`cachectl`, and `$BuildDirNames` in `cachectl.ps1`. Add your directory name to
both. Only add names that are unambiguously build output —
`dist` and `build` are already borderline, and anything more generic (`out`,
`tmp`, `data`) will eventually eat someone's source code.

## Safety rules, non-negotiable

Pull requests that weaken any of these will be closed:

1. Dry run stays the default for every destructive command.
2. `path_allowed()` (bash) and `Test-DeleteAllowed` (PowerShell) run before
   every delete. Don't add a bypass.
3. `$HOME`, `/`, `/Users` and `/home` stay hard-rejected, and on Windows so do
   your profile folder, `AppData`, drive roots, `C:\Windows` and `C:\Users`.
4. New paths outside the existing allowlist prefixes need the allowlist widened
   deliberately, in its own commit, with a reason.
5. Nothing is deleted outside the user's home directory. No `sudo` or admin, ever.
6. Deleting never follows a link. On Windows every delete goes through
   `Remove-Tree`, which removes junctions and symlinks as links. Don't swap in
   `Remove-Item -Recurse`.
7. `cachectl.ps1` stays pure ASCII and runs on Windows PowerShell 5.1. That's
   the version every Windows machine has; 5.1 reads a BOM-less file as ANSI.

## Testing

```bash
bash -n cachectl                  # syntax
shellcheck -s bash -S warning cachectl
./cachectl scan --only your-new-id
./cachectl clean --only your-new-id      # confirm the dry run looks right
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\cachectl.ps1 scan --only your-new-id
powershell -ExecutionPolicy Bypass -File .\cachectl.ps1 clean --only your-new-id
Invoke-ScriptAnalyzer -Path .\cachectl.ps1 -ExcludeRule PSAvoidUsingWriteHost
```

CI runs shellcheck and PSScriptAnalyzer, then smoke tests on macOS, Linux, and
Windows (both PowerShell 5.1 and 7). Each one plants a canary file, verifies a dry
run leaves it alone, verifies `--apply` removes it, and checks that deleting a
`node_modules` doesn't follow a link inside it.

## Scope

`cachectl` stays two dependency-free scripts: one in bash for a stock Mac or
Linux box, and one in PowerShell for a stock Windows install. No package manager,
no runtime, no config file, no telemetry, no network calls except the ones a
cleaner command makes on its own. Features that require any of
those belong in a different tool.
