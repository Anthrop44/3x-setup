<#
.SYNOPSIS
	同步远程3X-UI客户端和Cloudflare优选域名
.DESCRIPTION
	上传 remote/config.json 和客户分发文件到已有VPS，远程同步客户、Cloudflare优选域名并更新伪装站分发目录
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
Import-Module (Join-Path $ModuleDir "assert-exit-code.psm1") -Force
Import-Module (Join-Path $ModuleDir "ssh-host-recovery.psm1") -Force

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

# 检查config.json中的客户端和优选域名配置
Assert-SetupClientConfigValid -Config $Config -RequireSubscriptionPath
Assert-SetupCdnOptDomainsValid -Config $Config
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
$LogScriptPath = Join-Path $ProjectDir "get-log.ps1"
$HostKeyRecoveryAttempted = $false
$SshOptions = @(
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

$SftpBatchPath = Join-Path $ProjectDir "sync-config-$([Guid]::NewGuid().ToString("N")).sftp"
$RemoteFakeSiteDir = "3x-setup/fake-site"
$RemoteDistributionDir = "$RemoteFakeSiteDir/$DistributionPath"
$PrepareRemoteCommand = "set -eu; cd ~; rm -rf -- '$RemoteDistributionDir'; mkdir -p -- '$RemoteFakeSiteDir'"
$RemoteCommand = @"
set -eu
cd ~/3x-setup
(setsid bash -c 'exec bash ./cf-host-init.sh --noTLS --noAPP </dev/null' >/dev/null 2>&1 < /dev/null & RemotePid=`$!; echo 'Remote config sync has started in the background; waiting for it to complete'; wait `$RemotePid)
SourceDir="./fake-site/$DistributionPath"
TargetDir="/var/www/3x-fake-site/$DistributionPath"
test -d "`$SourceDir"
test -f "`$SourceDir/template.css"
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

	Write-Host "Preparing remote config distribution directory"
	Invoke-CommandWithHostKeyRecovery `
		-Command { & $SshPath @SshOptions -p $SshPort $SshTarget $PrepareRemoteCommand } `
		-LogScriptPath $LogScriptPath `
		-Attempted ([ref]$HostKeyRecoveryAttempted)
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to prepare remote config distribution directory"

	Write-Host "Uploading remote/config.json and distribution files to $RemoteHost"
	Invoke-CommandWithHostKeyRecovery `
		-Command { & $SftpPath @SshOptions -P $SshPort -b $SftpBatchPath $SshTarget } `
		-LogScriptPath $LogScriptPath `
		-Attempted ([ref]$HostKeyRecoveryAttempted)
	Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to upload remote config files"
} finally
{
	Remove-Item -LiteralPath $SftpBatchPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Starting remote config sync"
Invoke-CommandWithHostKeyRecovery `
	-Command { & $SshPath @SshOptions -p $SshPort $SshTarget $RemoteCommand } `
	-LogScriptPath $LogScriptPath `
	-Attempted ([ref]$HostKeyRecoveryAttempted)
Assert-ExitCode -ExitCode $LASTEXITCODE -FailureMessage "Failed to sync remote config"

& $LogScriptPath

$global:LASTEXITCODE = 0
