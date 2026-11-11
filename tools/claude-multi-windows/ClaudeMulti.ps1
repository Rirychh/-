# ClaudeMulti.ps1 — Windows 上同時使用多個 Claude 帳號
#
# 兩種模式：
#   desktop：用官方 Claude 桌面版，每個帳號一個獨立資料夾（--user-data-dir）
#   web    ：用 Edge / Chrome 開 claude.ai 的獨立 app 視窗，每個帳號一個獨立瀏覽器設定檔
#
# 用法：
#   直接執行（互動選單）           ClaudeMulti.ps1
#   開啟某個帳號                   ClaudeMulti.ps1 -Launch work
#   幫桌面版第二個帳號登入         ClaudeMulti.ps1 -Login work
#
# 檔案必須以 UTF-8 with BOM 儲存，Windows PowerShell 5.1 才能正確顯示中文。

[CmdletBinding()]
param(
    [string]$Launch,
    [string]$Login
)

$ErrorActionPreference = 'Stop'

$Root        = Join-Path $env:LOCALAPPDATA 'ClaudeMulti'
$ProfilesDir = Join-Path $Root 'profiles'
$InstalledPs = Join-Path $Root 'ClaudeMulti.ps1'
$BackupFile  = Join-Path $Root 'protocol-backup.txt'
$Protocol    = 'claude'
$ProtocolKey = "HKCU:\Software\Classes\$Protocol\shell\open\command"
$ClaudeWeb   = 'https://claude.ai'

# ---------- 共用小工具 ----------

function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host $msg -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host $msg -ForegroundColor Red }

function Initialize-Root {
    foreach ($d in @($Root, $ProfilesDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    }
    # 把自己複製到固定位置，桌面捷徑才不會因為你移動下載資料夾而失效
    if ($PSCommandPath -and ($PSCommandPath -ne $InstalledPs)) {
        Copy-Item -Path $PSCommandPath -Destination $InstalledPs -Force
    }
}

function Test-ProfileName($name) {
    return ($name -match '^[A-Za-z0-9_-]{1,32}$')
}

function Get-ProfileDir($name)  { Join-Path $ProfilesDir $name }
function Get-ProfileData($name) { Join-Path (Get-ProfileDir $name) 'data' }
function Get-ProfileMeta($name) { Join-Path (Get-ProfileDir $name) 'profile.json' }

function Get-Profiles {
    if (-not (Test-Path $ProfilesDir)) { return @() }
    $list = @()
    foreach ($d in Get-ChildItem -Path $ProfilesDir -Directory) {
        $meta = Join-Path $d.FullName 'profile.json'
        if (Test-Path $meta) {
            $obj = Get-Content -Raw -Path $meta -Encoding UTF8 | ConvertFrom-Json
            $list += [pscustomobject]@{ Name = $d.Name; Mode = $obj.Mode; Note = $obj.Note }
        }
    }
    return $list
}

function Get-Profile($name) {
    $meta = Get-ProfileMeta $name
    if (-not (Test-Path $meta)) { return $null }
    $obj = Get-Content -Raw -Path $meta -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{ Name = $name; Mode = $obj.Mode; Note = $obj.Note }
}

# ---------- 找程式 ----------

function Find-ClaudeExe {
    # 官方安裝程式（Squirrel）會裝在 %LOCALAPPDATA%\AnthropicClaude\app-<版本>\claude.exe
    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
    if (Test-Path $squirrel) {
        $apps = Get-ChildItem -Path $squirrel -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'claude.exe') } |
            Sort-Object -Descending -Property @{ Expression = {
                $v = $_.Name.Substring(4)
                try { [version]$v } catch { [version]'0.0' }
            } }
        if ($apps) { return (Join-Path $apps[0].FullName 'claude.exe') }
        $stub = Join-Path $squirrel 'claude.exe'
        if (Test-Path $stub) { return $stub }
    }
    $others = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe'),
        (Join-Path $env:ProgramFiles 'Claude\Claude.exe')
    )
    foreach ($p in $others) { if (Test-Path $p) { return $p } }
    return $null
}

function Find-ClaudeIcon {
    $stub = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
    if (Test-Path $stub) { return $stub }
    return (Find-ClaudeExe)
}

function Test-ClaudeStoreApp {
    try {
        $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue
        return [bool]$pkg
    } catch { return $false }
}

function Find-Browser {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
    foreach ($p in $candidates) { if ($p -and (Test-Path $p)) { return $p } }
    foreach ($name in @('msedge.exe', 'chrome.exe')) {
        $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$name"
        if (Test-Path $key) {
            $p = (Get-ItemProperty -Path $key).'(default)'
            if ($p -and (Test-Path $p)) { return $p }
        }
    }
    return $null
}

# ---------- 開啟 ----------

function Start-ClaudeProfile($name, [switch]$Verify) {
    $p = Get-Profile $name
    if (-not $p) { throw "找不到帳號設定檔「$name」。" }
    $data = Get-ProfileData $name
    if (-not (Test-Path $data)) { New-Item -ItemType Directory -Path $data | Out-Null }

    if ($p.Mode -eq 'web') {
        $browser = Find-Browser
        if (-not $browser) { throw '找不到 Edge 或 Chrome。' }
        Start-Process -FilePath $browser -ArgumentList @(
            "--user-data-dir=`"$data`"",
            "--app=$ClaudeWeb",
            '--no-first-run',
            '--no-default-browser-check'
        )
        return
    }

    $exe = Find-ClaudeExe
    if (-not $exe) {
        if (Test-ClaudeStoreApp) {
            throw '你的 Claude 是 Microsoft Store 版，不能用這個方式開第二個帳號。請改用 web 模式。'
        }
        throw '找不到 Claude 桌面版，請先從 claude.ai/download 安裝。'
    }

    $wasEmpty = -not (Get-ChildItem -Path $data -Force -ErrorAction SilentlyContinue)
    Start-Process -FilePath $exe -ArgumentList @("--user-data-dir=`"$data`"")

    if ($Verify -and $wasEmpty) {
        Write-Info '檢查 Claude 有沒有使用獨立資料夾（約 10 秒）...'
        Start-Sleep -Seconds 10
        if (Get-ChildItem -Path $data -Force -ErrorAction SilentlyContinue) {
            Write-Ok '確認成功：這個帳號的資料存在獨立資料夾，不會影響其他帳號。'
        } else {
            Write-Warn2 '警告：資料夾還是空的，這個版本的 Claude 可能不支援獨立資料夾。'
            Write-Warn2 '開出來的可能是你原本的帳號。建議把這個帳號刪掉，改用 web 模式重建。'
        }
    }
}

# ---------- 登入協助（桌面版） ----------
# 桌面版登入時，瀏覽器會用 claude:// 連結把登入結果送回 app。
# 這個連結預設只會送到「原本的」Claude，所以第二個帳號會登入失敗或登到第一個。
# 這裡暫時把 claude:// 改成指向這個帳號，登入完再改回來。

function Restore-Protocol {
    if (-not (Test-Path $BackupFile)) { return }
    $orig = Get-Content -Raw -Path $BackupFile -Encoding UTF8
    if ($orig -eq '<none>') {
        Remove-Item -Path "HKCU:\Software\Classes\$Protocol" -Recurse -Force -ErrorAction SilentlyContinue
    } elseif (Test-Path $ProtocolKey) {
        Set-ItemProperty -Path $ProtocolKey -Name '(default)' -Value $orig.TrimEnd("`r", "`n")
    }
    Remove-Item -Path $BackupFile -Force
    Write-Ok '已把 claude:// 連結還原成原本的設定。'
}

function Invoke-LoginHelper($name) {
    $p = Get-Profile $name
    if (-not $p) { throw "找不到帳號設定檔「$name」。" }
    if ($p.Mode -ne 'desktop') {
        Write-Info 'web 模式不需要登入協助，直接開啟後在視窗裡登入即可。'
        Start-ClaudeProfile $name
        return
    }
    $exe = Find-ClaudeExe
    if (-not $exe) { throw '找不到 Claude 桌面版。' }
    $data = Get-ProfileData $name

    Write-Info "開啟帳號「$name」..."
    Start-ClaudeProfile $name -Verify
    # Claude 啟動時可能會重新註冊 claude://，所以等它開好再改
    Start-Sleep -Seconds 3

    if (-not (Test-Path $BackupFile)) {
        if (Test-Path $ProtocolKey) {
            $orig = (Get-ItemProperty -Path $ProtocolKey).'(default)'
            Set-Content -Path $BackupFile -Value $orig -Encoding UTF8 -NoNewline
        } else {
            Set-Content -Path $BackupFile -Value '<none>' -Encoding UTF8 -NoNewline
            New-Item -Path $ProtocolKey -Force | Out-Null
            Set-ItemProperty -Path "HKCU:\Software\Classes\$Protocol" -Name '(default)' -Value "URL:$Protocol"
            Set-ItemProperty -Path "HKCU:\Software\Classes\$Protocol" -Name 'URL Protocol' -Value ''
        }
    }

    try {
        Set-ItemProperty -Path $ProtocolKey -Name '(default)' -Value "`"$exe`" --user-data-dir=`"$data`" `"%1`""
        Write-Host ''
        Write-Ok '現在請在剛開的 Claude 視窗裡登入這個帳號。'
        Write-Host '  瀏覽器問「要開啟 Claude 嗎？」時請按「開啟」。'
        Write-Host '  登入期間不要開啟其他 Claude 帳號。'
        Write-Host ''
        Read-Host '登入完成後，按 Enter 鍵還原設定'
    } finally {
        Restore-Protocol
    }
}

# ---------- 捷徑 ----------

function New-ProfileShortcut($name) {
    $p = Get-Profile $name
    if (-not $p) { throw "找不到帳號設定檔「$name」。" }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop "Claude - $name.lnk"
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)

    if ($p.Mode -eq 'web') {
        $browser = Find-Browser
        if (-not $browser) { throw '找不到 Edge 或 Chrome。' }
        $data = Get-ProfileData $name
        $lnk.TargetPath = $browser
        $lnk.Arguments  = "--user-data-dir=`"$data`" --app=$ClaudeWeb --no-first-run --no-default-browser-check"
        $lnk.IconLocation = "$browser,0"
    } else {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.TargetPath = $ps
        $lnk.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledPs`" -Launch $name"
        $lnk.WindowStyle = 7
        $icon = Find-ClaudeIcon
        if ($icon) { $lnk.IconLocation = "$icon,0" }
    }
    $lnk.Description = "Claude（帳號：$name）"
    $lnk.Save()
    Write-Ok "已在桌面建立捷徑：Claude - $name"
}

# ---------- 互動選單 ----------

function Show-Profiles {
    $list = Get-Profiles
    if (-not $list) { Write-Host '  （還沒有任何帳號設定檔）'; return }
    foreach ($p in $list) {
        $modeText = if ($p.Mode -eq 'web') { 'web（瀏覽器 app 視窗）' } else { 'desktop（官方桌面版）' }
        $note = if ($p.Note) { " - $($p.Note)" } else { '' }
        Write-Host ("  {0,-16} {1}{2}" -f $p.Name, $modeText, $note)
    }
}

function Read-ProfileName($prompt) {
    Show-Profiles
    $name = (Read-Host $prompt).Trim()
    if (-not (Get-Profile $name)) { Write-Err "找不到「$name」。"; return $null }
    return $name
}

function New-ClaudeProfile {
    Write-Host ''
    Write-Host '你原本的 Claude 桌面版就是第一個帳號，不用另外建立。這裡建立的是「額外」的帳號。'
    $name = (Read-Host '帳號代號（英文、數字、- 或 _，例如 work）').Trim()
    if (-not (Test-ProfileName $name)) { Write-Err '代號只能用英文、數字、- 或 _，最多 32 字。'; return }
    if (Get-Profile $name) { Write-Err "「$name」已經存在。"; return }
    $note = (Read-Host '備註（可留空，例如 公司帳號）').Trim()

    Write-Host ''
    Write-Host '選擇模式：'
    Write-Host '  1. desktop：官方 Claude 桌面版（有 Claude Code、Cowork、MCP 等桌面功能）'
    Write-Host '  2. web    ：Edge / Chrome 的 claude.ai 獨立視窗（最穩定，但沒有桌面版專屬功能）'
    $m = (Read-Host '請輸入 1 或 2').Trim()
    $mode = if ($m -eq '2') { 'web' } else { 'desktop' }

    if ($mode -eq 'desktop' -and -not (Find-ClaudeExe)) {
        if (Test-ClaudeStoreApp) {
            Write-Warn2 '你的 Claude 是 Microsoft Store 版，desktop 模式無法使用，自動改用 web 模式。'
        } else {
            Write-Warn2 '找不到 Claude 桌面版，自動改用 web 模式。'
        }
        $mode = 'web'
    }
    if ($mode -eq 'web' -and -not (Find-Browser)) { Write-Err '找不到 Edge 或 Chrome。'; return }

    New-Item -ItemType Directory -Path (Get-ProfileData $name) -Force | Out-Null
    [pscustomobject]@{ Mode = $mode; Note = $note } | ConvertTo-Json |
        Set-Content -Path (Get-ProfileMeta $name) -Encoding UTF8
    Write-Ok "已建立帳號「$name」（$mode 模式）。"

    if ((Read-Host '要在桌面建立捷徑嗎？(Y/n)').Trim() -notmatch '^[nN]') { New-ProfileShortcut $name }

    if ($mode -eq 'desktop') {
        if ((Read-Host '現在開啟並登入這個帳號嗎？(Y/n)').Trim() -notmatch '^[nN]') { Invoke-LoginHelper $name }
    } else {
        if ((Read-Host '現在開啟這個帳號嗎？(Y/n)').Trim() -notmatch '^[nN]') {
            Start-ClaudeProfile $name
            Write-Ok '請在開出來的視窗登入 claude.ai。之後點桌面捷徑就會直接進入這個帳號。'
        }
    }
}

function Remove-ClaudeProfile {
    $name = Read-ProfileName '要刪除的帳號代號'
    if (-not $name) { return }
    Write-Warn2 "這會刪除「$name」在這台電腦的登入狀態和本機資料（雲端上的對話不會被刪）。"
    if ((Read-Host "確定刪除請輸入 $name").Trim() -ne $name) { Write-Host '已取消。'; return }
    Remove-Item -Path (Get-ProfileDir $name) -Recurse -Force
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "Claude - $name.lnk"
    if (Test-Path $lnk) { Remove-Item -Path $lnk -Force }
    Write-Ok "已刪除「$name」。"
}

function Uninstall-ClaudeMulti {
    Write-Warn2 '這會移除這個工具、所有額外帳號的本機資料和捷徑。'
    Write-Warn2 '你原本的 Claude 桌面版和雲端上的對話都不受影響。'
    if ((Read-Host '確定移除請輸入 YES').Trim() -ne 'YES') { Write-Host '已取消。'; return $false }
    Restore-Protocol
    $desktop  = [Environment]::GetFolderPath('Desktop')
    $programs = [Environment]::GetFolderPath('Programs')
    $names = @('Claude 多帳號工具.lnk') + @(Get-Profiles | ForEach-Object { "Claude - $($_.Name).lnk" })
    foreach ($dir in @($desktop, $programs)) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        foreach ($n in $names) {
            $f = Join-Path $dir $n
            if (Test-Path $f) { Remove-Item -Path $f -Force }
        }
    }
    Remove-Item -Path $Root -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok '已完全移除。'
    return $true
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '==============================' -ForegroundColor Magenta
        Write-Host '  Claude 多帳號工具（Windows）' -ForegroundColor Magenta
        Write-Host '==============================' -ForegroundColor Magenta
        Write-Host '  1. 新增帳號'
        Write-Host '  2. 開啟帳號'
        Write-Host '  3. 重新登入帳號（桌面版登入協助）'
        Write-Host '  4. 建立桌面捷徑'
        Write-Host '  5. 列出所有帳號'
        Write-Host '  6. 刪除帳號'
        Write-Host '  7. 解除安裝這個工具'
        Write-Host '  0. 離開'
        $c = (Read-Host '請選擇').Trim()
        try {
            switch ($c) {
                '1' { New-ClaudeProfile }
                '2' { $n = Read-ProfileName '要開啟的帳號代號'; if ($n) { Start-ClaudeProfile $n -Verify } }
                '3' { $n = Read-ProfileName '要登入的帳號代號'; if ($n) { Invoke-LoginHelper $n } }
                '4' { $n = Read-ProfileName '要建立捷徑的帳號代號'; if ($n) { New-ProfileShortcut $n } }
                '5' { Show-Profiles }
                '6' { Remove-ClaudeProfile }
                '7' { if (Uninstall-ClaudeMulti) { Read-Host '按 Enter 結束' | Out-Null; return } }
                '0' { return }
                default { Write-Err '請輸入 0 到 7。' }
            }
        } catch {
            Write-Err "發生錯誤：$($_.Exception.Message)"
        }
    }
}

# ---------- 進入點 ----------

Initialize-Root

# 上次登入協助如果中途被關掉，先把 claude:// 還原
# （用捷徑開啟時不還原，避免打斷另一個視窗正在進行的登入）
if (-not $Launch -and (Test-Path $BackupFile)) {
    Write-Warn2 '偵測到上次登入協助沒有正常結束，正在還原 claude:// 連結...'
    Restore-Protocol
}

if ($Launch) {
    try { Start-ClaudeProfile $Launch }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Claude 多帳號工具') | Out-Null
    }
} elseif ($Login) {
    Invoke-LoginHelper $Login
} else {
    Show-Menu
}
