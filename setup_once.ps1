# One-time setup of a new GPU worker (Windows 10). Run in PowerShell AS ADMINISTRATOR.
# Installs Tailscale, enables OpenSSH Server (auto start + firewall), adds the main PC public key, disables sleep.
# ASCII only on purpose: Windows PowerShell 5.1 misreads UTF-8 files without BOM.
$ErrorActionPreference = 'Continue'
$pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIgfXZQSVpRQRO03nnwBhALwsJ2TL7Y8iqHW1bG3jeYn drones-main'

# 1. Tailscale
if (-not (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) {
  winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements
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
icacls $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
$uk = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
New-Item -ItemType Directory -Force -Path (Split-Path $uk) | Out-Null
if (-not (Test-Path $uk) -or -not (Select-String -Path $uk -SimpleMatch $pub -Quiet)) { Add-Content -Path $uk -Value $pub -Encoding ascii }

# 4. No sleep on AC power, high performance
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /setactive SCHEME_MIN

# 5. Tailscale login (browser opens once) and summary
& 'C:\Program Files\Tailscale\tailscale.exe' up --unattended
Write-Host ''
Write-Host 'DONE. Send these 3 lines to the operator (Tailscale IP, PC name, user):' -ForegroundColor Green
& 'C:\Program Files\Tailscale\tailscale.exe' ip -4
hostname
whoami
