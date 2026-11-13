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
    [string]$Login,
    [string]$ProtocolUrl,
    [string]$Watch,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

$Root        = Join-Path $env:LOCALAPPDATA 'ClaudeMulti'
$ProfilesDir = Join-Path $Root 'profiles'
$InstalledPs = Join-Path $Root 'ClaudeMulti.ps1'
$BackupFile  = Join-Path $Root 'protocol-backup.txt'
$Protocol    = 'claude'
$ProtocolKey = "HKCU:\Software\Classes\$Protocol\shell\open\command"
$ClaudeWeb   = 'https://claude.ai'
$RouterProgId    = 'ClaudeMulti.claude'
$RouterAppName   = 'Claude 多帳號工具'
$LoginTargetFile = Join-Path $Root 'login-target.txt'
$RouterLogFile   = Join-Path $Root 'router.log'

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
# 帳號資料夾放在 %LOCALAPPDATA%\ClaudeMulti-<代號>（只有一層）。
# 原因：桌面版把「userData 相對 %LOCALAPPDATA% 的路徑」當 Cowork 的名稱送給 cowork-svc，
# 多層路徑（舊的 ClaudeMulti\profiles\<代號>\data）會被拒絕（invalid userData basename），
# Cowork 就不能用；服務也拒絕 junction，所以一定要真的放在單層資料夾。
function Get-ProfileDataNew($name)    { Join-Path $env:LOCALAPPDATA "ClaudeMulti-$name" }
function Get-ProfileDataLegacy($name) { Join-Path (Get-ProfileDir $name) 'data' }
function Get-ProfileData($name) {
    $new = Get-ProfileDataNew $name
    $old = Get-ProfileDataLegacy $name
    # 還沒搬家的舊帳號照舊用舊位置（搬家由 Move-ProfileDataIfLegacy 處理）
    if ((Test-Path $old) -and -not (Test-Path $new)) { return $old }
    return $new
}
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
    return [pscustomobject]@{ Name = $name; Mode = $obj.Mode; Note = $obj.Note; ClaudeConfigDir = $obj.ClaudeConfigDir }
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

function Get-ClaudeMsix {
    # Microsoft Store（MSIX）版沒有一般的 claude.exe，直接執行套件裡的 exe 也不會帶參數。
    # 但用 Invoke-CommandInDesktopPackage 在套件環境裡啟動時，Electron 照樣吃
    # --user-data-dir，所以 Store 版一樣能開獨立帳號，不必改裝直接下載版。
    if (-not (Get-Command Invoke-CommandInDesktopPackage -ErrorAction SilentlyContinue)) { return $null }
    try { $pkg = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue } catch { return $null }
    if (-not $pkg) { return $null }
    $pkg = @($pkg)[0]
    $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
    if (-not (Test-Path $exe)) { return $null }
    $appId = 'Claude'
    try {
        $app = (Get-AppxPackageManifest $pkg).Package.Applications.Application
        if ($app) { $appId = @($app)[0].Id }
    } catch { }
    return [pscustomobject]@{ Family = $pkg.PackageFamilyName; AppId = $appId; Exe = $exe; Dir = $pkg.InstallLocation }
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

function Move-ProfileDataIfLegacy($name) {
    # 舊位置的資料搬到單層資料夾（見 Get-ProfileData 的說明）。視窗開著時檔案被鎖住，先不搬。
    # 回傳 $true＝搬好了或本來就在新位置；$false＝這次沒搬
    $old = Get-ProfileDataLegacy $name
    $new = Get-ProfileDataNew $name
    if (-not (Test-Path $old)) { return $true }
    if (Test-Path $new) { return $true }
    # 捷徑是在隱藏視窗執行的，看不到訊息，所以結果另外記到 migrate.log
    $logFile = Join-Path $Root 'migrate.log'
    $stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    if (Test-ProfileRunning $name) {
        Add-Content -Path $logFile -Value "$stamp $name skipped: window still open" -Encoding UTF8 -ErrorAction SilentlyContinue
        return $false
    }
    try {
        Move-Item -LiteralPath $old -Destination $new -ErrorAction Stop
        Add-Content -Path $logFile -Value "$stamp $name moved -> $new" -Encoding UTF8 -ErrorAction SilentlyContinue
        return $true
    } catch {
        Add-Content -Path $logFile -Value "$stamp $name move failed: $($_.Exception.Message)" -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-Warn2 "「$name」的資料搬家失敗，這次先用舊位置（Cowork 可能不能用）：$($_.Exception.Message)"
        return $false
    }
}

function Start-ClaudeProfile($name, [switch]$Verify) {
    $p = Get-Profile $name
    if (-not $p) { throw "找不到帳號設定檔「$name」。" }
    if ($p.Mode -ne 'web') { Move-ProfileDataIfLegacy $name | Out-Null }
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

    $exe  = Find-ClaudeExe
    $msix = $null
    if (-not $exe) {
        $msix = Get-ClaudeMsix
        if (-not $msix) { throw '找不到 Claude 桌面版，請先從 claude.ai/download 安裝。' }
    }

    $wasEmpty = -not (Get-ChildItem -Path $data -Force -ErrorAction SilentlyContinue)
    $cliArgs = @("--user-data-dir=`"$data`"")
    if ($ProtocolUrl) { $cliArgs += "`"$ProtocolUrl`"" }

    # Claude Code 設定資料夾（CLAUDE_CONFIG_DIR）：
    #   profile.json 有 ClaudeConfigDir → 用那個資料夾
    #   沒有 → 清掉這個變數，Claude Code 用預設的 ~/.claude（工作帳號共用）
    # 使用者層級的 CLAUDE_CONFIG_DIR 指向個人資料夾（給直接開的原本 Claude 用），所以這裡一定要明確設定或清掉。
    # ⚠ 改這個檔案的人請保留這段，拿掉的話工作帳號會開成個人設定。
    $cfgDir = $null
    if ($p.ClaudeConfigDir) {
        $cfgDir = [Environment]::ExpandEnvironmentVariables([string]$p.ClaudeConfigDir)
        if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
    }

    if ($msix) {
        # 套件環境不會繼承這個 PowerShell 的環境變數，所以在套件裡先跑一個 PowerShell
        # 設好（或清掉）變數，再由它啟動 Claude.exe。用 EncodedCommand 避免網址裡的 & % 被拆壞。
        # 實測：套件內 Start-Process（ShellExecute）不會把變數傳下去，要用 UseShellExecute=false
        $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
        $envLine = if ($cfgDir) { "`$env:CLAUDE_CONFIG_DIR = $(& $q $cfgDir)" }
                   else { 'Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue' }
        $script = "$envLine`n" +
            "`$si = New-Object System.Diagnostics.ProcessStartInfo $(& $q $msix.Exe), $(& $q ($cliArgs -join ' '))`n" +
            "`$si.UseShellExecute = `$false`n" +
            "[void][System.Diagnostics.Process]::Start(`$si)"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $psExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Invoke-CommandInDesktopPackage -PackageFamilyName $msix.Family -AppId $msix.AppId `
            -Command $psExe -Args "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $enc"
    } else {
        $oldCfg = $env:CLAUDE_CONFIG_DIR
        try {
            if ($cfgDir) { $env:CLAUDE_CONFIG_DIR = $cfgDir }
            else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
            Start-Process -FilePath $exe -ArgumentList $cliArgs
        } finally {
            if ($oldCfg) { $env:CLAUDE_CONFIG_DIR = $oldCfg } else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        }
    }
    Start-TaskbarWatcher $name

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

# ---------- Store（MSIX）版的登入：claude:// 路由器 ----------
# Store 版的 claude:// 是套件 manifest 註冊的（windows.protocol），Windows 一律交給套件
# 本身，改 HKCU\Software\Classes\claude 完全沒作用（實測過）。所以瀏覽器的登入回呼一定
# 會送到原本帳號的視窗，第二個帳號永遠登不進去。
# 解法：把這支腳本註冊成 claude:// 的候選處理程式，由使用者在 Windows「預設應用程式」
# 指定一次。之後每個 claude:// 連結都先到這裡：
#   - 登入協助進行中 → 帶著 --user-data-dir 交給正在登入的那個帳號
#   - 其他時候       → 原封不動轉給原本的 Claude

function Register-ProtocolRouter {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cmd = "`"$psExe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledPs`" -ProtocolUrl `"%1`""
    $cls = "HKCU:\Software\Classes\$RouterProgId"
    New-Item -Path "$cls\shell\open\command" -Force | Out-Null
    New-Item -Path "$cls\Application" -Force | Out-Null
    Set-ItemProperty -Path $cls -Name '(default)' -Value 'URL:Claude 多帳號工具'
    Set-ItemProperty -Path $cls -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path "$cls\Application" -Name 'ApplicationName' -Value $RouterAppName
    $icon = Find-ClaudeIcon
    if ($icon) { Set-ItemProperty -Path "$cls\Application" -Name 'ApplicationIcon' -Value "$icon,0" }
    Set-ItemProperty -Path "$cls\shell\open\command" -Name '(default)' -Value $cmd

    $cap = 'HKCU:\Software\ClaudeMulti\Capabilities'
    New-Item -Path "$cap\URLAssociations" -Force | Out-Null
    Set-ItemProperty -Path $cap -Name 'ApplicationName' -Value $RouterAppName
    Set-ItemProperty -Path $cap -Name 'ApplicationDescription' -Value '把 Claude 的登入連結送到正在登入的帳號'
    Set-ItemProperty -Path "$cap\URLAssociations" -Name $Protocol -Value $RouterProgId
    if (-not (Test-Path 'HKCU:\Software\RegisteredApplications')) {
        New-Item -Path 'HKCU:\Software\RegisteredApplications' -Force | Out-Null
    }
    Set-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name 'ClaudeMulti' -Value 'Software\ClaudeMulti\Capabilities'
}

function Unregister-ProtocolRouter {
    Remove-ItemProperty -Path 'HKCU:\Software\RegisteredApplications' -Name 'ClaudeMulti' -ErrorAction SilentlyContinue
    Remove-Item -Path 'HKCU:\Software\ClaudeMulti' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Classes\$RouterProgId" -Recurse -Force -ErrorAction SilentlyContinue
}

function Test-RouterIsDefault {
    $uc = "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$Protocol\UserChoice"
    if (-not (Test-Path $uc)) { return $false }
    return ((Get-ItemProperty -Path $uc).ProgId -eq $RouterProgId)
}

function Get-LoginTarget {
    # 登入協助寫下的目標帳號；超過 15 分鐘視為過期（避免中途關掉視窗後連結一直被導走）
    if (-not (Test-Path $LoginTargetFile)) { return $null }
    $f = Get-Item -Path $LoginTargetFile
    if ($f.LastWriteTime -lt (Get-Date).AddMinutes(-15)) {
        Remove-Item -Path $LoginTargetFile -Force -ErrorAction SilentlyContinue
        return $null
    }
    $name = (Get-Content -Raw -Path $LoginTargetFile -Encoding UTF8).Trim()
    if ((Test-ProfileName $name) -and (Get-Profile $name)) { return $name }
    return $null
}

function Send-UrlToDefaultClaude($url) {
    $exe = Find-ClaudeExe
    if ($exe) { Start-Process -FilePath $exe -ArgumentList @("`"$url`""); return }
    $msix = Get-ClaudeMsix
    if ($msix) {
        Invoke-CommandInDesktopPackage -PackageFamilyName $msix.Family -AppId $msix.AppId `
            -Command $msix.Exe -Args "`"$url`""
    }
}

function Get-RunningProfiles {
    # 目前開著視窗的 desktop 模式額外帳號（用主行程命令列裡的 --user-data-dir 比對）
    $result = @()
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='Claude.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' })
    foreach ($p in Get-Profiles) {
        if ($p.Mode -ne 'desktop') { continue }
        $data = Get-ProfileData $p.Name
        $hit = @($procs | Where-Object {
                $_.CommandLine.IndexOf("`"$data`"", [StringComparison]::OrdinalIgnoreCase) -ge 0
            } | Sort-Object CreationDate)
        # 取最早啟動的那個：重複開啟時會短暫多出一個馬上結束的行程，真正的視窗在最早那個
        if ($hit.Count) {
            $result += [pscustomobject]@{ Name = $p.Name; Started = $hit[0].CreationDate; ProcessId = [int]$hit[0].ProcessId }
        }
    }
    return $result
}

function Test-ProfileRunning($name) {
    return [bool](@(Get-RunningProfiles | Where-Object { $_.Name -eq $name }).Count)
}

function Test-ProfileSignedIn($name) {
    # 從 Claude 自己的 config.json 判斷這個帳號有沒有登入。只看欄位在不在，不讀內容。
    $cfg = Join-Path (Get-ProfileData $name) 'config.json'
    if (-not (Test-Path $cfg)) { return $false }
    try { $j = Get-Content -Raw -Path $cfg -Encoding UTF8 | ConvertFrom-Json }
    catch { return $true }   # 讀不到（可能正在寫入）就當作已登入，寧可不要把連結導錯
    $names = @($j.PSObject.Properties.Name)
    if (($names -contains 'windowSizeWasSignedIn') -and ($j.windowSizeWasSignedIn -eq $false)) { return $false }
    foreach ($k in @('oauth:tokenCacheV2', 'oauth:tokenCache')) {
        if (($names -contains $k) -and $j.$k) { return $true }
    }
    return $false
}

function Write-RouterLog($target, $why, $url) {
    # 診斷用：只記「送去哪、為什麼」。網址只留主機名稱和各段長度，
    # 路徑、query、fragment 都可能帶登入碼，不能寫進檔案。
    try {
        $shape = 'unparsed'
        if ($url -match '^claude://([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$') {
            $shape = 'host={0} path={1} query={2} fragment={3}' -f $matches[1], $matches[2].Length,
                ([string]$matches[3]).Length, ([string]$matches[4]).Length
        }
        $dest = if ($target) { $target } else { 'default' }
        $line = '{0} -> {1} ({2}) {3}' -f (Get-Date -Format s), $dest, $why, $shape
        $old = @()
        if (Test-Path $RouterLogFile) { $old = @(Get-Content -Path $RouterLogFile -Encoding UTF8 | Select-Object -Last 199) }
        Set-Content -Path $RouterLogFile -Value ($old + $line) -Encoding UTF8
    } catch { }
}

function Show-LoginPicker {
    # 重新登入時，帳號的 config.json 還留著舊的登入資料，Test-ProfileSignedIn 會當它已登入，
    # 自動判斷就會把登入結果送回原本的 Claude。判斷不出來時直接問使用者。
    # 回傳帳號代號、'__default__'（原本的 Claude）或 $null（使用者關掉視窗＝不送）
    $running = @(Get-RunningProfiles | Sort-Object Started -Descending)
    if (-not $running.Count) { return '__default__' }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $RouterAppName
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.AutoSize = $true
    $form.AutoSizeMode = 'GrowAndShrink'
    $form.Font = New-Object System.Drawing.Font('Microsoft JhengHei UI', 10)
    $form.Tag = $null

    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.FlowDirection = 'TopDown'
    $panel.WrapContents = $false
    $panel.AutoSize = $true
    $panel.Padding = New-Object System.Windows.Forms.Padding(16)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '收到 Claude 的登入結果，要交給哪個帳號？'
    $title.AutoSize = $true
    $title.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $panel.Controls.Add($title)

    $choices = @()
    foreach ($r in $running) {
        $p = Get-Profile $r.Name
        $label = if ($p -and $p.Note) { "$($r.Name)（$($p.Note)）" } else { $r.Name }
        $choices += , @($label, $r.Name)
    }
    $choices += , @('原本的 Claude', '__default__')
    foreach ($c in $choices) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $c[0]
        $b.Tag = $c[1]
        $b.Width = 340
        $b.Height = 40
        $b.Add_Click({ $form.Tag = $this.Tag; $form.Close() })
        $panel.Controls.Add($b)
    }

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '直接關掉這個視窗＝不送出，回到 Claude 再按一次登入即可。'
    $hint.AutoSize = $true
    $hint.ForeColor = [System.Drawing.Color]::Gray
    $hint.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 0)
    $panel.Controls.Add($hint)

    $form.Controls.Add($panel)
    $form.Add_Shown({ $form.Activate() })
    [void]$form.ShowDialog()
    $pick = $form.Tag
    $form.Dispose()
    return $pick
}

function Resolve-RouterTarget($url) {
    # 決定這個 claude:// 連結要送給誰，回傳 @(帳號代號或 $null, 原因)
    # 帳號代號為 '__cancel__' 表示使用者選擇不送
    $target = Get-LoginTarget
    if ($target) { return @($target, 'login helper') }
    # 沒有登入協助在跑：如果有「開著但還沒登入」的額外帳號視窗，這個連結幾乎一定是它的
    # 登入結果（沒登入的視窗用不到別種連結）。有好幾個就給最後開的那個。
    $pending = @(Get-RunningProfiles | Where-Object { -not (Test-ProfileSignedIn $_.Name) } |
        Sort-Object Started -Descending)
    if ($pending.Count) { return @($pending[0].Name, "signed-out window, $($pending.Count) candidate(s)") }
    # 登入結果但每個視窗看起來都已登入（重新登入的情況）：有額外帳號開著就讓使用者選
    if ($url -match '^claude://login') {
        $pick = Show-LoginPicker
        if (-not $pick) { return @('__cancel__', 'picker closed') }
        if ($pick -eq '__default__') { return @($null, 'picker: default') }
        return @($pick, 'picker')
    }
    return @($null, 'no pending login')
}

function Invoke-ProtocolRouter($url) {
    if ($url -notmatch '^claude:') { return }
    $target, $why = Resolve-RouterTarget $url
    if ($target -eq '__cancel__') { Write-RouterLog 'cancelled' $why $url; return }
    Write-RouterLog $target $why $url
    if ($target) { Start-ClaudeProfile $target }   # Start-ClaudeProfile 會把 $ProtocolUrl 一起帶進去
    else { Send-UrlToDefaultClaude $url }
}

function Invoke-MsixLoginHandoff($name) {
    Register-ProtocolRouter
    if (-not (Test-RouterIsDefault)) {
        Write-Host ''
        Write-Warn2 'Store 版 Claude 第一次登入額外帳號前，要在 Windows 設定裡指定一次（之後不用再做）：'
        Write-Host '  1. 等一下會打開「預設應用程式」設定頁'
        Write-Host '  2. 在最上面「為檔案類型或連結類型設定預設值」的搜尋框輸入 claude'
        Write-Host '  3. 點出現的「CLAUDE」那一列'
        Write-Host "  4. 選「$RouterAppName」，按「設為預設值」"
        Write-Host '  （如果 Windows 問要不要切換，選「仍要切換」）'
        Read-Host '按 Enter 開啟設定頁' | Out-Null
        Start-Process 'ms-settings:defaultapps'
        Read-Host '設定好後回到這裡按 Enter' | Out-Null
        if (-not (Test-RouterIsDefault)) {
            Write-Err "還沒有設定成功（claude 連結的預設程式不是「$RouterAppName」）。"
            Write-Err '這樣登入結果會送到原本的帳號。請設定好後再執行一次「重新登入帳號」。'
            return
        }
        Write-Ok '設定完成。平常的 claude:// 連結仍然會開到原本的 Claude，不受影響。'
    }

    Set-Content -Path $LoginTargetFile -Value $name -Encoding UTF8 -NoNewline
    try {
        Write-Host ''
        Write-Ok "現在請在「$name」的 Claude 視窗裡登入這個帳號。"
        Write-Host '  瀏覽器請確認登入的是「這個帳號」（瀏覽器若已登入別的帳號，請先登出或用無痕視窗）。'
        Write-Host '  瀏覽器問「要開啟 Claude 嗎？」時請按「開啟」。'
        Write-Host ''
        Read-Host '登入完成後，按 Enter 鍵結束' | Out-Null
    } finally {
        Remove-Item -Path $LoginTargetFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LoginHelper($name) {
    $p = Get-Profile $name
    if (-not $p) { throw "找不到帳號設定檔「$name」。" }
    if ($p.Mode -ne 'desktop') {
        Write-Info 'web 模式不需要登入協助，直接開啟後在視窗裡登入即可。'
        Start-ClaudeProfile $name
        return
    }
    $exe  = Find-ClaudeExe
    $msix = if ($exe) { $null } else { Get-ClaudeMsix }
    if (-not $exe -and -not $msix) { throw '找不到 Claude 桌面版。' }
    $data = Get-ProfileData $name

    if ($msix -and (Test-ProfileRunning $name)) {
        # 已經開著就不要再叫一次：多出來的行程搶不到快取，會在這個視窗噴一堆嚇人的紅字
        Write-Info "帳號「$name」的視窗已經開著，請切到那個視窗。"
    } else {
        Write-Info "開啟帳號「$name」..."
        Start-ClaudeProfile $name -Verify
    }
    if ($msix) {
        Invoke-MsixLoginHandoff $name
        return
    }
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

# ---------- 帳號專屬圖示 ----------
# 每個帳號的捷徑用不同圖示：Claude 的圖示 + 右下角彩色徽章（數字或代號縮寫），
# 桌面上一眼分得出哪個是哪個。視窗開起來後工作列上的圖示是 Claude 自己的，這裡改不到。

function Get-ProfileBadge($name) {
    # 代號結尾有數字就用數字（最多兩位），否則用前兩個字
    if ($name -match '(\d{1,2})$') { return $matches[1] }
    return $name.Substring(0, [Math]::Min(2, $name.Length)).ToUpper()
}

function Get-ClaudeBaseImage {
    # 回傳 Claude 圖示的 Bitmap；找不到回傳 $null
    $msix = Get-ClaudeMsix
    if ($msix) {
        foreach ($f in @('assets\Square44x44Logo.targetsize-256.png', 'assets\Square150x150Logo.scale-400.png', 'assets\StoreLogo.png')) {
            $p = Join-Path $msix.Dir $f
            if (Test-Path $p) { return [System.Drawing.Bitmap]::FromFile($p) }
        }
    }
    $exe = Find-ClaudeIcon
    if ($exe) { return [System.Drawing.Icon]::ExtractAssociatedIcon($exe).ToBitmap() }
    return $null
}

function New-ProfileIcon($name) {
    # 產生 <帳號資料夾>\icon.ico 並回傳路徑。畫不出來就回傳 $null，呼叫端用一般圖示。
    try {
        Add-Type -AssemblyName System.Drawing
        $palette = @('#2563EB', '#16A34A', '#DC2626', '#9333EA', '#EA580C', '#0891B2', '#CA8A04', '#DB2777')
        # 顏色依代號排序後的順序分配，同時存在的帳號（八個以內）顏色不會重複
        $all = @(Get-Profiles | ForEach-Object { $_.Name } | Sort-Object)
        $idx = [Math]::Max(0, [Array]::IndexOf($all, $name))
        $color = [System.Drawing.ColorTranslator]::FromHtml($palette[$idx % $palette.Count])
        $badge = Get-ProfileBadge $name

        $master = New-Object System.Drawing.Bitmap(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($master)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)

        $base = Get-ClaudeBaseImage
        if ($base) {
            $g.DrawImage($base, 0, 0, 256, 256)
            $base.Dispose()
        } else {
            $tile = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#D97757'))
            $g.FillEllipse($tile, 8, 8, 240, 240)
            $tile.Dispose()
        }

        # 右下角徽章：白色外圈 + 彩色圓 + 白字
        $ring = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $fill = New-Object System.Drawing.SolidBrush($color)
        $g.FillEllipse($ring, 108, 108, 148, 148)
        $g.FillEllipse($fill, 118, 118, 128, 128)
        $fontPx = if ($badge.Length -ge 2) { 70 } else { 96 }
        $font = New-Object System.Drawing.Font('Segoe UI', $fontPx, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rect = New-Object System.Drawing.RectangleF(118, 114, 128, 128)
        $g.DrawString($badge, $font, $ring, $rect, $fmt)
        $font.Dispose(); $fmt.Dispose(); $ring.Dispose(); $fill.Dispose(); $g.Dispose()

        # 寫成 .ico（每個尺寸一張 PNG；Windows Vista 之後都支援）
        $images = @()
        foreach ($size in @(256, 64, 48, 32, 16)) {
            $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $gs = [System.Drawing.Graphics]::FromImage($bmp)
            $gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $gs.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $gs.DrawImage($master, 0, 0, $size, $size)
            $gs.Dispose()
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $images += , @($size, $ms.ToArray())
            $ms.Dispose()
        }
        $master.Dispose()

        $out = New-Object System.IO.MemoryStream
        $w = New-Object System.IO.BinaryWriter($out)
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)
        $offset = 6 + 16 * $images.Count
        foreach ($img in $images) {
            $dim = if ($img[0] -ge 256) { 0 } else { $img[0] }
            $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32)
            $w.Write([uint32]$img[1].Length); $w.Write([uint32]$offset)
            $offset += $img[1].Length
        }
        foreach ($img in $images) { $w.Write([byte[]]$img[1]) }
        $w.Flush()
        $path = Join-Path (Get-ProfileDir $name) 'icon.ico'
        [System.IO.File]::WriteAllBytes($path, $out.ToArray())
        $w.Dispose(); $out.Dispose()
        return $path
    } catch {
        return $null
    }
}

# ---------- 工作列分開顯示 ----------
# 所有 Claude 視窗預設共用同一個「應用程式識別碼」，在工作列會疊成同一顆按鈕、圖示也一樣。
# 這裡幫每個額外帳號的視窗掛上自己的識別碼和圖示，工作列就會各自一顆按鈕。
# 這個屬性是掛在視窗上的，視窗重開就沒了，所以每個開著的帳號留一個很輕的背景程序
# 持續補掛，帳號視窗關掉它就自己結束。

$TaskbarInteropSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ClaudeMultiTaskbar {
  [StructLayout(LayoutKind.Sequential, Pack = 4)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Explicit, Size = 24)] public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    [PreserveSig] int GetCount(out uint c);
    [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
    [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
    [PreserveSig] int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
    [PreserveSig] int Commit();
  }
  [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);
  [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT v);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
  static readonly Guid Fmt = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");   // System.AppUserModel.*
  static readonly Guid StoreIid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

  // Visible, unowned, titled top-level windows of one process.
  public static List<IntPtr> TopWindows(uint pid) {
    var r = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p == pid && IsWindowVisible(h) && GetWindow(h, 4) == IntPtr.Zero && GetWindowTextLength(h) > 0) r.Add(h);
      return true;
    }, IntPtr.Zero);
    return r;
  }
  static void SetStr(IPropertyStore s, uint pid, string val) {
    if (string.IsNullOrEmpty(val)) return;
    var k = new PROPERTYKEY { fmtid = Fmt, pid = pid };
    var v = new PROPVARIANT { vt = 31, p = Marshal.StringToCoTaskMemUni(val) };   // VT_LPWSTR
    s.SetValue(ref k, ref v); PropVariantClear(ref v);
  }
  public static string GetAppId(IntPtr hwnd) {
    Guid iid = StoreIid; IPropertyStore s;
    if (SHGetPropertyStoreForWindow(hwnd, ref iid, out s) != 0) return null;
    var k = new PROPERTYKEY { fmtid = Fmt, pid = 5 }; PROPVARIANT v;
    if (s.GetValue(ref k, out v) != 0 || v.vt != 31) return null;
    string r = Marshal.PtrToStringUni(v.p); PropVariantClear(ref v); return r;
  }
  // pid 5 = ID, 3 = RelaunchIconResource, 2 = RelaunchCommand, 4 = RelaunchDisplayNameResource
  public static bool Apply(IntPtr hwnd, string appId, string icon, string relaunch, string name) {
    Guid iid = StoreIid; IPropertyStore s;
    if (SHGetPropertyStoreForWindow(hwnd, ref iid, out s) != 0) return false;
    SetStr(s, 5, appId); SetStr(s, 3, icon); SetStr(s, 2, relaunch); SetStr(s, 4, name);
    return s.Commit() == 0;
  }
}
'@

function Start-TaskbarWatcher($name) {
    # 另開一個隱藏的背景程序去顧工作列；同一個帳號已經有人在顧的話，新的會馬上結束
    try {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$InstalledPs`"", '-Watch', $name)
    } catch { }
}

function Invoke-TaskbarWatcher($name) {
    if (-not (Test-ProfileName $name)) { return }
    $p = Get-Profile $name
    if (-not $p -or $p.Mode -ne 'desktop') { return }
    $mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeMulti.Watch.$name")
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return }

        Add-Type -TypeDefinition $TaskbarInteropSource
        $icon = Join-Path (Get-ProfileDir $name) 'icon.ico'
        if (-not (Test-Path $icon)) { $icon = New-ProfileIcon $name }
        $iconRes = if ($icon) { "$icon,0" } else { '' }
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # 使用者把這顆按鈕釘選到工作列時，Windows 會用這條指令重新開啟
        $relaunch = "`"$psExe`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledPs`" -Launch $name"
        $appId = "ClaudeMulti.$name"

        # 等這個帳號的主行程出現（最多約 60 秒）
        $procId = 0
        for ($i = 0; $i -lt 30 -and -not $procId; $i++) {
            $r = @(Get-RunningProfiles | Where-Object { $_.Name -eq $name })
            if ($r.Count) { $procId = $r[0].ProcessId } else { Start-Sleep -Seconds 2 }
        }
        if (-not $procId) { return }
        $proc = [System.Diagnostics.Process]::GetProcessById($procId)
        while (-not $proc.HasExited) {
            foreach ($h in [ClaudeMultiTaskbar]::TopWindows([uint32]$procId)) {
                if ([ClaudeMultiTaskbar]::GetAppId($h) -ne $appId) {
                    [void][ClaudeMultiTaskbar]::Apply($h, $appId, $iconRes, $relaunch, "Claude - $name")
                }
            }
            Start-Sleep -Seconds 2
        }
    } catch {
    } finally {
        if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
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
    $profileIcon = New-ProfileIcon $name
    if ($profileIcon) { $lnk.IconLocation = "$profileIcon,0" }
    $lnk.Description = "Claude（帳號：$name）"
    $lnk.Save()
    Write-Ok "已在桌面建立捷徑：Claude - $name"
}

function Install-Launcher {
    # 離線安裝包用：建立「Claude 多帳號工具」捷徑（桌面 + 開始功能表）。
    # 線上安裝（install.ps1）自己會建同名捷徑，兩邊檔名必須一致，解除安裝才刪得到。
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ws = New-Object -ComObject WScript.Shell
    $icon = Find-ClaudeIcon
    foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        $lnk = $ws.CreateShortcut((Join-Path $dir "$RouterAppName.lnk"))
        $lnk.TargetPath = $ps
        $lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -File `"$InstalledPs`""
        $lnk.WorkingDirectory = $Root
        $lnk.Description = '新增、開啟、管理多個 Claude 帳號'
        if ($icon) { $lnk.IconLocation = "$icon,0" }
        $lnk.Save()
    }
    Write-Ok "已安裝，桌面和開始功能表有「$RouterAppName」捷徑。"
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
        if (Get-ClaudeMsix) {
            Write-Info '偵測到 Microsoft Store 版 Claude，改用套件模式啟動（一樣是獨立資料夾）。'
        } else {
            Write-Warn2 '找不到 Claude 桌面版，自動改用 web 模式。'
            $mode = 'web'
        }
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
    $newData = Get-ProfileDataNew $name
    if (Test-Path $newData) { Remove-Item -Path $newData -Recurse -Force }
    Remove-Item -Path (Get-ProfileDir $name) -Recurse -Force
    $lnk =Join-Path ([Environment]::GetFolderPath('Desktop')) "Claude - $name.lnk"
    if (Test-Path $lnk) { Remove-Item -Path $lnk -Force }
    Write-Ok "已刪除「$name」。"
}

function Uninstall-ClaudeMulti {
    Write-Warn2 '這會移除這個工具、所有額外帳號的本機資料和捷徑。'
    Write-Warn2 '你原本的 Claude 桌面版和雲端上的對話都不受影響。'
    if ((Read-Host '確定移除請輸入 YES').Trim() -ne 'YES') { Write-Host '已取消。'; return $false }
    Restore-Protocol
    Unregister-ProtocolRouter
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
    foreach ($p in @(Get-Profiles)) {
        $newData = Get-ProfileDataNew $p.Name
        if (Test-Path $newData) { Remove-Item -Path $newData -Recurse -Force -ErrorAction SilentlyContinue }
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
if (-not $Launch -and -not $ProtocolUrl -and -not $Watch -and (Test-Path $BackupFile)) {
    Write-Warn2 '偵測到上次登入協助沒有正常結束，正在還原 claude:// 連結...'
    Restore-Protocol
}

if ($Watch) {
    # 背景程序：顧某個帳號視窗的工作列識別，沒有主控台，失敗就安靜結束
    Invoke-TaskbarWatcher $Watch
} elseif ($ProtocolUrl -and -not $Launch) {
    # 被 Windows 當成 claude:// 處理程式叫起來：沒有主控台可以顯示錯誤，失敗就安靜結束
    try { Invoke-ProtocolRouter $ProtocolUrl } catch { }
} elseif ($Launch) {
    try { Start-ClaudeProfile $Launch }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Claude 多帳號工具') | Out-Null
    }
} elseif ($Login) {
    Invoke-LoginHelper $Login
} elseif ($Install) {
    Install-Launcher
    Show-Menu
} else {
    Show-Menu
}
