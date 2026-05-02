# Bootstrap OpenSSH Server on a freshly provisioned Win11 Vagrant box and inject
# the host's public key, so that `ssh -p 2222 vagrant@127.0.0.1 ...` works
# afterwards. Runs elevated via the Vagrantfile shell provisioner.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "==> Ensuring OpenSSH Server is present..."
# We deliberately avoid the WindowsCapability/Windows Update mechanism here -
# it has been unreliable on this box (10-30 minute installs, services in
# "marked for deletion" state, Installed-marker without on-disk binaries).
# Instead we install Win32-OpenSSH directly from its GitHub release - small,
# offline-safe, and ships its own install-sshd.ps1.
if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    $installDir    = "C:\Program Files\OpenSSH-Win64"
    $installScript = Join-Path $installDir "install-sshd.ps1"

    if (-not (Test-Path $installScript)) {
        Write-Host "    Downloading Win32-OpenSSH from GitHub..."
        $url = "https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip"
        $zip = Join-Path $env:TEMP "OpenSSH-Win64.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath "C:\Program Files" -Force
        Remove-Item $zip
    }

    Write-Host "    Registering sshd service from $installScript..."
    & PowerShell -ExecutionPolicy Bypass -File $installScript
}

Write-Host "==> Configuring sshd service..."
# Retry Set-Service for transient "marked for deletion" SCM states.
$retries = 30
while ($true) {
    try {
        Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
        break
    } catch {
        $retries--
        if ($retries -le 0) { throw }
        Start-Sleep -Seconds 2
    }
}
Start-Service sshd

Write-Host "==> Opening firewall TCP/22..."
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True -Direction Inbound -Protocol TCP `
        -Action Allow -LocalPort 22 | Out-Null
}

Write-Host "==> Setting default shell to PowerShell..."
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
    -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String -Force | Out-Null

# Place the host's public key.
#
# Default `vagrant` user IS in the Administrators group on these boxes; for
# Administrators, sshd reads from %ProgramData%\ssh\administrators_authorized_keys
# (and IGNORES the user's ~/.ssh/authorized_keys). We write to both for
# robustness - whichever the user ends up promoted/demoted to, ssh keeps working.

$pubkey = Get-Content "C:\Users\vagrant\id_ed25519.pub" -Raw

# 1) User-scope authorized_keys.
$userSshDir = "C:\Users\vagrant\.ssh"
if (-not (Test-Path $userSshDir)) {
    New-Item -ItemType Directory -Path $userSshDir | Out-Null
}
$userAuth = Join-Path $userSshDir "authorized_keys"
Set-Content -Path $userAuth -Value $pubkey -NoNewline -Encoding ascii

# 2) Administrators-scope authorized_keys (the one sshd actually reads
# for accounts in the Administrators group).
$adminAuth = "C:\ProgramData\ssh\administrators_authorized_keys"
Set-Content -Path $adminAuth -Value $pubkey -NoNewline -Encoding ascii

Write-Host "==> Locking down ACLs on key files..."
# sshd refuses to read keyfiles writable by anyone other than the owner /
# SYSTEM / Administrators. Reset ACLs to match what sshd expects.
icacls $userAuth /inheritance:r | Out-Null
icacls $userAuth /grant "vagrant:F" "SYSTEM:F" "Administrators:F" | Out-Null

icacls $adminAuth /inheritance:r | Out-Null
icacls $adminAuth /grant "SYSTEM:F" "Administrators:F" | Out-Null

Write-Host "==> Restarting sshd to pick up config + ACL changes..."
Restart-Service sshd

Write-Host "==> Done. SSH should now accept the host's public key on TCP/22."
