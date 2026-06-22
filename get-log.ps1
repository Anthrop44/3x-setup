<#
.SYNOPSIS
	下载远程初始化日志
.DESCRIPTION
	从 remote/config.json 和 remote/constants.json 读取连接信息，下载整个 log/ 文件夹
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
if ([string]::IsNullOrWhiteSpace($RemoteHost))
{
	throw "remote/config.json 缺少 ip"
}
$SshPort = $Config.sshPort
$Username = $Constants.username
$RemoteLogDir = "~/3x-setup/log"
$LocalLogDir = Join-Path $ProjectDir "log"

# 创建本地 log 目录
if (-not (Test-Path -LiteralPath $LocalLogDir -PathType Container))
{
	New-Item -ItemType Directory -Path $LocalLogDir -Force | Out-Null
}

Write-Host "下载 $RemoteLogDir/ 到 $LocalLogDir/"
scp -o StrictHostKeyChecking=accept-new -r -P $SshPort "${Username}@${RemoteHost}:${RemoteLogDir}/*" "$LocalLogDir/"
if ($LASTEXITCODE -ne 0)
{
	Write-Error "下载日志文件夹失败"
	exit 1
}

$global:LASTEXITCODE = 0
