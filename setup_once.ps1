# Однократная настройка нового GPU-воркера (Windows 10). Запускать в PowerShell ОТ АДМИНИСТРАТОРА.
# Делает: Tailscale, OpenSSH Server (автозапуск), наш ключ для входа, правило брандмауэра, без сна, план питания.
$ErrorActionPreference = 'Continue'
$pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIgfXZQSVpRQRO03nnwBhALwsJ2TL7Y8iqHW1bG3jeYn drones-main'

# 1. Tailscale
if (-not (Get-Command tailscale -ErrorAction SilentlyContinue) -and -not (Test-Path 'C:\Program Files\Tailscale\tailscale.exe')) {
  winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements
}

# 2. OpenSSH Server
$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic; Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
# PowerShell как оболочка по умолчанию для ssh
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

# 3. Наш ключ: для админов Windows ключи читаются из administrators_authorized_keys
$ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
if (-not (Test-Path $ak) -or -not (Select-String -Path $ak -SimpleMatch $pub -Quiet)) { Add-Content -Path $ak -Value $pub -Encoding ascii }
icacls $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
$uk = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
New-Item -ItemType Directory -Force -Path (Split-Path $uk) | Out-Null
if (-not (Test-Path $uk) -or -not (Select-String -Path $uk -SimpleMatch $pub -Quiet)) { Add-Content -Path $uk -Value $pub -Encoding ascii }

# 4. Без сна и гибернации от сети, высокая производительность
powercfg /change standby-timeout-ac 0; powercfg /change hibernate-timeout-ac 0; powercfg /change monitor-timeout-ac 30
powercfg /setactive SCHEME_MIN

# 5. Вход в Tailscale (откроется браузер один раз) и итог
& 'C:\Program Files\Tailscale\tailscale.exe' up --unattended
Write-Host "`nГОТОВО. Пришлите в чат: имя ПК в Tailscale и пользователя Windows:" -ForegroundColor Green
& 'C:\Program Files\Tailscale\tailscale.exe' ip -4
whoami
hostname
