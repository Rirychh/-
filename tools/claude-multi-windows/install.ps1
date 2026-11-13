# Claude multi-account tool: one-line installer.
#
# Paste this into PowerShell:
#   irm https://raw.githubusercontent.com/Rirychh/-/main/tools/claude-multi-windows/install.ps1 | iex
#
# Set $env:CLAUDEMULTI_BRANCH first to install from a non-main branch.
#
# IMPORTANT: keep this file pure ASCII. Windows PowerShell 5.1 decodes a
# BOM-less UTF-8 script using the system ANSI codepage, which corrupts any
# non-ASCII literal and breaks parsing when the script is run as a file
# (the `irm | iex` path is unaffected, which is why this hid for a while).
# Non-ASCII text that must survive is written as [char] escapes below.

$ErrorActionPreference = 'Stop'
$Branch  = if ($env:CLAUDEMULTI_BRANCH) { $env:CLAUDEMULTI_BRANCH } else { 'main' }
$BaseUrl = "https://raw.githubusercontent.com/Rirychh/-/$Branch/tools/claude-multi-windows"
$Root    = Join-Path $env:LOCALAPPDATA 'ClaudeMulti'
$Target  = Join-Path $Root 'ClaudeMulti.ps1'

# Must stay byte-identical to the name ClaudeMulti.ps1's uninstaller removes:
# "Claude <U+591A><U+5E33><U+865F><U+5DE5><U+5177>.lnk"
$LnkName = 'Claude ' + (-join (0x591A, 0x5E33, 0x865F, 0x5DE5, 0x5177 | ForEach-Object { [char]$_ })) + '.lnk'

Write-Host ''
Write-Host 'Installing Claude multi-account tool...' -ForegroundColor Cyan

# Older Windows PowerShell may not negotiate TLS 1.2 by default, which GitHub requires.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root | Out-Null }

# 1. Download the main script with -OutFile so the bytes land verbatim and its
#    UTF-8 BOM survives (ClaudeMulti.ps1 does contain Chinese UI text).
$tmp = "$Target.download"
Invoke-WebRequest -Uri "$BaseUrl/ClaudeMulti.ps1" -OutFile $tmp -UseBasicParsing
if ((Get-Item $tmp).Length -lt 1000) { Remove-Item $tmp -Force; throw 'Download looks incomplete. Please try again.' }
Move-Item -Path $tmp -Destination $Target -Force
try { Unblock-File -Path $Target } catch { }
Write-Host '  [1/3] Main script downloaded' -ForegroundColor Green

# 2. Create the launcher shortcut on the Desktop and in the Start Menu.
$ps   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnkArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$Target`""
$icon = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
$ws   = New-Object -ComObject WScript.Shell
$places = @(
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('Programs')
)
foreach ($dir in $places) {
    if (-not $dir -or -not (Test-Path $dir)) { continue }
    $lnk = $ws.CreateShortcut((Join-Path $dir $LnkName))
    $lnk.TargetPath  = $ps
    $lnk.Arguments   = $lnkArgs
    $lnk.WorkingDirectory = $Root
    $lnk.Description = 'Add, open and manage multiple Claude accounts'
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Save()
}
Write-Host '  [2/3] Shortcut created on Desktop and Start Menu' -ForegroundColor Green

# 3. Open the menu.
Write-Host '  [3/3] Done, opening the menu...' -ForegroundColor Green
Write-Host ''
& $ps -NoProfile -ExecutionPolicy Bypass -File $Target
