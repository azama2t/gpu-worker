# One-time setup of a new GPU worker (Windows 10/11). Run in PowerShell AS ADMINISTRATOR.
# Installs Tailscale, enables OpenSSH Server (auto start + firewall), adds the main PC public key, disables sleep.
# ASCII only on purpose: Windows PowerShell 5.1 misreads UTF-8 files without BOM.
#
# Optional steps (all OFF by default):
#   -Root E:\proj    project root used by -Layout and -CleanupTask (default: D:\worker if D: exists, else C:\worker)
#   -Layout          create the folder layout runner, jobs, outbox, cache, logs, tmp under -Root
#   -SetTdr          set TdrDelay=60 and TdrDdiDelay=60 (old values saved for -UndoTdr); reboot needed
#   -UndoTdr         restore the TDR values saved by -SetTdr; reboot needed
#   -CleanupTask     register hourly task "GPU Worker Cleanup" (tmp older than 24 h, delivered jobs, log rotation,
#                    STOP_DISK flag below -StopFreeGB free space)
#   -OnlyExtras      skip the base setup (Tailscale/SSH/power), run only the optional steps above
# Example (parameters do not pass through "irm | iex", use a script block):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/azama2t/gpu-worker/main/setup_once.ps1))) -OnlyExtras -Root E:\proj -Layout -CleanupTask
param(
  [string]$Root = '',
  [switch]$Layout,
  [switch]$SetTdr,
  [switch]$UndoTdr,
  [switch]$CleanupTask,
  [int]$StopFreeGB = 40,
  [int]$TmpHours = 24,
  [switch]$OnlyExtras
)
$ErrorActionPreference = 'Continue'
$pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIgfXZQSVpRQRO03nnwBhALwsJ2TL7Y8iqHW1bG3jeYn drones-main'
$SelfUrl = 'https://raw.githubusercontent.com/azama2t/gpu-worker/main/setup_once.ps1'
if (-not $Root) { if (Test-Path 'D:\') { $Root = 'D:\worker' } else { $Root = 'C:\worker' } }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is much faster without the progress bar

# 0a. 32-bit PowerShell on 64-bit Windows breaks DISM/OpenSSH: relaunch the base setup in 64-bit
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
  Write-Host '32-bit PowerShell detected, relaunching in 64-bit...' -ForegroundColor Yellow
  & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "irm '$SelfUrl' | iex"
  return
}
# 0b. Not admin: relaunch elevated (one UAC prompt)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host 'Not administrator: relaunching elevated (press Yes in the UAC window)...' -ForegroundColor Yellow
  Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', "irm '$SelfUrl' | iex"
  return
}

function Get-File([string]$Url, [string]$Out) {
  # unstable internet: 5 rounds, three different downloaders
  for ($i = 1; $i -le 5; $i++) {
    Remove-Item $Out -Force -ErrorAction SilentlyContinue
    try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Out -TimeoutSec 300 } catch {}
    if ((Test-Path $Out) -and (Get-Item $Out).Length -gt 100000) { return $true }
    try { & curl.exe -L --retry 3 --retry-delay 5 -s -o $Out $Url } catch {}
    if ((Test-Path $Out) -and (Get-Item $Out).Length -gt 100000) { return $true }
    try { Start-BitsTransfer -Source $Url -Destination $Out -ErrorAction Stop } catch {}
    if ((Test-Path $Out) -and (Get-Item $Out).Length -gt 100000) { return $true }
    Write-Host "  download try $i failed, retry in 10 s: $Url" -ForegroundColor Yellow
    Start-Sleep 10
  }
  return $false
}
function Install-Msi([string]$Msi) {
  $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$Msi`"", '/qn', '/norestart' -Wait -PassThru
  Write-Host "  msiexec exit $($p.ExitCode)"
}
$TS = 'C:\Program Files\Tailscale\tailscale.exe'

if (-not $OnlyExtras) {
# 1. Tailscale
if (-not (Test-Path $TS)) {
  Write-Host '[1] Installing Tailscale...' -ForegroundColor Cyan
  $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
  if (Get-File 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' $msi) { Install-Msi $msi }
  Remove-Item $msi -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path $TS) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    winget install -e --id Tailscale.Tailscale --silent --accept-package-agreements --accept-source-agreements
  }
}

# 2. OpenSSH Server: Windows capability -> GitHub MSI -> GitHub zip -> winget
function Test-Sshd { [bool](Get-Service sshd -ErrorAction SilentlyContinue) }
Write-Host '[2] OpenSSH Server...' -ForegroundColor Cyan
if (-not (Test-Sshd)) {
  try {
    $cap = Get-WindowsCapability -Online -ErrorAction Stop | Where-Object Name -like 'OpenSSH.Server*'
    if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null }
  } catch { Write-Host "  Windows capability failed, using the GitHub build instead" -ForegroundColor Yellow }
}
if (-not (Test-Sshd)) {
  $assets = @()
  try { $assets = (Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases' -TimeoutSec 60)[0].assets } catch {}
  $msiA = $assets | Where-Object { $_.name -like '*Win64*.msi' } | Select-Object -First 1
  if ($msiA) {
    $msi = Join-Path $env:TEMP 'openssh.msi'
    if (Get-File $msiA.browser_download_url $msi) { Install-Msi $msi }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Sshd)) {
    $zipUrl = ($assets | Where-Object { $_.name -eq 'OpenSSH-Win64.zip' } | Select-Object -First 1).browser_download_url
    if (-not $zipUrl) { $zipUrl = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip' }
    $zip = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
    if (Get-File $zipUrl $zip) {
      Expand-Archive $zip -DestinationPath $env:ProgramFiles -Force
      $dir = Join-Path $env:ProgramFiles 'OpenSSH-Win64'
      if (Test-Path "$dir\install-sshd.ps1") { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$dir\install-sshd.ps1" }
    }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Sshd) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    winget install -e --id Microsoft.OpenSSH.Preview --silent --accept-package-agreements --accept-source-agreements
  }
}
if (Test-Sshd) {
  Set-Service sshd -StartupType Automatic
  Start-Service sshd -ErrorAction SilentlyContinue
} else { Write-Host '  OpenSSH Server could NOT be installed - see messages above' -ForegroundColor Red }
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  try { New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Profile Any -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction Stop | Out-Null }
  catch { netsh advfirewall firewall add rule name="OpenSSH-Server-In-TCP" dir=in action=allow protocol=TCP localport=22 profile=any | Out-Null }
} else { Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Profile Any -ErrorAction SilentlyContinue }
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

# 3. Our key (admins read administrators_authorized_keys)
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\ssh' | Out-Null
$ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
if (-not (Test-Path $ak) -or -not (Select-String -Path $ak -SimpleMatch $pub -Quiet)) { Add-Content -Path $ak -Value $pub -Encoding ascii }
icacls $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null   # SIDs: any Windows language
$uk = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
New-Item -ItemType Directory -Force -Path (Split-Path $uk) | Out-Null
if (-not (Test-Path $uk) -or -not (Select-String -Path $uk -SimpleMatch $pub -Quiet)) { Add-Content -Path $uk -Value $pub -Encoding ascii }

# 4. No sleep on AC power, high performance
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /setactive SCHEME_MIN
}

# 5. Optional: folder layout (everything of the project lives under one root; temp files only in tmp)
if ($Layout -or $CleanupTask) {
  foreach ($d in 'runner', 'runner\state', 'jobs', 'outbox', 'cache', 'logs', 'tmp') {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null
  }
  Write-Host "Layout ready: $Root\{runner,jobs\<id>\{in,ckpt,out},outbox,cache,logs,tmp}"
  Write-Host "Runner must set TMP/TEMP/TORCH_HOME/HF_HOME/PIP_CACHE_DIR inside $Root (tmp or cache)."
}

# 6. Optional: TDR timeouts (default Windows TDR is 2 s; long CUDA kernels on a busy card can trip it)
$gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$tdrBackup = 'C:\ProgramData\gpu-worker\tdr_backup.txt'
if ($SetTdr) {
  New-Item -ItemType Directory -Force -Path (Split-Path $tdrBackup) | Out-Null
  if (-not (Test-Path $tdrBackup)) {
    $lines = @()
    foreach ($n in 'TdrDelay', 'TdrDdiDelay') {
      $v = (Get-ItemProperty -Path $gd -Name $n -ErrorAction SilentlyContinue).$n
      if ($null -eq $v) { $lines += "$n=ABSENT" } else { $lines += "$n=$v" }
    }
    Set-Content -Path $tdrBackup -Value $lines -Encoding ascii
  }
  New-ItemProperty -Path $gd -Name TdrDelay -Value 60 -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $gd -Name TdrDdiDelay -Value 60 -PropertyType DWord -Force | Out-Null
  Write-Host "TDR set to 60 s (previous values in $tdrBackup). Reboot to apply." -ForegroundColor Yellow
}
if ($UndoTdr) {
  if (Test-Path $tdrBackup) {
    foreach ($line in Get-Content $tdrBackup) {
      $n, $v = $line -split '=', 2
      if ($v -eq 'ABSENT') { Remove-ItemProperty -Path $gd -Name $n -ErrorAction SilentlyContinue }
      else { New-ItemProperty -Path $gd -Name $n -Value ([int]$v) -PropertyType DWord -Force | Out-Null }
    }
    Remove-Item $tdrBackup -Force
    Write-Host 'TDR restored. Reboot to apply.' -ForegroundColor Yellow
  } else { Write-Host "No $tdrBackup, nothing to undo." }
}

# 7. Optional: hourly cleanup task (rules: delete right after use / confirmed delivery, never touch live jobs)
if ($CleanupTask) {
  $cleanup = Join-Path $Root 'runner\cleanup_hourly.ps1'
  $body = @'
param([string]$Root, [int]$StopFreeGB = 40, [int]$TmpHours = 24, [int]$LogMB = 50)
# Rules: jobs\<id>\LEASED = live, never touched. jobs\<id>\DELIVERED.json = {"files": {"out/model.onnx": "<sha256 from receiver>"}}:
# if every listed local file still has that sha256, delete in, ckpt, out. tmp entries older than TmpHours are deleted.
# logs\*.log over LogMB are rotated (3 copies). Free space below StopFreeGB creates STOP_DISK (runner takes no new jobs).
$ErrorActionPreference = 'Continue'
$log = Join-Path $Root 'logs\cleanup.log'
function Log($m) { Add-Content -Path $log -Value ((Get-Date -Format 's') + ' ' + $m) -Encoding ascii }
$cut = (Get-Date).AddHours(-$TmpHours)
Get-ChildItem (Join-Path $Root 'tmp') -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } | ForEach-Object {
  Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue; Log ('tmp ' + $_.Name)
}
Get-ChildItem (Join-Path $Root 'jobs') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $job = $_.FullName
  if (Test-Path (Join-Path $job 'LEASED')) { return }
  $rc = Join-Path $job 'DELIVERED.json'
  if (-not (Test-Path $rc)) { return }
  try { $files = (Get-Content $rc -Raw | ConvertFrom-Json).files } catch { return }
  if ($null -eq $files) { return }
  $ok = $true; $n = 0
  foreach ($p in $files.PSObject.Properties) {
    $n++
    $f = Join-Path $job $p.Name
    if ((Test-Path $f) -and ((Get-FileHash $f -Algorithm SHA256).Hash -ne ([string]$p.Value).ToUpper())) { $ok = $false }
  }
  if ($ok -and $n -gt 0) {
    foreach ($sub in 'in', 'ckpt', 'out') {
      $d = Join-Path $job $sub
      if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; Log ('delivered ' + $_.Name + '\' + $sub) }
    }
  }
}
Get-ChildItem (Join-Path $Root 'logs') -Filter *.log -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt $LogMB * 1MB } | ForEach-Object {
  $p = $_.FullName
  Remove-Item "$p.3" -Force -ErrorAction SilentlyContinue
  if (Test-Path "$p.2") { Move-Item "$p.2" "$p.3" -Force }
  if (Test-Path "$p.1") { Move-Item "$p.1" "$p.2" -Force }
  Move-Item $p "$p.1" -Force
}
$drive = (Get-Item $Root).PSDrive.Name
$free = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
$flag = Join-Path $Root 'STOP_DISK'
if ($free -lt $StopFreeGB) {
  if (-not (Test-Path $flag)) { Set-Content $flag "free $free GB < $StopFreeGB GB" -Encoding ascii; Log "STOP_DISK set, free $free GB" }
} elseif (Test-Path $flag) { Remove-Item $flag -Force; Log "STOP_DISK cleared, free $free GB" }
Log "free $free GB"
'@
  Set-Content -Path $cleanup -Value $body -Encoding ascii
  $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cleanup`" -Root `"$Root`" -StopFreeGB $StopFreeGB -TmpHours $TmpHours"
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
  $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
  $prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
  Register-ScheduledTask -TaskName 'GPU Worker Cleanup' -Action $act -Trigger $trg -Principal $prn -Settings $set -Force | Out-Null
  Write-Host "Hourly task 'GPU Worker Cleanup' registered: $cleanup (log $Root\logs\cleanup.log)"
}

if (-not $OnlyExtras) {
# 8. Tailscale login (browser opens once), self-check and summary
Restart-Service sshd -ErrorAction SilentlyContinue
$ip = $null
for ($i = 1; $i -le 3; $i++) {
  & $TS up --unattended
  $ip = (& $TS ip -4 2>$null | Select-Object -First 1)
  if ($ip) { break }
  Write-Host "  Tailscale not connected yet (try $i), retry in 15 s" -ForegroundColor Yellow
  Start-Sleep 15
}
Write-Host ''
Write-Host '=== SELF-CHECK ===' -ForegroundColor Cyan
$script:ok = $true
function Chk([string]$Name, [bool]$Pass, [string]$Hint) {
  if ($Pass) { Write-Host "OK    $Name" -ForegroundColor Green } else { Write-Host "FAIL  $Name -> $Hint" -ForegroundColor Red; $script:ok = $false }
}
$akf = 'C:\ProgramData\ssh\administrators_authorized_keys'
Chk 'Tailscale installed' (Test-Path $TS) 'download failed: check internet and run the same command again'
Chk 'Tailscale connected' ([bool]$ip) 'click the Tailscale tray icon, log in with the owner account, run again'
Chk 'sshd service running' ((Get-Service sshd -ErrorAction SilentlyContinue).Status -eq 'Running') 'OpenSSH install failed: run again or send a photo'
Chk 'port 22 listening' ([bool](Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue)) 'run: Restart-Service sshd'
Chk 'operator key installed' ((Test-Path $akf) -and (Select-String -Path $akf -SimpleMatch $pub -Quiet)) 'run again'
Write-Host ''
if ($script:ok) { Write-Host 'DONE. Send these 3 lines to the operator (Tailscale IP, PC name, user):' -ForegroundColor Green }
else { Write-Host 'NOT COMPLETE: run the same command again; if FAIL stays, send a photo of this window.' -ForegroundColor Red }
$ip
hostname
whoami
}
