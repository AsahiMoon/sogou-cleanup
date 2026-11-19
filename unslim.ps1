#requires -Version 5.1
# Undo slim.ps1: restore every *.disabled item renamed by the slim-down,
# and re-enable the firewall rules / cloud input it changed. Safe to re-run.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File unslim.ps1
param()

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argsElev = '-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"'
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $argsElev -Verb RunAs -Wait -ErrorAction Stop; exit 0 }
    catch { Write-Host 'ERROR: administrator rights required.' -ForegroundColor Red; exit 2 }
}

$ErrorActionPreference = 'Continue'
$LogDir = Join-Path $env:ProgramData 'SogouHarden'
$Log = Join-Path $LogDir 'unslim-log.txt'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
function Log([string]$m) { Add-Content -Path $Log -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $m) -Encoding UTF8 }

Log '================ unslim start ================'
$n = 0

# locate install root
$root = $null
try { $root = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Sogou Input' -ErrorAction Stop).InstallLocation } catch { }
if (-not $root) { try { $root = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Sogou Input' -ErrorAction Stop).InstallLocation } catch { } }
if (-not $root -or -not (Test-Path -LiteralPath $root)) {
    foreach ($c in @('C:\Program Files (x86)\SogouInput','C:\Program Files\SogouInput','D:\Software\SogouInput')) { if (Test-Path -LiteralPath $c) { $root = $c; break } }
}
Log ('install root: ' + $root)

# restore all *.disabled under install dir, user profile promo apps, and ProgramData caches
$searchRoots = @()
if ($root) { $searchRoots += $root }
$searchRoots += $env:LOCALAPPDATA
$searchRoots += (Join-Path $env:ProgramData 'SogouInput')
foreach ($sr in $searchRoots) {
    if (-not (Test-Path -LiteralPath $sr)) { continue }
    Get-ChildItem -LiteralPath $sr -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.disabled' } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            $orig = $_.FullName -replace '\.disabled$',''
            try { Move-Item -LiteralPath $_.FullName -Destination $orig -Force -ErrorAction Stop; $n++; Log ('RESTORED ' + $orig) }
            catch { Log ('RESTORE-FAIL ' + $_.FullName) }
        }
}
Log ('items restored: ' + $n)

# remove slim firewall rules
Get-NetFirewallRule -DisplayName 'DSH-Sogou-Slim-*' -ErrorAction SilentlyContinue | ForEach-Object {
    try { Remove-NetFirewallRule -Name $_.Name -ErrorAction SilentlyContinue; Log ('FWRULE removed ' + $_.DisplayName) } catch {}
}

# remove the component-download hosts block
try {
    $hosts = 'C:\Windows\System32\drivers\etc\hosts'
    $cur = [IO.File]::ReadAllText($hosts)
    if ($cur -match 'DSH-Sogou-NoComponentDL') {
        $cur = [regex]::Replace($cur, '(?m)\r?\n[ \t]*# DSH-Sogou-NoComponentDL\r?\n[\s\S]*?# DSH-Sogou-NoComponentDL-end\r?\n', "`r`n")
        [IO.File]::WriteAllText($hosts, $cur, [Text.Encoding]::ASCII)
        Log 'hosts removed NoComponentDL block'
    }
} catch { Log ('hosts unblock fail : ' + $_.Exception.Message) }

Log '================ unslim done ================'
Write-Host ("Restored " + $n + " items. Please re-open Sogou Input / reboot if needed.")
