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
if (-not $Root) { if (Test-Path 'D:\') { $Root = 'D:\worker' } else { $Root = 'C:\worker' } }

if (-not $OnlyExtras) {
# 1. Tailscale
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) {
  # fresh Windows may have no winget: install the official MSI directly
  $msi = Join-Path $env:TEMP 'tailscale-setup.msi'
  Invoke-WebRequest -UseBasicParsing -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi' -OutFile $msi
  Start-Process msiexec.exe -ArgumentList '/i', $msi, '/quiet', '/norestart' -Wait
  Remove-Item $msi -Force -ErrorAction SilentlyContinue   # do not leave installers in TEMP
}

# 2. OpenSSH Server
$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

# 3. Our key (admins read administrators_authorized_keys)
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
# 8. Tailscale login (browser opens once) and summary
& 'C:\Program Files\Tailscale\tailscale.exe' up --unattended
Write-Host ''
Write-Host 'DONE. Send these 3 lines to the operator (Tailscale IP, PC name, user):' -ForegroundColor Green
& 'C:\Program Files\Tailscale\tailscale.exe' ip -4
hostname
whoami
}
