# Install LDC (LLVM-based D compiler) on Win11.
# Downloads the official Inno Setup installer from LDC's GitHub releases and
# runs it silently. Idempotent: skipped if already installed at the target dir.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Update this when bumping versions.
$version    = "1.42.0"
$installer  = "ldc2-$version-windows-multilib.exe"
$url        = "https://github.com/ldc-developers/ldc/releases/download/v$version/$installer"
$installDir = "C:\ldc2"

if (Test-Path "$installDir\bin\ldc2.exe") {
    Write-Host "==> LDC $version already installed at $installDir; skipping."
    return
}

Write-Host "==> Downloading LDC $version..."
$tmp = Join-Path $env:TEMP $installer
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing

Write-Host "==> Installing silently to $installDir..."
$proc = Start-Process -FilePath $tmp `
    -ArgumentList "/VERYSILENT", "/SP-", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=`"$installDir`"" `
    -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    throw "LDC installer exited with code $($proc.ExitCode)"
}

Remove-Item $tmp

Write-Host "==> Ensuring $installDir\bin is on system PATH..."
$path = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($path -notlike "*$installDir\bin*") {
    [Environment]::SetEnvironmentVariable("Path", "$path;$installDir\bin", "Machine")
}

Write-Host "==> LDC $version installed."
