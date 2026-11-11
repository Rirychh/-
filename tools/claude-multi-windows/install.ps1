# Claude 多帳號工具：一鍵安裝
# 在 PowerShell 貼上這一行即可：
#   irm https://raw.githubusercontent.com/Rirychh/-/main/tools/claude-multi-windows/install.ps1 | iex

$ErrorActionPreference = 'Stop'
$Branch  = if ($env:CLAUDEMULTI_BRANCH) { $env:CLAUDEMULTI_BRANCH } else { 'main' }
$BaseUrl = "https://raw.githubusercontent.com/Rirychh/-/$Branch/tools/claude-multi-windows"
$Root    = Join-Path $env:LOCALAPPDATA 'ClaudeMulti'
$Target  = Join-Path $Root 'ClaudeMulti.ps1'

Write-Host ''
Write-Host '安裝 Claude 多帳號工具...' -ForegroundColor Cyan

# 舊版 Windows PowerShell 預設可能不用 TLS 1.2，連不上 GitHub
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root | Out-Null }

# 1. 下載主程式（用 -OutFile 原樣存檔，保留 UTF-8 BOM，中文才不會亂碼）
$tmp = "$Target.download"
Invoke-WebRequest -Uri "$BaseUrl/ClaudeMulti.ps1" -OutFile $tmp -UseBasicParsing
if ((Get-Item $tmp).Length -lt 1000) { Remove-Item $tmp -Force; throw '下載的檔案不完整，請稍後再試。' }
Move-Item -Path $tmp -Destination $Target -Force
try { Unblock-File -Path $Target } catch { }
Write-Host '  [1/3] 已下載主程式' -ForegroundColor Green

# 2. 建立「Claude 多帳號工具」捷徑（桌面 + 開始功能表）
$ps   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnkArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$Target`""
$icon = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
$ws   = New-Object -ComObject WScript.Shell
$places = @(
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('Programs')
)
foreach ($dir in $places) {
    $lnk = $ws.CreateShortcut((Join-Path $dir 'Claude 多帳號工具.lnk'))
    $lnk.TargetPath  = $ps
    $lnk.Arguments   = $lnkArgs
    $lnk.WorkingDirectory = $Root
    $lnk.Description = '新增、開啟、管理多個 Claude 帳號'
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Save()
}
Write-Host '  [2/3] 已在桌面和開始功能表建立「Claude 多帳號工具」' -ForegroundColor Green

# 3. 打開選單
Write-Host '  [3/3] 安裝完成，正在打開選單...' -ForegroundColor Green
Write-Host ''
& $ps -NoProfile -ExecutionPolicy Bypass -File $Target
