<#
.SYNOPSIS
	触发远端directDomain公信TLS初始化
.DESCRIPTION
	从 remote/config.json 和 remote/constants.json 读取连接信息，通过SSH在远端执行 direct-tls-init.sh，然后下载日志
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"

$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Constants = Get-Content -LiteralPath $ConstantsPath -Raw | ConvertFrom-Json
$RemoteHost = $Config.ip
$SshPort = $Config.sshPort
$Username = $Constants.username
$SshTarget = "${Username}@${RemoteHost}"
$SshHostKeyOptions = @(
	"-o", "StrictHostKeyChecking=no",
	"-o", "UserKnownHostsFile=NUL",
	"-o", "LogLevel=ERROR",
	"-o", "BatchMode=yes"
)

$RemoteCommand = "cd ~/3x-setup && bash ./direct-tls-init.sh"

Write-Host "Starting remote direct TLS init"
ssh @SshHostKeyOptions -p $SshPort $SshTarget $RemoteCommand
if ($LASTEXITCODE -ne 0)
{
	Write-Error "Failed to init remote direct TLS"
	exit 1
}

& (Join-Path $ProjectDir "get-log.ps1")

$global:LASTEXITCODE = 0
