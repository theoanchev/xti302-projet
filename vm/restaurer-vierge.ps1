<#
  restaurer-vierge.ps1 — Remet la VM dans l'etat du snapshot "vierge"
  (pour vérifier que les scripts du projet reconstruisent tout).
  Usage : powershell -ExecutionPolicy Bypass -File .\vm\restaurer-vierge.ps1
#>
param([string]$VmName = "debian13-projet", [string]$SnapName = "vierge")
$ErrorActionPreference = "Stop"
$VBox = Join-Path $env:ProgramFiles "Oracle\VirtualBox\VBoxManage.exe"
$state = (& $VBox showvminfo $VmName --machinereadable | Select-String '^VMState=') -replace '^VMState="|"$',''
if ($state -ne "poweroff") { & $VBox controlvm $VmName poweroff; Start-Sleep 3 }
& $VBox snapshot $VmName restore $SnapName
& $VBox startvm $VmName --type headless
Write-Host "VM restauree sur '$SnapName' et demarree (headless)."
