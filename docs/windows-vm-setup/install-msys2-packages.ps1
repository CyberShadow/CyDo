# Install MSYS2 packages needed for the dev workflow (currently: rsync).
# MSYS2 itself is installed by winget via cydo-windev.yaml; this script
# populates it with the userland we want.
#
# Idempotent: pacman -S on an already-installed package is a no-op,
# and we skip the script entirely if rsync is already present on PATH.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$msys2Bin = "C:\msys64\usr\bin"
$pacman   = Join-Path $msys2Bin "pacman.exe"
$rsync    = Join-Path $msys2Bin "rsync.exe"

if (-not (Test-Path $pacman)) {
    throw "MSYS2 not found at C:\msys64; expected winget package MSYS2.MSYS2 to have installed it."
}

if (Test-Path $rsync) {
    Write-Host "==> rsync already present at $rsync; skipping pacman."
} else {
    Write-Host "==> Refreshing MSYS2 package database..."
    & $pacman --noconfirm -Sy
    if ($LASTEXITCODE -ne 0) { throw "pacman -Sy failed with exit code $LASTEXITCODE" }

    Write-Host "==> Installing rsync via pacman..."
    & $pacman --noconfirm -S rsync
    if ($LASTEXITCODE -ne 0) { throw "pacman -S rsync failed with exit code $LASTEXITCODE" }
}

# Append MSYS2 bin to system PATH (append, NOT prepend) so rsync.exe and
# other utilities are discoverable by Win32-OpenSSH's exec resolution
# without shadowing the system OpenSSH that we already installed.
Write-Host "==> Ensuring $msys2Bin is on system PATH (appended)..."
$path = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($path -notlike "*$msys2Bin*") {
    [Environment]::SetEnvironmentVariable("Path", "$path;$msys2Bin", "Machine")
    Write-Host "    Appended."
} else {
    Write-Host "    Already on PATH."
}

Write-Host "==> MSYS2 packages ready."
