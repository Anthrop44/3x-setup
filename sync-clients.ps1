<#
.SYNOPSIS
	同步远程3x-ui客户端
.DESCRIPTION
	上传 remote/config.json 和客户分发页面到已有VPS，远程同步客户并更新伪装站分发目录
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectDir = $PSScriptRoot
$RemoteDir = Join-Path $ProjectDir "remote"
$ConfigPath = Join-Path $RemoteDir "config.json"
$ConfigSchemaPath = Join-Path $RemoteDir "config.schema.json"
$ConstantsPath = Join-Path $RemoteDir "constants.json"
$ConstantsSchemaPath = Join-Path $RemoteDir "constants.schema.json"
$FakeSiteDir = Join-Path $RemoteDir "fake-site"
$ClientsTsvPath = Join-Path $ProjectDir "clients.tsv"
$ModuleDir = Join-Path $ProjectDir "modules"

Import-Module (Join-Path $ModuleDir "setup-config.psm1") -Force
Import-Module (Join-Path $ModuleDir "client-files.psm1") -Force

function Assert-ExitCode
{
	<#
	.SYNOPSIS
		检查命令退出码
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$ExitCode,

		[Parameter(Mandatory = $true)]
		[string]$FailureMessage
	)

	if ($ExitCode -ne 0)
	{
		throw $FailureMessage
	}
}

# 读取并解析 config.json 和 constants.json
$ConfigFiles = Read-SetupConfigFiles `
	-ConfigPath $ConfigPath `
	-ConfigSchemaPath $ConfigSchemaPath `
	-ConstantsPath $ConstantsPath `
	-ConstantsSchemaPath $ConstantsSchemaPath
$Config = $ConfigFiles.Config
$Constants = $ConfigFiles.Constants

# 补齐 config.json 自动生成字段
Complete-SetupConfig -Config $Config

# 检查 config.json 中的客户端名和订阅路径不重复
Assert-SetupClientConfigValid -Config $Config -RequireSubscriptionPath
Assert-SetupConstantsValid -Constants $Constants

# 写回自动生成字段并导出客户分发页面和URL清单
Save-SetupConfig -Config $Config -ConfigPath $ConfigPath
$DistributionPath = [string]$Config.distributionPath
$DistributionDir = Join-Path $FakeSiteDir $DistributionPath
Export-ClientFiles -Config $Config -Constants $Constants -DistributionDir $DistributionDir -ClientsTsvPath $ClientsTsvPath
if ($DistributionPath -notmatch "^[a-zA-Z0-9]{15}$")
{
	throw "remote/config.json distributionPath is unsafe"
}

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

$SshPath = (Get-Command "ssh" -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$SftpPath = (Get-Command "sftp" -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if ([string]::IsNullOrWhiteSpace($SshPath))
{
	throw "OpenSSH ssh is required"
}
if ([string]::IsNullOrWhiteSpace($SftpPath))
{
	throw "OpenSSH sftp is required"
}

$SftpBatchPath = Join-Path $ProjectDir "sync-clients-$([Guid]::NewGuid().ToString("N")).sftp"
$RemoteFakeSiteDir = "3x-setup/fake-site"
$RemoteDistributionDir = "$RemoteFakeSiteDir/$DistributionPath"
$PrepareRemoteCommand = "set -eu; cd ~; rm -rf -- '$RemoteDistributionDir'; mkdir -p -- '$RemoteFakeSiteDir'"
$RemoteCommand = @"
set -eu
cd ~/3x-setup
(setsid bash -c 'exec bash ./3x-client-init.sh --noTLS --noAPP </dev/null' >/dev/null 2>&1 < /dev/null & RemotePid=`$!; echo 'Remote client sync has started in the background; waiting for it to complete'; wait `$RemotePid)
SourceDir="./fake-site/$DistributionPath"
TargetDir="/var/www/3x-fake-site/$DistributionPath"
test -d "`$SourceDir"
sudo -n rm -rf -- "`$TargetDir"
sudo -n install -d -m 755 -o caddy -g caddy "`$TargetDir"
sudo -n cp -a -- "`$SourceDir"/. "`$TargetDir"/
sudo -n chown -R caddy:caddy "`$TargetDir"
"@

try
{
	$ConfigSftpPath = $ConfigPath -replace "\\", "/"
	$DistributionSftpPath = $DistributionDir -replace "\\", "/"
	$SftpCommands = @(
		"put `"$ConfigSftpPath`" `"3x-setup/config.json`"",
		"put -r `"$DistributionSftpPath`" `"$RemoteFakeSiteDir`"",
		"bye"
	)
	Set-Content -LiteralPath $SftpBatchPath -Encoding ascii -Value $SftpCommands

	Write-Host "Preparing remote client distribution directory"
	& $SshPath @SshHostKeyOptions -p $SshPort $SshTarget $PrepareRemoteCommand
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to prepare remote client distribution directory"

	Write-Host "Uploading remote/config.json and client distribution pages to $RemoteHost"
	& $SftpPath @SshHostKeyOptions -P $SshPort -b $SftpBatchPath $SshTarget
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to upload remote client files"
} finally
{
	Remove-Item -LiteralPath $SftpBatchPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Starting remote client sync"
& $SshPath @SshHostKeyOptions -p $SshPort $SshTarget $RemoteCommand
Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to sync remote clients"

& (Join-Path $ProjectDir "get-log.ps1")

$global:LASTEXITCODE = 0
