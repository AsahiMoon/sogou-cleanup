#requires -Version 5.1
# Sogou IME conservative slim-down (whitelist-protected).
# Goal: remove ads / promo / auto-update, KEEP account sync + skin mall + typing.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File slim.ps1 [-Purge]
#   default : rename removable items to *.disabled (fully revertible)
#   -Purge  : delete them for real (backup of user data is still made)
# Log: %ProgramData%\SogouHarden\slim-log.txt
param([switch]$Purge)

# Self-elevate: renaming exes under the install dir and creating firewall rules
# both require administrator rights. Re-launch elevated if not already admin.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argsElev = '-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"'
    if ($Purge) { $argsElev += ' -Purge' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argsElev -Verb RunAs -Wait -ErrorAction Stop
        exit 0
    } catch {
        Write-Host 'ERROR: administrator rights are required (UAC elevation was declined).' -ForegroundColor Red
        exit 2
    }
}

$ErrorActionPreference = 'Continue'
$LogDir  = Join-Path $env:ProgramData 'SogouHarden'
$Log     = Join-Path $LogDir 'slim-log.txt'
$BackupD = Join-Path $LogDir 'backup'
New-Item -ItemType Directory -Force -Path $LogDir, $BackupD | Out-Null
$script:ok = 0; $script:fail = 0; $script:opFail = 0

function Log([string]$m) { Add-Content -Path $Log -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $m) -Encoding UTF8 }
function Step([string]$name, [scriptblock]$sb) { try { & $sb; $script:ok++; Log ('OK   ' + $name) } catch { $script:fail++; Log ('FAIL ' + $name + ' : ' + $_.Exception.Message) } }

Log '================ slim start (Purge=' + $Purge.IsPresent.ToString() + ') ================'

# ---------- 0. WHITELIST: things that must NEVER be touched ----------
# Account sync + skin mall + typing depend on these. Any operation below skips them.
$PROTECT_FILES = @(
    'SogouTSF.ime','SogouPY.ime','SGMyInput.exe','SGWebRender.exe','SGTool.exe',
    'SogouCloud.exe','SogouComMgr.exe','userNetSchedule.exe','SogouSvc.exe',
    'SogouExe.exe','SGDownload.exe','ZipLib.dll','ComponentConfig.ini',
    'SkinRecent.ini','SkinLove.ini','SkinMakeSelf.ini','skin.dat','skin_v3.dat',
    'acc.dat','user.dat','usrZone.dat','usrzoneext.dat'
)
$PROTECT_DIRS = @('SogouFlash','Theme','Data','SogouExe','Components','AllSkin','users','scd',
                  'SGRender')
function Is-Protected([string]$path) {
    $name = Split-Path -Leaf $path
    if ($PROTECT_FILES -contains $name) { return $true }
    if ($PROTECT_DIRS -contains $name) { return $true }
    return $false
}

# ---------- 1. locate install root dynamically ----------
$root = $null
try { $root = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Sogou Input' -ErrorAction Stop).InstallLocation } catch { }
if (-not $root) { try { $root = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Sogou Input' -ErrorAction Stop).InstallLocation } catch { } }
if (-not $root -or -not (Test-Path -LiteralPath $root)) {
    foreach ($c in @('C:\Program Files (x86)\SogouInput','C:\Program Files\SogouInput','D:\Software\SogouInput')) {
        if (Test-Path -LiteralPath $c) { $root = $c; break }
    }
}
if (-not $root -or -not (Test-Path -LiteralPath $root)) { Log 'FATAL: SogouInput install not found'; exit 2 }
$script:root = $root
Log ('install root: ' + $root)
$verDirs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -match '^\d+(\.\d+){3}' })
$liveDirs = @($verDirs | Where-Object { $_.Name -notmatch '\.disabled' })
$activeDir = $null
if ($liveDirs.Count) { $activeDir = $liveDirs | Sort-Object { [version]$_.Name } | Select-Object -Last 1 }
Log ('version dirs: ' + (($verDirs | ForEach-Object { $_.Name }) -join ', ') + ' | active: ' + $(if($activeDir){$activeDir.Name}else{'none'}))

# ---------- 2. backup user data (account + skin) BEFORE any change ----------
Step 'backup account+skin user data' {
    # LocalLow is a SIBLING of Local (not Local\Low). Derive it from the Local path.
    $localLow = Join-Path (Split-Path $env:LOCALAPPDATA -Parent) 'LocalLow'
    $ud = @(
        (Join-Path $localLow 'SogouPY'),
        (Join-Path $env:LOCALAPPDATA 'SogouPY'),
        (Join-Path $env:APPDATA 'SogouPY'),
        (Join-Path $localLow 'SogouPY.users')
    )
    foreach ($d in $ud) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $tag = ($d -replace '[\\:]', '_')
        $dest = Join-Path $BackupD ('userdata' + $tag)
        try { Copy-Item -LiteralPath $d -Destination $dest -Recurse -Force -ErrorAction Stop; Log ('BACKUP userdata ' + $d) }
        catch { Log ('BACKUP userdata skip ' + $d + ' : ' + $_.Exception.Message) }
    }
}

# ---------- 3. kill only removable / updater processes ----------
# Never kill the IME core, SGMyInput (settings/skin host), SogouCloud (kernel host)
Step 'kill promo/updater processes' {
    $killNames = @('PinyinUp','SGBizLauncher','SGSmartAssistant','SGIGuideHelper','sgfeedbackhelper','crashrpt','SogouImeRepair','SogouToolkits')
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and ($_.ExecutablePath -like ($root + '*')) -and ($killNames -contains [IO.Path]::GetFileNameWithoutExtension($_.ExecutablePath))
    } | ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Log ('KILL ' + $_.Name + ' pid=' + $_.ProcessId) } catch { }
    }
}

# ---------- 4. disable updater / promo EXEs (whitelist-guarded) ----------
# NOT touched (protected): SogouCloud, userNetSchedule, SGDownload, SGMyInput,
# SGWebRender, SGTool, SogouComMgr, SogouSvc/SogouExe.
$DISABLE_EXE = @('PinyinUp.exe','Install64.exe','SogouImeRepair.exe',
                 'SGBizLauncher.exe','SGSmartAssistant.exe','SGIGuideHelper.exe',
                 'sgfeedbackhelper.exe','crashrpt.exe','SogouToolkits.exe')
function Handle-Item([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return }
    if (Is-Protected $p) { Log ('SKIP-PROTECTED ' + $p); return }
    $dis = $p + '.disabled'
    if ($Purge) {
        try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; Log ('DELETED ' + $p) }
        catch { $script:opFail++; Log ('DELETE-FAIL ' + $p + ' : ' + $_.Exception.Message) }
    } else {
        # Component manager may have re-downloaded an item we disabled earlier,
        # leaving both "X" and "X.disabled". Drop the stale copy first so the
        # rename of the freshly-downloaded one does not collide.
        if (Test-Path -LiteralPath $dis) {
            try { Remove-Item -LiteralPath $dis -Recurse -Force -ErrorAction Stop; Log ('REMOVED-STALE-DISABLED ' + $dis) }
            catch { $script:opFail++; Log ('STALE-REMOVE-FAIL ' + $dis + ' : ' + $_.Exception.Message); return }
        }
        try { Move-Item -LiteralPath $p -Destination $dis -Force -ErrorAction Stop; Log ('RENAMED ' + $p) }
        catch { $script:opFail++; Log ('RENAME-FAIL ' + $p + ' : ' + $_.Exception.Message) }
    }
}
Step 'disable updater/promo exes' {
    foreach ($vd in $liveDirs) { foreach ($n in $DISABLE_EXE) { Handle-Item (Join-Path $vd.FullName $n) } }
}

# ---------- 5. remove pure promo component folders (whitelist-guarded) ----------
# MobileInput = cross-screen/cross-device input; unrelated to account sync or skin.
# SGRender is deliberately NOT here - it is protected (advanced skin rendering).
$PROMO_DIRS = @('biz_center','biz_pdf','game_center','AppBox','IChat','isgpet',
                'PicFace','WriteSpirit','systembeautify','MobileInput')
Step 'remove promo component folders' {
    $comp = Join-Path $root 'Components'
    foreach ($n in $PROMO_DIRS) { Handle-Item (Join-Path $comp $n) }
    # stop SGMobileInput process if present so its folder can be renamed
    Get-Process -Name SGMobileInput -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---------- 6. remove promo apps in user profile (PDF/zip/picture bundles) ----------
$PROMO_APPDIRS = @('kzip_sogou','sogoupdf','fastpdf_sogou','kfastpic_sogou','kdiskmgr_sogou','kwallpaper_sogou','sogousdk')
Step 'remove promo apps in user profile' {
    foreach ($n in $PROMO_APPDIRS) { Handle-Item (Join-Path $env:LOCALAPPDATA $n) }
}

# ---------- 7. firewall: block ONLY updater/promo exes at CURRENT path ----------
# Protected exes are never blocked. SGDownload/SogouCloud are NOT blocked here
# (they carry skin/account/network functions); cloud input is disabled via registry instead.
Step 'firewall block updater/promo exes' {
    Get-NetFirewallRule -DisplayName 'DSH-Sogou-Slim-*' -ErrorAction SilentlyContinue | ForEach-Object { try { Remove-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue } catch {} }
    $made = 0
    foreach ($vd in $liveDirs) {
        foreach ($n in $DISABLE_EXE) {
            $exe = Join-Path $vd.FullName $n
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            if (Is-Protected $exe) { continue }
            $dn = 'DSH-Sogou-Slim-' + $n
            if (-not (Get-NetFirewallRule -DisplayName $dn -ErrorAction SilentlyContinue)) {
                try { New-NetFirewallRule -DisplayName $dn -Direction Outbound -Program $exe -Action Block -Profile Any -Enabled True -Description 'Sogou slim (protected exes excluded)' -ErrorAction Stop | Out-Null; $made++ }
                catch { $script:opFail++; Log ('FW-ADD-FAIL ' + $exe + ' : ' + $_.Exception.Message) }
            }
        }
    }
    Log ('firewall rules added: ' + $made)
}

# ---------- 8. clean stale firewall rules from previous C:-drive runs ----------
Step 'remove stale DSH-Sogou-Block rules' {
    $stale = Get-NetFirewallRule -DisplayName 'DSH-Sogou-Block-*' -ErrorAction SilentlyContinue
    foreach ($r in $stale) {
        try { Remove-NetFirewallRule -Name $r.Name -ErrorAction Stop; Log ('FWRULE removed stale ' + $r.DisplayName) }
        catch { $script:opFail++; Log ('FWRULE-REMOVE-FAIL ' + $r.DisplayName + ' : ' + $_.Exception.Message) }
    }
}

# ---------- 9. disable cloud input via registry (keep account sync intact) ----------
# Cloud input = SogouCloud candidates; turning it off does NOT stop account sync.
# Set to 0 to disable cloud candidates; set to 1 to re-enable any time.
Step 'disable cloud input (optional, reversible)' {
    $keys = @('HKCU:\Software\SogouInput','HKCU:\Software\SogouInput\Client','HKCU:\Software\SogouInput\Cloud')
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        foreach ($v in @('EnableCloudInput','CloudCand','EnablePinyinCloud')) {
            $cur = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).$v
            if ($null -ne $cur) {
                try { Set-ItemProperty -LiteralPath $k -Name $v -Value 0 -ErrorAction Stop; Log ('REG cloud off ' + $k + ' :: ' + $v) } catch {}
            }
        }
    }
}

# ---------- 10. clean genuine ad/update caches (NEVER cache/SGCefCache/imepop) ----------
# cache\urlcache = skin thumbnails; SGCefCache = skin mall CEF data; imepop = skin data.
Step 'clean ad/update caches only' {
    $pd = 'C:\ProgramData\SogouInput'
    foreach ($d in @('ShiplyUpdate','SGSysToast','SGBizConfig')) { Handle-Item (Join-Path $pd $d) }
}

# ---------- 10b. block component auto-download host (prevents promo parts "reviving") ----------
# SogouCloud/SGTool daemons re-download removed Components from dl.pinyin.sogou.com.
# We cannot kill those daemons (skin mall + account need them), so block only the
# component-package download host. Skin/account use DIFFERENT hosts
# (pcskin/h5api.sginput.qq.com, account.sogou.com, imedl.sogoucdn.com, res.sogou),
# none of which are touched here.
Step 'block component download host in hosts' {
    $hosts = 'C:\Windows\System32\drivers\etc\hosts'
    $mk = '# DSH-Sogou-NoComponentDL'
    $end = '# DSH-Sogou-NoComponentDL-end'
    try {
        $cur = [IO.File]::ReadAllText($hosts)
        if ($cur -match [regex]::Escape($mk)) {
            $cur = [regex]::Replace($cur, '(?m)\r?\n[ \t]*' + [regex]::Escape($mk) + '\r?\n[\s\S]*?' + [regex]::Escape($end) + '\r?\n', "`r`n")
            Log 'hosts removed old NoComponentDL section (self-heal)'
        }
        $block = "`r`n$mk`r`n0.0.0.0 dl.pinyin.sogou.com`r`n$end`r`n"
        [IO.File]::WriteAllText($hosts, ($cur -replace "`r`n$", '') + $block, [Text.Encoding]::ASCII)
        Log 'hosts blocked dl.pinyin.sogou.com (component downloads only)'
    } catch { $script:opFail++; Log ('hosts block fail : ' + $_.Exception.Message) }
}

# ---------- 11. keep SogouSvc service as official default (account sync channel) ----------
# Do NOT disable SogouSvc: it is the account/lexicon sync channel. Leave Manual.
Step 'verify protected components intact' {
    $missing = @()
    foreach ($n in @('SGMyInput.exe','SGWebRender.exe','SGTool.exe','SogouCloud.exe','userNetSchedule.exe','SogouComMgr.exe')) {
        if (-not (Get-ChildItem -LiteralPath $root -Recurse -File -Filter $n -ErrorAction SilentlyContinue | Select-Object -First 1)) { $missing += $n }
    }
    if ($missing.Count) { Log ('WARN protected missing: ' + ($missing -join ', ')) }
    else { Log 'OK all protected components present (account sync + skin intact)' }
    $svc = Get-Service SogouSvc -ErrorAction SilentlyContinue
    if ($svc) { Log ('SogouSvc left as-is: ' + $svc.StartType) } else { Log 'SogouSvc not present' }
}

if ($script:opFail -gt 0) { Log ('WARNING: ' + $script:opFail + ' item(s) could not be changed (usually permission denied - run as administrator)') }
Log ('================ slim done: ok=' + $script:ok + ' fail=' + $script:fail + ' opFail=' + $script:opFail + ' ================')
if (($script:fail + $script:opFail) -gt 0) { exit 1 } else { exit 0 }
