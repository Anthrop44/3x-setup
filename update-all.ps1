<#
.SYNOPSIS
	更新远端VPS系统、3X-UI和代理客户端文件
.DESCRIPTION
	从本地配置读取SSH连接信息，依次执行系统升级、3X-UI更新和一次代理客户端更新任务
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"
$ModuleDir = Join-Path $ProjectDir "modules"

Import-Module (Join-Path $ModuleDir "assert-exit-code.psm1") -Force
Import-Module (Join-Path $ModuleDir "ssh-host-recovery.psm1") -Force

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Constants = Get-Content -LiteralPath $ConstantsPath -Raw | ConvertFrom-Json
$RemoteHost = $Config.ip
$SshPort = $Config.sshPort
$Username = $Constants.username
$SshTarget = "${Username}@${RemoteHost}"
$LogScriptPath = Join-Path $ProjectDir "get-log.ps1"
$HostKeyRecoveryAttempted = $false
$SshOptions = @(
	"-o", "BatchMode=yes"
)

$SshCommand = Get-Command "ssh" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $SshCommand)
{
	throw "OpenSSH ssh is required"
}

$RemoteCommand = @'
set -eu
sudo -n apt-get update
sudo -n apt-get dist-upgrade -y
sudo -n x-ui update
sudo -n systemctl start 3x-fetch-apps.service
'@

Write-Host "Updating system, 3X-UI, and proxy client files on $RemoteHost"
Invoke-CommandWithHostKeyRecovery `
	-Command { & $SshCommand.Source @SshOptions -p $SshPort $SshTarget $RemoteCommand } `
	-LogScriptPath $LogScriptPath `
	-Attempted ([ref]$HostKeyRecoveryAttempted)
Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to update the remote server"

Write-Host "Remote update completed"
$global:LASTEXITCODE = 0
