#
# cachectl installer for Windows. (macOS and Linux: install.sh)
#
# Works two ways:
#   1. Cloned repo:  powershell -ExecutionPolicy Bypass -File .\install.ps1
#   2. One-liner:    irm https://raw.githubusercontent.com/eshwarpk/cachectl/main/install.ps1 | iex
#
# Puts cachectl.ps1 in %LOCALAPPDATA%\cachectl, a cachectl.cmd launcher in
# %LOCALAPPDATA%\cachectl\bin, and adds that bin folder to your user PATH.
# No admin rights needed. uninstall.ps1 undoes all of it.
#
# Under `irm | iex` this runs inside your own PowerShell session. So errors
# throw rather than exit (exit would close the session), and the body runs in
# its own scope so none of its variables or its error preference leak into it.
#
& {
  $ErrorActionPreference = 'Stop'
  $RepoRaw = 'https://raw.githubusercontent.com/eshwarpk/cachectl/main'

  if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    throw 'install.ps1 is for Windows. On macOS and Linux, run install.sh.'
  }

  $InstallDir = Join-Path $env:LOCALAPPDATA 'cachectl'
  $BinDir = Join-Path $InstallDir 'bin'
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

  # Locate the script: next to this installer if cloned, otherwise download it.
  # Require both files present, so a stray cachectl.ps1 can't hijack the iex path.
  $here = $PSScriptRoot
  if ($here -and (Test-Path -LiteralPath (Join-Path $here 'cachectl.ps1')) -and
      (Test-Path -LiteralPath (Join-Path $here 'install.ps1'))) {
    Write-Host "Using local cachectl.ps1 from $here"
    Copy-Item -LiteralPath (Join-Path $here 'cachectl.ps1') -Destination $InstallDir -Force
  } else {
    Write-Host 'Downloading cachectl...'
    # Windows PowerShell 5.1 on older builds still defaults to TLS 1.0.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri "$RepoRaw/cachectl.ps1" -OutFile (Join-Path $InstallDir 'cachectl.ps1')
  }

  # A .cmd launcher, so `cachectl` works from cmd and PowerShell alike whatever
  # the execution policy. It sits alone in bin\: if cachectl.ps1 were on PATH,
  # PowerShell would run it directly and trip over the policy.
  $launcher = "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\cachectl.ps1`" %*`r`n"
  [IO.File]::WriteAllText((Join-Path $BinDir 'cachectl.cmd'), $launcher, [Text.Encoding]::ASCII)
  Write-Host "Installed: $(Join-Path $BinDir 'cachectl.cmd')"

  # Add bin\ to the user PATH. Read and write the raw registry value, so entries
  # like %USERPROFILE%\... stay unexpanded and the value keeps its type.
  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  try {
    $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($raw -split ';' | Where-Object { $_ })
    if ($entries -notcontains $BinDir) {
      $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
      if ($raw) { $kind = $key.GetValueKind('Path') }
      $key.SetValue('Path', (@($entries) + $BinDir) -join ';', $kind)
      # Tell Explorer, and so every new terminal, that the environment changed:
      # setting a user variable through .NET broadcasts WM_SETTINGCHANGE.
      [Environment]::SetEnvironmentVariable('CACHECTL_INSTALLING', '1', 'User')
      [Environment]::SetEnvironmentVariable('CACHECTL_INSTALLING', $null, 'User')
      Write-Host "Added $BinDir to your user PATH."
    }
  } finally {
    $key.Close()
  }
  if (($env:Path -split ';') -notcontains $BinDir) { $env:Path = "$env:Path;$BinDir" }

  Write-Host ''
  Write-Host 'Done. Open a new terminal, then start with:'
  Write-Host '  cachectl report'
  Write-Host ''
  Write-Host 'Nothing is ever deleted without an explicit --apply flag.'
}
