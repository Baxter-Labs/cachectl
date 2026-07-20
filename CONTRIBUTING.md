# Contributing

The most valuable contribution is **a new cache target**. If a tool you use
leaves gigabytes on disk and `cachectl` doesn't know about it, that's a gap.

## Adding a cache target

Open `cachectl`, find the `targets()` function, and add one pipe-delimited line:

```
id | category | risk | path | cleaner | description
```

| Field | Meaning |
|---|---|
| `id` | Short kebab-case name, used with `--only`. Must be unique. |
| `category` | `node`, `python`, `rust`, `go`, `jvm`, `dotnet`, `php`, `ruby`, `apple`, `android`, `system`, `other` |
| `risk` | `safe`, `review`, or `risky` — see below |
| `path` | Absolute path, using `$H` for `$HOME`. This is what gets measured. |
| `cleaner` | `-` to delete the dir and recreate it empty, or a shell command to run instead |
| `description` | One line. Say what the user loses, not what the tool is. |

Use `cleaner` instead of `-` whenever the tool ships its own garbage collector.
Hand-deleting a store that a package manager tracks in a separate index will
corrupt its state — that's why `homebrew`, `go-mod`, `docker` and
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

Stale build dirs are matched by name in `scan_projects()`. Add your directory
name to the `names` list. Only add names that are unambiguously build output —
`dist` and `build` are already borderline, and anything more generic (`out`,
`tmp`, `data`) will eventually eat someone's source code.

## Safety rules, non-negotiable

Pull requests that weaken any of these will be closed:

1. Dry run stays the default for every destructive command.
2. `path_allowed()` runs before every `rm`. Don't add a bypass.
3. `$HOME`, `/`, and `/Users` stay hard-rejected.
4. New paths outside the existing allowlist prefixes need the allowlist widened
   deliberately, in its own commit, with a reason.
5. Nothing is deleted outside the user's home directory. No `sudo`, ever.

## Testing

```bash
bash -n cachectl                  # syntax
shellcheck -s bash -S warning cachectl
./cachectl scan --only your-new-id
./cachectl clean --only your-new-id      # confirm the dry run looks right
```

CI runs shellcheck plus a macOS smoke test that plants a canary file, verifies a
dry run leaves it alone, and verifies `--apply` removes it.

## Scope

`cachectl` stays a single dependency-free bash script that runs on a stock Mac.
No package manager, no runtime, no config file, no telemetry, no network calls
except the ones a cleaner command makes on its own. Features that require any of
those belong in a different tool.
