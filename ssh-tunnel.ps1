<#
.SYNOPSIS
	SSH转发本地端口到3x-ui面板端口
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"

# 读取并解析config.json和constants.json
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Constants = Get-Content -LiteralPath $ConstantsPath -Raw | ConvertFrom-Json
$RemoteHost = $Config.ip
if ([string]::IsNullOrWhiteSpace($RemoteHost))
{
	throw "remote/config.json 缺少 ip"
}
$SshPort = $Config.sshPort
$Username = $Constants.username
$LocalSshPort = $Constants.localSshPort
$PanelPort = $Constants.'3xpanelPort'
$PanelUriPath = $Constants.'3xpanelUriPath'

# 建立SSH转发
Write-Host "正在建立SSH转发"
Write-Host "请访问 http://127.0.0.1:$LocalSshPort/$PanelUriPath 进入3x-ui面板"
Write-Host "按Ctrl+C断开隧道"
ssh -N -L "${LocalSshPort}:127.0.0.1:${PanelPort}" -p $SshPort "$Username@$RemoteHost"
