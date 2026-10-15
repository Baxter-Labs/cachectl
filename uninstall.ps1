#
# Removes what install.ps1 put in place: %LOCALAPPDATA%\cachectl and its
# entry in your user PATH.
#
# The body runs in its own scope so that, under `irm | iex`, none of its
# variables or its error preference leak into your session.
& {
  $ErrorActionPreference = 'Stop'

  $InstallDir = Join-Path $env:LOCALAPPDATA 'cachectl'
  $BinDir = Join-Path $InstallDir 'bin'
  $removed = $false

  if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "Removed $InstallDir"
    $removed = $true
  }

  # Same raw registry handling as install.ps1, so the rest of PATH is untouched.
  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
  try {
    $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($raw -split ';' | Where-Object { $_ })
    if ($entries -contains $BinDir) {
      $kind = $key.GetValueKind('Path')
      $key.SetValue('Path', @($entries | Where-Object { $_ -ne $BinDir }) -join ';', $kind)
      [Environment]::SetEnvironmentVariable('CACHECTL_UNINSTALLING', '1', 'User')
      [Environment]::SetEnvironmentVariable('CACHECTL_UNINSTALLING', $null, 'User')
      Write-Host "Removed $BinDir from your user PATH"
      $removed = $true
    }
  } finally {
    $key.Close()
  }

  if (-not $removed) { Write-Host 'cachectl was not installed.' }
  Write-Host 'cachectl keeps no config or state, so nothing else to clean up.'
}
