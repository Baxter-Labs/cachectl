#
# cachectl.ps1 - inspect and reclaim developer cache space on Windows
#
# The Windows port of the cachectl bash script (macOS and Linux). Same
# commands, flags, risk tiers and safety model:
#   * Nothing is ever deleted unless you pass --apply.
#   * Every target has a risk tier: safe | review | risky.
#   * `clean` only touches `safe` targets unless you opt in explicitly.
#   * Deletion paths are validated against an allowlist of prefixes before
#     anything is removed. A target that fails validation is skipped loudly.
#   * Junctions and symlinks are never followed. Deleting a tree removes a
#     link inside it as a link, and never touches what it points to.
#
# Runs on the Windows PowerShell 5.1 that ships with Windows 10 and 11, and on
# PowerShell 7. Keep this file pure ASCII: 5.1 reads a BOM-less script as ANSI.
#
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Version = '1.1.0'

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
  [Console]::Error.WriteLine('cachectl.ps1 is the Windows build. On macOS and Linux, run the cachectl bash script.')
  exit 1
}

# ---------------------------------------------------------------- formatting --

$UseColor = -not [Console]::IsOutputRedirected
$Inv = [Globalization.CultureInfo]::InvariantCulture

# Write text, optionally coloured, optionally without a newline.
function Write-Out([string]$Text = '', [string]$Fg = '', [switch]$NoNewline) {
  if ($Fg -and $UseColor) { Write-Host $Text -ForegroundColor $Fg -NoNewline:$NoNewline }
  else { Write-Host $Text -NoNewline:$NoNewline }
}
function Write-Warn([string]$Text) { Write-Out $Text Yellow }
function Exit-WithError([string]$Text) { $host.UI.WriteErrorLine($Text); exit 1 }

# A one-line progress indicator on stderr, overwritten in place.
function Show-Status([string]$Text) {
  if (-not [Console]::IsErrorRedirected) { [Console]::Error.Write(("`r  {0,-50}" -f $Text)) }
}
function Clear-Status {
  if (-not [Console]::IsErrorRedirected) { [Console]::Error.Write("`r" + (' ' * 70) + "`r") }
}

# Convert kilobytes to a human string.
function Format-Size([long]$Kb) {
  if ($Kb -lt 1024) { return "$Kb KB" }
  if ($Kb -lt 1048576) { return ($Kb / 1024).ToString('0.0', $Inv) + ' MB' }
  return ($Kb / 1048576).ToString('0.00', $Inv) + ' GB'
}

function Get-RiskColor([string]$Risk) {
  switch ($Risk) { 'safe' { 'Green' } 'review' { 'Yellow' } 'risky' { 'Red' } default { '' } }
}

# Show a path under your profile as ~\...
function Format-Home([string]$Path) {
  $u = $env:USERPROFILE.TrimEnd('\')
  if ($Path -ieq $u) { return '~' }
  if ($Path.StartsWith("$u\", [StringComparison]::OrdinalIgnoreCase)) { return '~' + $Path.Substring($u.Length) }
  return $Path
}

# ------------------------------------------------------------------ measuring --

$NowUtc = [DateTime]::UtcNow
$ReparsePoint = [IO.FileAttributes]::ReparsePoint
$DirectoryAttr = [IO.FileAttributes]::Directory
$ReadOnlyAttr = [IO.FileAttributes]::ReadOnly

# Windows PowerShell 5.1 runs on .NET Framework, which handles paths over 260
# characters (deep node_modules) only when they carry the \\?\ prefix. Probe
# once whether this .NET understands it; PowerShell 7 copes either way.
$LongPrefix = ''
try {
  if ((New-Object IO.DirectoryInfo ('\\?\' + $env:SystemRoot)).Exists) { $LongPrefix = '\\?\' }
} catch { $LongPrefix = '' }

# A drive-letter path like C:\..., the only kind cachectl will measure or delete.
function Test-LocalPath([string]$Path) { return ($Path -match '^[A-Za-z]:\\') }

function Get-IOPath([string]$Path) {
  if ($LongPrefix -and (Test-LocalPath $Path)) { return $LongPrefix + $Path }
  return $Path
}
function Get-PlainPath([string]$Path) {
  if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
  return $Path
}

function Test-IsLink([string]$Path) {
  $d = New-Object IO.DirectoryInfo (Get-IOPath $Path)
  return ($d.Exists -and ($d.Attributes -band $ReparsePoint))
}

# Size of a file or folder tree in KB. Links (junctions, symlinks) are never
# followed, so nothing is counted twice and a link cannot lead outside the
# tree. Unreadable folders are skipped. Missing path -> 0.
function Get-SizeKb([string]$Path) {
  $bytes = [long]0
  try {
    $root = New-Object IO.DirectoryInfo (Get-IOPath $Path)
    if (-not $root.Exists) {
      $file = New-Object IO.FileInfo (Get-IOPath $Path)
      if ($file.Exists) { $bytes = $file.Length }
      return [long][math]::Ceiling($bytes / 1024)
    }
  } catch { return 0 }
  if ($root.Attributes -band $ReparsePoint) { return 0 }

  $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
  $stack.Push($root)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try { $entries = $dir.GetFileSystemInfos() } catch { continue }
    foreach ($e in $entries) {
      if ($e.Attributes -band $ReparsePoint) { continue }
      if ($e.Attributes -band $DirectoryAttr) { $stack.Push($e) } else { $bytes += $e.Length }
    }
  }
  return [long][math]::Ceiling($bytes / 1024)
}

# Whole days since the path was last modified. Missing path -> -1.
function Get-Age([string]$Path) {
  try {
    $item = New-Object IO.DirectoryInfo (Get-IOPath $Path)
    if (-not $item.Exists) { $item = New-Object IO.FileInfo (Get-IOPath $Path) }
    if (-not $item.Exists) { return -1 }
  } catch { return -1 }
  return [int][math]::Floor(($NowUtc - $item.LastWriteTimeUtc).TotalDays)
}

# -------------------------------------------------------------------- targets --

# Record layout, pipe delimited:
#   id | category | risk | path | cleaner | description
#
# cleaner is "-" to mean "empty the folder", or a command to run instead (used
# where the tool ships its own GC and deleting by hand would corrupt state).
#
# risk tiers:
#   safe   - regenerated automatically, no user data, no network cost beyond redownload
#   review - safe to lose but expensive to rebuild, or may hold something you want
#   risky  - can destroy real artifacts / require reinstall; never auto-selected
function Get-TargetTable {
  $U = $env:USERPROFILE.TrimEnd('\')
  $L = $env:LOCALAPPDATA.TrimEnd('\')
  $R = $env:APPDATA.TrimEnd('\')
  $table = @"
npm|node|safe|$L\npm-cache\_cacache|-|npm package cache
yarn|node|safe|$L\Yarn\Cache|-|Yarn v1 cache
yarn-berry|node|safe|$L\Yarn\Berry\cache|-|Yarn Berry global cache
pnpm|node|safe|$L\pnpm\store|-|pnpm content-addressable store
pnpm-alt|node|safe|$U\.pnpm-store|-|pnpm store (legacy location)
bun|node|safe|$U\.bun\install\cache|-|Bun install cache
node-gyp|node|safe|$L\node-gyp\Cache|-|node-gyp downloaded headers
electron|node|safe|$L\electron\Cache|-|Electron binary downloads
puppeteer|node|review|$U\.cache\puppeteer|-|Puppeteer Chromium builds (redownloads on next run)
playwright|node|review|$L\ms-playwright|-|Playwright browser builds (re-run 'playwright install')
pip|python|safe|$L\pip\Cache|-|pip wheel/http cache
uv|python|safe|$L\uv\cache|-|uv package cache
poetry|python|safe|$L\pypoetry\Cache|-|Poetry artifact cache
pyenv-build|python|safe|$U\.pyenv\pyenv-win\install_cache|-|pyenv-win installer downloads
huggingface|python|review|$U\.cache\huggingface|-|Hugging Face model/dataset cache (large redownloads)
torch|python|review|$U\.cache\torch|-|PyTorch downloaded weights
cargo-registry|rust|safe|$U\.cargo\registry|-|Cargo crate registry cache
cargo-git|rust|safe|$U\.cargo\git|-|Cargo git checkouts
sccache|rust|safe|$L\Mozilla\sccache\cache|-|sccache compiler cache
go-build|go|safe|$L\go-build|-|Go build cache
go-mod|go|review|$U\go\pkg\mod|go clean -modcache|Go module cache (redownloads on next build)
gradle|jvm|safe|$U\.gradle\caches|-|Gradle build/dependency cache
maven|jvm|review|$U\.m2\repository|-|Maven local repo (may hold locally-installed artifacts)
sbt|jvm|safe|$U\.sbt\boot|-|sbt boot cache
coursier|jvm|safe|$L\Coursier\Cache|-|Coursier/Scala dependency cache
nuget|dotnet|safe|$U\.nuget\packages|-|NuGet global packages
nuget-http|dotnet|safe|$L\NuGet\v3-cache|-|NuGet HTTP cache
composer|php|safe|$L\Composer|-|Composer cache
bundler|ruby|review|$U\.bundle\cache|-|Bundler gem cache
gem-spec|ruby|safe|$U\.gem\specs|-|RubyGems spec cache
android-cache|android|safe|$U\.android\cache|-|Android SDK cache
android-build-cache|android|safe|$U\.android\build-cache|-|Android build cache
avd|android|risky|$U\.android\avd|-|Android emulator images - deletes your virtual devices
scoop|system|safe|$U\scoop\cache|scoop cache rm *|Scoop installer downloads
deno|other|safe|$L\deno|-|Deno dependency cache
terraform|other|review|$R\terraform.d\plugin-cache|-|Terraform provider plugin cache
docker|other|risky|$L\Docker\wsl|docker system prune -a -f --volumes|Docker prune (SIZE SHOWN = whole Docker disk; prune removes unused images/volumes only, and the disk file only shrinks after Docker compacts it)
user-temp|system|review|$L\Temp|-|Your temp folder (files that are in use are left alone)
crash-dumps|system|review|$L\CrashDumps|-|Crash dumps
"@
  foreach ($line in ($table -split "`r?`n")) {
    if (-not $line) { continue }
    $f = $line.Split('|', 6)
    [pscustomobject]@{ Id = $f[0]; Category = $f[1]; Risk = $f[2]; Path = $f[3]; Cleaner = $f[4]; Description = $f[5] }
  }
}

# ------------------------------------------------------------ delete guardrail --

# A path must sit under one of these to be eligible for removal:
#   %LOCALAPPDATA%\...         where Windows tools keep their caches
#   %APPDATA%\...              the terraform plugin cache
#   %USERPROFILE%\.<folder>    dot-folders in your profile (~\.npm, ~\.cargo, ...)
#   %USERPROFILE%\go\pkg\...
function Test-DeleteAllowed([string]$Path) {
  if (-not $Path -or -not (Test-LocalPath $Path) -or $Path.Contains('..')) { return $false }
  $p = $Path.TrimEnd('\')
  $U = $env:USERPROFILE.TrimEnd('\')
  $L = $env:LOCALAPPDATA.TrimEnd('\')
  $R = $env:APPDATA.TrimEnd('\')
  # Reject anything that resolves to a boundary we must never remove.
  if ($p -match '^[A-Za-z]:$') { return $false }
  foreach ($never in @($U, $L, $R, "$U\AppData", $env:SystemRoot, "$env:SystemDrive\Users")) {
    if ($never -and $p -ieq $never.TrimEnd('\')) { return $false }
  }
  foreach ($prefix in @("$L\", "$R\", "$U\go\pkg\")) {
    if ($p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  if ($p.StartsWith("$U\", [StringComparison]::OrdinalIgnoreCase)) {
    return ($p.Substring($U.Length + 1) -match '^\.[^.\\]')
  }
  return $false
}

# Delete a tree without ever following a link: a junction or symlink inside it
# is removed as a link, and whatever it points to is left alone. (pnpm and
# `npm link` put junctions to folders elsewhere inside node_modules.) Read-only
# entries are made writable first; git and cargo leave files read-only.
# With -KeepRoot the folder itself survives, emptied.
# Returns how many entries could not be removed (files in use, and so on).
function Remove-Tree {
  [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'cachectl dry-runs by default; --apply is the opt-in, not -WhatIf.')]
  param([string]$Path, [switch]$KeepRoot)
  $failed = 0
  $root = New-Object IO.DirectoryInfo (Get-IOPath $Path)
  if (-not $root.Exists) { return 0 }
  if ($root.Attributes -band $ReparsePoint) { return 1 }

  # Walk the tree top-down, deleting files and links as we go and collecting
  # real folders, then remove the folders deepest-first.
  $dirs = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
  $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
  $stack.Push($root)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $dirs.Add($dir)
    try { $entries = $dir.GetFileSystemInfos() } catch { $failed++; continue }
    foreach ($e in $entries) {
      if (($e.Attributes -band $DirectoryAttr) -and -not ($e.Attributes -band $ReparsePoint)) {
        $stack.Push($e)
        continue
      }
      try {
        if ($e.Attributes -band $ReadOnlyAttr) { $e.Attributes = $e.Attributes -bxor $ReadOnlyAttr }
        $e.Delete()
      } catch { $failed++ }
    }
  }
  $last = 0
  if ($KeepRoot) { $last = 1 }
  for ($i = $dirs.Count - 1; $i -ge $last; $i--) {
    try {
      if ($dirs[$i].Attributes -band $ReadOnlyAttr) { $dirs[$i].Attributes = $dirs[$i].Attributes -bxor $ReadOnlyAttr }
      $dirs[$i].Delete()
    } catch { $failed++ }
  }
  return $failed
}

# Move a folder to the Recycle Bin. Windows deletes outright anything bigger
# than the Recycle Bin is allowed to hold, as Explorer does.
function Move-ToRecycleBin([string]$Path) {
  try {
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    return $true
  } catch { return $false }
}

# Run a tool's own cleanup command. Returns $true on success.
function Invoke-Cleaner([string]$Command) {
  $exe = ($Command -split ' ')[0]
  if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $false }
  $ErrorActionPreference = 'Continue'
  & cmd.exe /d /c "$Command >nul 2>&1"
  return ($LASTEXITCODE -eq 0)
}

# ------------------------------------------------------------------- argv --

function Get-FlagValue([string[]]$Argv, [int]$Index) {
  if ($Index + 1 -ge $Argv.Count) { Exit-WithError "$($Argv[$Index]) needs a value" }
  return $Argv[$Index + 1]
}
function ConvertTo-Count([string]$Text, [string]$Flag) {
  $n = 0
  if (-not [int]::TryParse($Text, [ref]$n)) { Exit-WithError "$Flag needs a whole number, got '$Text'" }
  return $n
}
function ConvertTo-Kb([string]$Mb) {
  $v = 0.0
  if (-not [double]::TryParse($Mb, [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) {
    Exit-WithError "--min-size needs a number of MB, got '$Mb'"
  }
  return [long][math]::Floor($v * 1024)
}
function Read-YesNo([string]$Prompt) {
  Write-Out $Prompt -NoNewline
  $answer = [Console]::In.ReadLine()
  return ($answer -cin @('y', 'Y', 'yes', 'YES'))
}

# ----------------------------------------------------------------------- scan --

# Measures every target that exists and matches the filters.
# Returns Rows (Target, Kb, Age), Safe and All totals in KB.
function Invoke-TargetScan([string]$Category, [string]$Ids, [long]$MinKb, [int]$StaleDays) {
  $rows = New-Object 'System.Collections.Generic.List[object]'
  $safe = [long]0; $all = [long]0
  $idList = @()
  if ($Ids) { $idList = @($Ids -split ',') }

  foreach ($t in $Targets) {
    if ($Category -and $t.Category -cne $Category) { continue }
    if ($idList.Count -and $idList -cnotcontains $t.Id) { continue }
    if (-not (Test-Path -LiteralPath $t.Path)) { continue }

    Show-Status "scanning $($t.Id)"
    $kb = Get-SizeKb $t.Path
    $age = Get-Age $t.Path

    if ($kb -lt $MinKb) { continue }
    if ($StaleDays -gt 0 -and $age -lt $StaleDays) { continue }

    $rows.Add([pscustomobject]@{ Target = $t; Kb = $kb; Age = $age })
    $all += $kb
    if ($t.Risk -eq 'safe') { $safe += $kb }
  }
  Clear-Status
  return [pscustomobject]@{ Rows = $rows.ToArray(); Safe = $safe; All = $all }
}

function Write-ScanTable([object[]]$Rows, [string]$SortBy) {
  Write-Out ('{0,-24} {1,12} {2,7} {3,-7} {4,-9} {5}' -f 'ID', 'SIZE', 'AGE', 'RISK', 'GROUP', 'WHAT IT IS') White
  Write-Out ('-' * 100) DarkGray
  $sorted = $Rows | Sort-Object -Property $SortBy -Descending
  foreach ($r in $sorted) {
    Write-Out ('{0,-24} {1,12} {2,6}d ' -f $r.Target.Id, (Format-Size $r.Kb), $r.Age) -NoNewline
    Write-Out ('{0,-7}' -f $r.Target.Risk) (Get-RiskColor $r.Target.Risk) -NoNewline
    Write-Out (' {0,-9} ' -f $r.Target.Category) -NoNewline
    Write-Out $r.Target.Description DarkGray
  }
}

function Invoke-ScanCommand([string[]]$Argv) {
  $category = ''; $ids = ''; $minKb = [long]0; $staleDays = 0; $sortBy = 'Kb'
  $i = 0
  while ($i -lt $Argv.Count) {
    $flag = $Argv[$i]
    switch -CaseSensitive ($flag) {
      '--category'   { $category = Get-FlagValue $Argv $i; $i += 2 }
      '--only'       { $ids = Get-FlagValue $Argv $i; $i += 2 }
      '--min-size'   { $minKb = ConvertTo-Kb (Get-FlagValue $Argv $i); $i += 2 }
      '--stale-days' { $staleDays = ConvertTo-Count (Get-FlagValue $Argv $i) $flag; $i += 2 }
      '--by-age'     { $sortBy = 'Age'; $i += 1 }
      default        { Exit-WithError "scan: unknown flag $flag" }
    }
  }

  Write-Out 'Scanning developer caches...' White
  $scan = Invoke-TargetScan $category $ids $minKb $staleDays

  if (-not $scan.Rows.Count) {
    Write-Out 'No matching caches found.'
    return
  }

  Write-Out ''
  Write-ScanTable $scan.Rows $sortBy
  Write-Out ''
  Write-Out 'Reclaimable now (risk=safe): ' White -NoNewline
  Write-Out (Format-Size $scan.Safe) Green
  Write-Out ('All listed caches:            ' + (Format-Size $scan.All)) White
  Write-Out ''
  Write-Out 'Next: cachectl clean            # dry run, safe targets only' DarkGray
  Write-Out '      cachectl clean --apply    # actually delete' DarkGray
}

# ---------------------------------------------------------------------- clean --

function Invoke-CleanCommand([string[]]$Argv) {
  $apply = $false; $useTrash = $false; $includeReview = $false; $includeRisky = $false; $assumeYes = $false
  $category = ''; $ids = ''; $minKb = [long]0; $staleDays = 0
  $i = 0
  while ($i -lt $Argv.Count) {
    $flag = $Argv[$i]
    switch -CaseSensitive ($flag) {
      '--apply'          { $apply = $true; $i += 1 }
      '--trash'          { $useTrash = $true; $i += 1 }
      '--include-review' { $includeReview = $true; $i += 1 }
      '--include-risky'  { $includeRisky = $true; $i += 1 }
      '--yes'            { $assumeYes = $true; $i += 1 }
      '-y'               { $assumeYes = $true; $i += 1 }
      '--category'       { $category = Get-FlagValue $Argv $i; $i += 2 }
      '--only'           { $ids = Get-FlagValue $Argv $i; $includeReview = $true; $includeRisky = $true; $i += 2 }
      '--min-size'       { $minKb = ConvertTo-Kb (Get-FlagValue $Argv $i); $i += 2 }
      '--stale-days'     { $staleDays = ConvertTo-Count (Get-FlagValue $Argv $i) $flag; $i += 2 }
      default            { Exit-WithError "clean: unknown flag $flag" }
    }
  }

  if ($includeRisky -and -not $assumeYes -and $apply) {
    Exit-WithError '--include-risky with --apply also requires --yes (risky targets can destroy build artifacts).'
  }

  Write-Out 'Scanning...' White
  $scan = Invoke-TargetScan $category $ids $minKb $staleDays
  if (-not $scan.Rows.Count) { Write-Out 'Nothing to clean.'; return }

  # Build the selected set.
  $selected = @($scan.Rows | Where-Object {
      $_.Target.Risk -eq 'safe' -or
      ($_.Target.Risk -eq 'review' -and $includeReview) -or
      ($_.Target.Risk -eq 'risky' -and $includeRisky)
    } | Sort-Object -Property Kb -Descending)
  if (-not $selected.Count) { Write-Out 'Nothing selected. Try --include-review.'; return }
  $total = [long]0
  foreach ($r in $selected) { $total += $r.Kb }

  Write-Out ''
  if (-not $apply) { Write-Out ' DRY RUN - nothing will be deleted ' Cyan }
  else { Write-Out ' APPLYING - these will be removed ' Red }
  Write-Out ''

  foreach ($r in $selected) {
    Write-Out '  ' -NoNewline
    Write-Out ('{0,-7}' -f $r.Target.Risk) (Get-RiskColor $r.Target.Risk) -NoNewline
    Write-Out (' {0,-24} {1,12}  ' -f $r.Target.Id, (Format-Size $r.Kb)) -NoNewline
    Write-Out $r.Target.Path DarkGray
  }

  Write-Out ''
  Write-Out 'Total to reclaim: ' White -NoNewline
  Write-Out (Format-Size $total) Green
  Write-Out ''

  if (-not $apply) {
    Write-Out 'Re-run with --apply to delete. Add --trash to move to the Recycle Bin instead (reversible, slower).' DarkGray
    return
  }

  if (-not $assumeYes) {
    if (-not (Read-YesNo 'Proceed? [y/N] ')) { Write-Out 'Aborted.'; exit 1 }
  }

  # Freed space is measured, not assumed: files in use survive on Windows.
  $freed = [long]0
  foreach ($r in $selected) {
    $t = $r.Target

    if ($t.Cleaner -ne '-') {
      Write-Out '  -> ' Cyan -NoNewline
      Write-Out "$($t.Id)  ($($t.Cleaner))"
      if (Invoke-Cleaner $t.Cleaner) {
        $gone = $r.Kb - (Get-SizeKb $t.Path)
        if ($gone -gt 0) { $freed += $gone }
      } else {
        Write-Warn "     cleaner failed for $($t.Id), left untouched"
      }
      continue
    }

    if (-not (Test-DeleteAllowed $t.Path)) {
      Write-Warn "  !! refusing to delete '$($t.Path)' (outside allowlist) - skipped"
      continue
    }
    if (-not (Test-Path -LiteralPath $t.Path)) { continue }
    if (Test-IsLink $t.Path) {
      Write-Warn "  !! '$($t.Path)' is a link to somewhere else - skipped"
      continue
    }

    Write-Out '  -> ' Cyan -NoNewline
    Write-Out "$($t.Id)  " -NoNewline
    Write-Out $t.Path DarkGray
    if ($useTrash) {
      if (Move-ToRecycleBin $t.Path) {
        [void](New-Item -ItemType Directory -Force -Path $t.Path)
      } else {
        Write-Warn '     could not move to the Recycle Bin - skipped'
        continue
      }
    } else {
      $failed = Remove-Tree $t.Path -KeepRoot
      if ($failed) { Write-Warn "     $failed item(s) in use or locked - left in place" }
    }
    $gone = $r.Kb - (Get-SizeKb $t.Path)
    if ($gone -gt 0) { $freed += $gone }
  }

  Write-Out ''
  Write-Out ('Freed: ' + (Format-Size $freed)) Green
}

# ------------------------------------------------------------------- projects --

# Find stale build/dependency folders inside project trees. These are the
# ones that quietly eat the most space and nobody ever looks at.

$BuildDirNames = @('node_modules', '.next', '.nuxt', 'dist', 'build', 'target', '.turbo', '.parcel-cache',
  '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache', '.gradle', 'DerivedData', '.terraform')

# Names match case-sensitively, as on macOS and Linux, so a hand-made "Build"
# folder is left alone. vendor\bundle matches as a pair.
function Test-BuildDirName([IO.DirectoryInfo]$Dir) {
  if ($BuildDirNames -ccontains $Dir.Name) { return $true }
  return ($Dir.Name -ceq 'bundle' -and $null -ne $Dir.Parent -and $Dir.Parent.Name -ceq 'vendor')
}

# Folders under $Root, at most $Depth levels down, whose name marks them as
# build output. Never descends into a match (no node_modules inside
# node_modules), into a link, or into AppData: that is where caches live, not
# projects, and it holds the global npm packages in AppData\Roaming\npm.
function Find-BuildDir([string]$Root, [int]$Depth) {
  $appData = $env:USERPROFILE.TrimEnd('\') + '\AppData'
  $stack = New-Object 'System.Collections.Generic.Stack[object]'
  $stack.Push(@((New-Object IO.DirectoryInfo (Get-IOPath $Root)), 0))
  while ($stack.Count -gt 0) {
    $item = $stack.Pop()
    $dir = $item[0]; $level = $item[1]
    try { $children = $dir.GetDirectories() } catch { continue }
    foreach ($c in $children) {
      if ($c.Attributes -band $ReparsePoint) { continue }
      if (Test-BuildDirName $c) { $c; continue }
      if ($level + 1 -ge $Depth) { continue }
      if ((Get-PlainPath $c.FullName) -ieq $appData) { continue }
      $stack.Push(@($c, ($level + 1)))
    }
  }
}

# Returns Rows (Kb, Age, Path), Total KB and Count.
function Invoke-ProjectScan([string]$Root, [int]$StaleDays, [long]$MinKb, [int]$Depth) {
  $rows = New-Object 'System.Collections.Generic.List[object]'
  $total = [long]0
  foreach ($d in @(Find-BuildDir $Root $Depth)) {
    $age = [int][math]::Floor(($NowUtc - $d.LastWriteTimeUtc).TotalDays)
    if ($age -lt $StaleDays) { continue }
    Show-Status ('measuring {0}\{1}' -f $d.Parent.Name, $d.Name)
    $path = Get-PlainPath $d.FullName
    $kb = Get-SizeKb $path
    if ($kb -lt $MinKb) { continue }
    $rows.Add([pscustomobject]@{ Kb = $kb; Age = $age; Path = $path })
    $total += $kb
  }
  Clear-Status
  return [pscustomobject]@{ Rows = $rows.ToArray(); Total = $total; Count = $rows.Count }
}

# Where `projects` may look: your profile, any folder on another drive, or a
# folder on the system drive outside Windows' own (Program Files and so on).
function Test-ProjectRoot([string]$Path) {
  $p = $Path.TrimEnd('\')
  $u = $env:USERPROFILE.TrimEnd('\')
  if ($p -ieq $u -or $p.StartsWith("$u\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
  if (-not ($p -match '^([A-Za-z]:)(\\(.+))?$')) { return $false }
  $drive = $Matches[1]
  $rest = $Matches[3]
  if ($drive -ine $env:SystemDrive) { return $true }
  if (-not $rest) { return $false }
  $top = ($rest -split '\\')[0]
  $system = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData', 'Users', 'Recovery',
    'PerfLogs', '$Recycle.Bin', 'System Volume Information')
  return ($system -notcontains $top)
}

function Resolve-Root([string]$Root) {
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
  if (-not [IO.Directory]::Exists($full)) { Exit-WithError "not a directory: $Root" }
  # Keep a drive root as D:\ -- a bare D: means "the current folder on D".
  if ($full -match '^[A-Za-z]:\\$') { return $full }
  return $full.TrimEnd('\')
}

function Invoke-ProjectsCommand([string[]]$Argv) {
  $root = $env:USERPROFILE; $staleDays = 30; $minKb = [long]51200; $depth = 6
  $apply = $false; $useTrash = $false; $assumeYes = $false
  $i = 0
  while ($i -lt $Argv.Count) {
    $flag = $Argv[$i]
    switch -CaseSensitive ($flag) {
      '--root'       { $root = Get-FlagValue $Argv $i; $i += 2 }
      '--stale-days' { $staleDays = ConvertTo-Count (Get-FlagValue $Argv $i) $flag; $i += 2 }
      '--min-size'   { $minKb = ConvertTo-Kb (Get-FlagValue $Argv $i); $i += 2 }
      '--depth'      { $depth = ConvertTo-Count (Get-FlagValue $Argv $i) $flag; $i += 2 }
      '--apply'      { $apply = $true; $i += 1 }
      '--trash'      { $useTrash = $true; $i += 1 }
      '--yes'        { $assumeYes = $true; $i += 1 }
      '-y'           { $assumeYes = $true; $i += 1 }
      default        { Exit-WithError "projects: unknown flag $flag" }
    }
  }

  $root = Resolve-Root $root
  if (-not (Test-ProjectRoot $root)) {
    Exit-WithError 'refusing to scan the system drive outside your profile, or Windows, Program Files, ProgramData'
  }

  Write-Out "Looking for build dirs under $root " White -NoNewline
  Write-Out "(untouched >${staleDays}d, >$(Format-Size $minKb), depth<=$depth)" DarkGray

  $scan = Invoke-ProjectScan $root $staleDays $minKb $depth
  if (-not $scan.Count) { Write-Out 'Nothing stale enough to report.'; return }
  $rows = @($scan.Rows | Sort-Object -Property Kb -Descending)

  Write-Out ''
  Write-Out ('{0,12} {1,7}  {2}' -f 'SIZE', 'AGE', 'PATH') White
  Write-Out ('-' * 90) DarkGray
  foreach ($r in $rows) { Write-Out ('{0,12} {1,6}d  {2}' -f (Format-Size $r.Kb), $r.Age, $r.Path) }
  Write-Out ''
  Write-Out ('{0} dirs, {1} reclaimable' -f $scan.Count, (Format-Size $scan.Total)) White
  Write-Out ''

  if (-not $apply) {
    Write-Out 'Dry run. Re-run with --apply to delete these.' DarkGray
    Write-Out 'Note: reinstalling deps (npm i, cargo build, ...) recreates them.' DarkGray
    return
  }

  if (-not $assumeYes) {
    if (-not (Read-YesNo "Delete all $($scan.Count) directories above? [y/N] ")) { Write-Out 'Aborted.'; exit 1 }
  }

  $freed = [long]0
  foreach ($r in $rows) {
    $dir = New-Object IO.DirectoryInfo (Get-IOPath $r.Path)
    if (-not (Test-BuildDirName $dir) -or ($dir.Attributes -band $ReparsePoint)) {
      Write-Warn "  !! skipping $($r.Path)"
      continue
    }
    Write-Out '  -> ' Cyan -NoNewline
    Write-Out $r.Path
    if ($useTrash) {
      if (-not (Move-ToRecycleBin $r.Path)) { Write-Warn '     Recycle Bin move failed' }
    } else {
      $failed = Remove-Tree $r.Path
      if ($failed) { Write-Warn "     $failed item(s) in use or locked - left in place" }
    }
    $gone = $r.Kb - (Get-SizeKb $r.Path)
    if ($gone -gt 0) { $freed += $gone }
  }

  Write-Out ''
  Write-Out ('Freed: ' + (Format-Size $freed)) Green
}

# --------------------------------------------------------------------- report --

# Measure every entry directly inside $Dir. Returns Kb, Age, Path rows.
function Get-ChildSize([string]$Dir) {
  try { $entries = (New-Object IO.DirectoryInfo (Get-IOPath $Dir)).GetFileSystemInfos() } catch { return }
  foreach ($e in $entries) {
    $path = Get-PlainPath $e.FullName
    Show-Status "measuring $($e.Name)"
    [pscustomobject]@{ Kb = (Get-SizeKb $path); Age = (Get-Age $path); Path = $path; Name = $e.Name }
  }
  Clear-Status
}

# True when a known target is this path or sits inside it.
function Test-CoversTarget([string]$Path) {
  foreach ($t in $Targets) {
    if ($t.Path -ieq $Path -or $t.Path.StartsWith("$Path\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

# Pad a label with dots so the summary column lines up.
function Format-Label([string]$Text) {
  $s = $Text
  while ($s.Length -lt 35) { $s += '.' }
  return $s
}

# The whole picture in one pass: tool caches, stale project dirs, and unknown
# cache entries - with a single grand total and an ordered list of what to do.
function Invoke-ReportCommand([string[]]$Argv) {
  $root = $env:USERPROFILE; $staleDays = 30; $minKb = [long]51200; $depth = 6; $skipProjects = $false
  $i = 0
  while ($i -lt $Argv.Count) {
    $flag = $Argv[$i]
    switch -CaseSensitive ($flag) {
      '--root'        { $root = Get-FlagValue $Argv $i; $i += 2 }
      '--stale-days'  { $staleDays = ConvertTo-Count (Get-FlagValue $Argv $i) $flag; $i += 2 }
      '--min-size'    { $minKb = ConvertTo-Kb (Get-FlagValue $Argv $i); $i += 2 }
      '--depth'       { $depth = ConvertTo-Count (Get-FlagValue $Argv $i) $flag; $i += 2 }
      '--no-projects' { $skipProjects = $true; $i += 1 }
      default         { Exit-WithError "report: unknown flag $flag" }
    }
  }

  $drive = [IO.Path]::GetPathRoot($env:USERPROFILE)
  $freeKb = [long]0
  try { $freeKb = [long]((New-Object IO.DriveInfo $drive).AvailableFreeSpace / 1024) } catch { $freeKb = 0 }

  Write-Out ''
  Write-Out '  cachectl disk report' White
  Write-Out "  free space on $($drive.TrimEnd('\')): $(Format-Size $freeKb)" DarkGray
  Write-Out ''

  # --- 1. tool caches -------------------------------------------------------
  Write-Out '[1/3] Tool caches' White
  $scan = Invoke-TargetScan '' '' 0 0
  if ($scan.Rows.Count) {
    Write-Out ''
    Write-ScanTable $scan.Rows 'Kb'
  } else {
    Write-Out '  none found'
  }

  # --- 2. stale project dirs -----------------------------------------------
  $projTotal = [long]0; $projCount = 0
  Write-Out ''
  if (-not $skipProjects) {
    $root = Resolve-Root $root
    if (-not (Test-ProjectRoot $root)) {
      Exit-WithError 'refusing to scan the system drive outside your profile, or Windows, Program Files, ProgramData'
    }
    Write-Out '[2/3] Stale build directories ' White -NoNewline
    Write-Out "under $root, untouched >${staleDays}d" DarkGray
    $proj = Invoke-ProjectScan $root $staleDays $minKb $depth
    $projTotal = $proj.Total; $projCount = $proj.Count

    if ($projCount) {
      Write-Out ''
      Write-Out ('{0,12} {1,7}  {2}' -f 'SIZE', 'AGE', 'PATH') White
      foreach ($r in @($proj.Rows | Sort-Object -Property Kb -Descending | Select-Object -First 15)) {
        Write-Out ('{0,12} {1,6}d  {2}' -f (Format-Size $r.Kb), $r.Age, (Format-Home $r.Path))
      }
      if ($projCount -gt 15) { Write-Out ('{0,12}  ... and {1} more' -f '', ($projCount - 15)) DarkGray }
    } else {
      Write-Out '  none found'
    }
  } else {
    Write-Out '[2/3] Stale build directories ' White -NoNewline
    Write-Out 'skipped' DarkGray
  }

  # --- 3. unknown cache entries --------------------------------------------
  $cacheLabel = Format-Home $env:LOCALAPPDATA.TrimEnd('\')
  Write-Out ''
  Write-Out "[3/3] Unrecognised entries in $cacheLabel " White -NoNewline
  Write-Out '(judge these yourself)' DarkGray
  Write-Out ''
  $children = @(Get-ChildSize $env:LOCALAPPDATA.TrimEnd('\'))
  $unknownTotal = [long]0
  foreach ($c in $children) { $unknownTotal += $c.Kb }
  $children | Sort-Object -Property Kb -Descending |
    Where-Object { $_.Kb -ge 10240 -and -not (Test-CoversTarget $_.Path) } |
    Select-Object -First 12 |
    ForEach-Object { Write-Out ('{0,12} {1,6}d  {2}' -f (Format-Size $_.Kb), $_.Age, $_.Name) }

  # --- verdict --------------------------------------------------------------
  $grand = $scan.Safe + $projTotal
  Write-Out ''
  Write-Out ('=' * 72) DarkGray
  Write-Out '  SUMMARY' White
  Write-Out '    Tool caches, safe to clear now .... ' -NoNewline
  Write-Out ('{0,14}' -f (Format-Size $scan.Safe)) Green
  Write-Out ('    Tool caches, all tiers ........... {0,14}' -f (Format-Size $scan.All))
  Write-Out ('    Stale build dirs ({0}) ............. ' -f $projCount) -NoNewline
  Write-Out ('{0,14}' -f (Format-Size $projTotal)) Green
  Write-Out ('    {0} {1,14}' -f (Format-Label "$cacheLabel, total on disk "), (Format-Size $unknownTotal))
  Write-Out ('-' * 72) DarkGray
  Write-Out '    RECLAIMABLE WITHOUT THINKING ..... ' White -NoNewline
  Write-Out ('{0,14}' -f (Format-Size $grand)) Green
  Write-Out ('=' * 72) DarkGray
  Write-Out ''

  Write-Out '  What to run, in order:' White
  Write-Out ''
  $step = 1
  if ($scan.Safe -gt 0) {
    Write-Out "    $step. " -NoNewline
    Write-Out 'cachectl clean --apply' Cyan
    Write-Out "       Frees $(Format-Size $scan.Safe). Everything here regenerates on its own." DarkGray
    Write-Out ''
    $step++
  }
  if ($projTotal -gt 0) {
    Write-Out "    $step. " -NoNewline
    Write-Out "cachectl projects --stale-days $staleDays --apply" Cyan
    Write-Out "       Frees $(Format-Size $projTotal) across $projCount dirs. Reinstall deps to get them back." DarkGray
    Write-Out ''
    $step++
  }
  Write-Out "    $step. " -NoNewline
  Write-Out 'cachectl scan --stale-days 90' Cyan
  Write-Out '       Review what you have not touched in three months.' DarkGray
  Write-Out ''
  Write-Out '  Nothing above has been deleted. Every command dry-runs by default.' DarkGray
  Write-Out ''
}

# ----------------------------------------------------------------------- top --

# Show the biggest things in %LOCALAPPDATA%, including ones cachectl does NOT
# know about, so you can decide for yourself. Read-only.
function Invoke-TopCommand([string[]]$Argv) {
  $n = 25; $dir = $env:LOCALAPPDATA.TrimEnd('\')
  $i = 0
  while ($i -lt $Argv.Count) {
    $flag = $Argv[$i]
    switch -CaseSensitive ($flag) {
      '-n'    { $n = ConvertTo-Count (Get-FlagValue $Argv $i) $flag; $i += 2 }
      '--dir' { $dir = Resolve-Root (Get-FlagValue $Argv $i); $i += 2 }
      default { Exit-WithError "top: unknown flag $flag" }
    }
  }
  if (-not [IO.Directory]::Exists($dir)) { Exit-WithError "not a directory: $dir" }

  Write-Out "Largest entries in $dir " White -NoNewline
  Write-Out '(read-only; nothing is deleted)' DarkGray
  Write-Out ''
  Get-ChildSize $dir | Sort-Object -Property Kb -Descending | Select-Object -First $n |
    ForEach-Object { Write-Out ('{0,12}  {1,6}d  {2}' -f (Format-Size $_.Kb), $_.Age, $_.Name) }
  Write-Out ''
  Write-Out 'Anything here that belongs to an app you deleted is dead weight.' DarkGray
  Write-Out 'Caches for apps you still use will simply be rebuilt.' DarkGray
}

# ---------------------------------------------------------------------- usage --

function Show-Usage {
  Write-Out "cachectl v$Version - see and reclaim developer cache space on Windows" White
  Write-Out @'

USAGE
  cachectl report [flags]       Start here. Full picture + what to run, in order
  cachectl scan [flags]         Measure known caches and show what's reclaimable
  cachectl clean [flags]        Remove caches (dry run unless --apply)
  cachectl projects [flags]     Find stale node_modules/target/build dirs in your projects
  cachectl top [flags]          List biggest entries in ~\AppData\Local (read-only)
  cachectl list                 Print every known target and its risk tier
  cachectl help

REPORT
  --root <dir>           Where to look for project dirs (default: your profile)
  --stale-days <n>       Staleness threshold for build dirs (default: 30)
  --min-size <MB>        Minimum build dir size to report (default: 50)
  --no-projects          Skip the project scan (much faster)

SCAN
  --category <group>     node|python|rust|go|jvm|dotnet|php|ruby|android|system|other
  --only <id,id>         Restrict to specific target ids
  --min-size <MB>        Hide anything smaller
  --stale-days <n>       Only show caches untouched for n+ days
  --by-age               Sort by age instead of size

CLEAN
  --apply                Actually delete. Without it, nothing is touched.
  --trash                Move to the Recycle Bin instead (reversible, much slower)
  --include-review       Also clean 'review' tier (expensive to rebuild but safe)
  --include-risky        Also clean 'risky' tier - requires --yes with --apply
  --only <id,id>         Clean exactly these ids (implies both tiers above)
  --yes, -y              Skip the confirmation prompt
  plus every scan filter flag

PROJECTS
  --root <dir>           Where to search (default: your profile)
  --stale-days <n>       Untouched for n+ days (default: 30)
  --min-size <MB>        Minimum size to report (default: 50)
  --depth <n>            How many folders deep to look (default: 6)
  --apply / --trash / --yes

RISK TIERS
  safe    Regenerated automatically. Cleaning costs you nothing but a rebuild.
  review  Safe to lose, but expensive to rebuild (model weights, browser binaries).
  risky   Can destroy real artifacts (Android emulators, Docker volumes).
          Never selected automatically.

TYPICAL SESSION
  cachectl scan                            # what do I have?
  cachectl clean                           # what would go away?
  cachectl clean --apply                   # do it
  cachectl projects --stale-days 60        # what's rotting in my repos?
  cachectl projects --stale-days 60 --apply

'@
}

function Show-List {
  Write-Out ('{0,-24} {1,-9} {2,-7} {3}' -f 'ID', 'GROUP', 'RISK', 'PATH') White
  foreach ($t in $Targets) {
    $mark = ' '
    if (Test-Path -LiteralPath $t.Path) { $mark = '*' }
    Write-Out ('{0} {1,-23} {2,-9} ' -f $mark, $t.Id, $t.Category) -NoNewline
    Write-Out ('{0,-7}' -f $t.Risk) (Get-RiskColor $t.Risk) -NoNewline
    Write-Out (' ' + (Format-Home $t.Path))
  }
  Write-Out ''
  Write-Out '* = present on this machine' DarkGray
}

# ----------------------------------------------------------------------- main --

foreach ($name in 'USERPROFILE', 'LOCALAPPDATA', 'APPDATA') {
  if (-not [Environment]::GetEnvironmentVariable($name)) {
    Exit-WithError "%$name% is not set, so cachectl cannot tell where your caches live."
  }
}
$Targets = @(Get-TargetTable)

# From a PowerShell prompt, `--only npm,gradle` arrives as an array and numbers
# as numbers; from cmd everything is a string. Normalise to strings.
$cliArgs = @($args | ForEach-Object { if ($_ -is [array]) { $_ -join ',' } else { [string]$_ } })
$command = 'help'
if ($cliArgs.Count) { $command = $cliArgs[0] }
$rest = @($cliArgs | Select-Object -Skip 1)

switch -CaseSensitive ($command) {
  'report'   { Invoke-ReportCommand $rest }
  'scan'     { Invoke-ScanCommand $rest }
  'clean'    { Invoke-CleanCommand $rest }
  'projects' { Invoke-ProjectsCommand $rest }
  'top'      { Invoke-TopCommand $rest }
  'list'     { Show-List }
  { $_ -in 'version', '--version', '-V' } { Write-Out "cachectl $Version" }
  { $_ -in 'help', '--help', '-h' } { Show-Usage }
  default {
    $host.UI.WriteErrorLine("unknown command: $command")
    Write-Out ''
    Show-Usage
    exit 1
  }
}
exit 0
