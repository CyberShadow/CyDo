# Disable Windows guest power saving so the VM stays responsive when idle.
# Without this, Windows hits its default "sleep after 30 min" / "monitor
# off after 10 min" and SSH/SPICE sessions appear to freeze even though
# the libvirt domain is still running.
#
# All four `powercfg /change ... -ac 0` invocations mean "AC power, never".
# Modifies the active power scheme persistently across reboots.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "==> Disabling guest power saving (sleep, hibernate, monitor, disk timeouts)..."
powercfg /change standby-timeout-ac   0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac   0
powercfg /change disk-timeout-ac      0
Write-Host "==> Power saving disabled."
